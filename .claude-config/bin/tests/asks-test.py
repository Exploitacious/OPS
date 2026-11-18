#!/usr/bin/env python3
"""Behavior tests for bin/asks, the per-thread register of what is waiting on the box's owner.

The register replaces polling several threads for status, so the failures that
matter are the quiet ones: an ask that vanishes, a duplicate that doubles the
page, a corrupt file read as an empty register, a secret stored where a chat
page will show it, and two threads writing at once. Every case runs the real
script against a throwaway OPS_STATE_DIR; the live ~/.local/state/ops is never
read.
"""
import os, runpy; runpy.run_path(os.path.join(os.path.dirname(os.path.realpath(__file__)), "..", "sandbox_guard.py"))["require"]()

import json
import stat
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path

ASKS = Path(__file__).resolve().parent.parent / "asks"
T1 = "aaaaaaaa-1111-4111-8111-111111111111"
T2 = "bbbbbbbb-2222-4222-8222-222222222222"
NOW = "2026-11-07T12:00:00-05:00"


class AsksTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="asks-test.")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.state = self.root / "state"
        self.asks_dir = self.state / "asks"
        self.env = {k: v for k, v in os.environ.items() if k not in ("ASKS_THREAD", "T3CODE_THREAD_ID", "OPS_STATE_DIR")}
        self.env.update(OPS_STATE_DIR=str(self.state), HOME=str(self.root / "home"), ASKS_NOW=NOW,
                        PYTHONDONTWRITEBYTECODE="1")

    def run_asks(self, *args, thread=T1, stdin=None, env=None):
        e = dict(env or self.env)
        if thread:
            e["ASKS_THREAD"] = thread
        return subprocess.run([sys.executable, str(ASKS), *args], capture_output=True, text=True, env=e,
                              input=stdin, timeout=30)

    def ok(self, *args, **kw):
        p = self.run_asks(*args, **kw)
        self.assertEqual(p.returncode, 0, p.stderr + p.stdout)
        return p

    def listed(self, *args, **kw):
        return json.loads(self.ok("list", "--json", *args, **kw).stdout)

    # --- add and list ------------------------------------------------------

    def test_add_records_every_field_and_lists_it(self):
        self.ok("add", "Ship the lint?", "--why", "It checks every final message", "--rec", "Yes",
                "--default", "It stays off", "--owner", "lane register", "--client", "Example Client",
                "--deadline", "2026-11-10", "--title", "Prompt hooks")
        (item,) = self.listed()
        self.assertEqual((item["n"], item["kind"], item["text"]), (1, "decision", "Ship the lint?"))
        self.assertEqual((item["why"], item["rec"], item["default"]), ("It checks every final message", "Yes", "It stays off"))
        self.assertEqual((item["owner"], item["client"], item["deadline"]), ("lane register", "Example Client", "2026-11-10"))
        self.assertEqual((item["thread"], item["thread_title"], item["ref"]), (T1, "Prompt hooks", "aaaaaaaa#1"))
        self.assertEqual(item["created"], NOW)
        self.assertIsNone(item["resolved"])

    def test_numbers_are_per_thread_and_never_reused(self):
        self.ok("add", "one")
        self.ok("add", "two")
        self.ok("add", "other thread", thread=T2)
        self.ok("resolve", "2")
        self.ok("add", "three")
        by = {(i["thread"][:8], i["n"]): i["text"] for i in self.listed("--all")}
        self.assertEqual(by, {("aaaaaaaa", 1): "one", ("aaaaaaaa", 3): "three", ("bbbbbbbb", 1): "other thread"})

    def test_same_open_ask_updates_instead_of_duplicating(self):
        self.ok("add", "Pick one", "--rec", "A")
        p = self.ok("add", "Pick one", "--default", "stays as is")
        self.assertIn("updated #1", p.stdout)
        (item,) = self.listed()
        # The re-add refreshes what it passes and keeps what it left empty.
        self.assertEqual((item["rec"], item["default"]), ("A", "stays as is"))

    def test_resolved_ask_can_be_asked_again_as_a_new_ask(self):
        self.ok("add", "Pick one")
        self.ok("resolve", "1")
        self.ok("add", "Pick one")
        self.assertEqual([i["n"] for i in self.listed()], [2])

    def test_default_thread_comes_from_t3codethread_id_and_scopes_the_list(self):
        env = dict(self.env, T3CODE_THREAD_ID=T1)
        self.run_asks("add", "mine", thread=None, env=env)
        self.ok("add", "theirs", thread=T2)
        mine = json.loads(self.run_asks("list", "--json", thread=None, env=env).stdout)
        self.assertEqual([i["text"] for i in mine], ["mine"])
        everything = json.loads(self.run_asks("list", "--json", "--all", thread=None, env=env).stdout)
        self.assertEqual(sorted(i["text"] for i in everything), ["mine", "theirs"])
        by_prefix = json.loads(self.run_asks("list", "--json", "--thread", "bbbbbbbb", thread=None, env=env).stdout)
        self.assertEqual([i["text"] for i in by_prefix], ["theirs"])

    def test_no_thread_id_files_under_adhoc_and_says_so(self):
        p = self.run_asks("add", "orphan", thread=None)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("adhoc", p.stderr)
        self.assertEqual([i["thread"] for i in self.listed("--all", thread=None)], ["adhoc"])

    def test_long_and_colon_thread_ids_get_a_safe_file_name(self):
        lane = "thread:provider:claudeAgent:native-thread:" + "x" * 300
        self.ok("add", "from a lane", thread=lane)
        (path,) = [p for p in self.asks_dir.iterdir() if p.suffix == ".json"]
        self.assertLess(len(path.name), 100)
        self.assertEqual(json.loads(path.read_text())["thread"], lane)
        (item,) = self.listed("--all")
        self.assertTrue(item["ref"].startswith("lane:"), item["ref"])

    # --- console asks ------------------------------------------------------

    def test_console_ask_keeps_steps_and_paste_and_defaults_its_kind(self):
        paste = 'Write-Host "hi"\r\nexit 0\r\n'
        self.ok("add", "Update the census script", "--tool", "Example script library", "--step", "Open the library",
                "--step", "Replace the body and save", "--paste", paste, "--expect", "Version 4", "--link", "https://x.example/n")
        (item,) = self.listed()
        self.assertEqual(item["kind"], "console")
        self.assertEqual(item["steps"], ["Open the library", "Replace the body and save"])
        self.assertEqual(item["paste"], 'Write-Host "hi"\nexit 0')
        self.assertEqual((item["tool"], item["expect"], item["link"]), ("Example script library", "Version 4", "https://x.example/n"))

    def test_paste_from_file_and_stdin(self):
        f = self.root / "p.ps1"
        f.write_text("from file\n")
        self.ok("add", "a", "--tool", "T", "--paste", "@" + str(f))
        self.ok("add", "b", "--tool", "T", "--paste", "-", stdin="from stdin\n")
        self.assertEqual([i["paste"] for i in self.listed()], ["from file", "from stdin"])

    def test_console_ask_without_tool_steps_or_paste_is_refused(self):
        p = self.run_asks("add", "empty", "--kind", "console")
        self.assertEqual(p.returncode, 2)
        self.assertIn("console ask needs", p.stderr)

    def test_oversize_paste_and_bad_link_and_bad_deadline_are_refused(self):
        self.assertEqual(self.run_asks("add", "big", "--tool", "T", "--paste", "x" * (65 * 1024)).returncode, 2)
        self.assertEqual(self.run_asks("add", "x", "--tool", "T", "--link", "ftp://nope").returncode, 2)
        self.assertEqual(self.run_asks("add", "x", "--deadline", "11/10/2026").returncode, 2)
        self.assertEqual(self.run_asks("add", "x" * 401).returncode, 2)
        self.assertFalse(self.asks_dir.exists() and any(p.suffix == ".json" for p in self.asks_dir.iterdir()))

    # --- secrets -----------------------------------------------------------

    def test_secret_shaped_values_are_refused_in_every_field_and_never_stored(self):
        token = "ghp_" + "a1B2c3D4e5" * 4
        # Built from parts so this file never holds a literal key header line: a secret
        # scanner would flag it, and two such lines side by side read as one key.
        key_header = "-" * 5 + "BEGIN RSA PRIVATE" + " KEY" + "-" * 5
        cases = [("add", "key " + token), ("add", "x", "--why", token), ("add", "x", "--tool", "T", "--paste", token),
                 ("add", "x", "--tool", "T", "--step", token),
                 ("add", "x", "--tool", "T", "--paste", key_header + "\nabc")]
        for args in cases:
            with self.subTest(args=args):
                p = self.run_asks(*args)
                self.assertEqual(p.returncode, 2, p.stdout)
                self.assertNotIn(token, p.stderr)   # the refusal names the shape, never echoes the value
        self.assertFalse(any(p.suffix == ".json" for p in self.asks_dir.iterdir()) if self.asks_dir.exists() else False)

    def test_title_note_and_thread_id_get_the_same_refusal(self):
        # --title, resolve --note and --thread must be checked like the ask itself: the
        # title shows on any page that lists the register, the note in `list --resolved`,
        # and the thread id becomes the file name.
        token = "ghp_" + "a1B2c3D4e5" * 4
        self.ok("add", "plain ask")
        before = sorted(p.name for p in self.asks_dir.iterdir())
        cases = {
            "add --title": ("add", "another ask", "--title", token),
            "resolve --note": ("resolve", "1", "--note", "closed with " + token),
            "add --thread": ("add", "x", "--thread", token),
            "list --thread": ("list", "--thread", token),
            "resolve --thread": ("resolve", "1", "--thread", token),
        }
        for name, args in cases.items():
            with self.subTest(case=name):
                p = self.run_asks(*args)
                self.assertEqual(p.returncode, 2, p.stdout + p.stderr)
                self.assertIn("GitHub token", p.stderr)
                self.assertNotIn(token, p.stderr + p.stdout)   # the refusal never echoes the value
        # An id that arrives through the environment becomes a file name just as a flag would.
        p = self.run_asks("add", "x", thread=token)
        self.assertEqual(p.returncode, 2, p.stdout + p.stderr)
        self.assertNotIn(token, p.stderr + p.stdout)
        # Nothing was stored: no new file, no title, no note, the ask is still open.
        self.assertEqual(sorted(p.name for p in self.asks_dir.iterdir()), before)
        (item,) = self.listed()
        self.assertEqual((item["thread_title"], item["note"], item["resolved"]), ("", None, None))

    def test_a_plain_title_and_note_are_still_stored(self):
        self.ok("add", "ask", "--title", "Prompt hooks")
        self.ok("resolve", "1", "--note", "answered in chat")
        (item,) = self.listed("--resolved")
        self.assertEqual((item["thread_title"], item["note"]), ("Prompt hooks", "answered in chat"))

    def test_a_script_that_names_a_password_parameter_is_not_refused(self):
        self.ok("add", "script", "--tool", "T", "--paste", "param([string]$Password)\nWrite-Host 'password prompt'")

    # --- resolve and prune -------------------------------------------------

    def test_resolve_by_number_by_ref_and_not_found(self):
        self.ok("add", "one")
        self.ok("add", "two", thread=T2)
        self.ok("resolve", "1", "--note", "answered in chat")
        self.ok("resolve", "bbbbbbbb#1")
        self.assertEqual(self.listed("--all"), [])
        done = {i["text"]: i["note"] for i in self.listed("--all", "--resolved")}
        self.assertEqual(done, {"one": "answered in chat", "two": None})
        self.assertEqual(self.run_asks("resolve", "9").returncode, 1)
        self.assertEqual(self.run_asks("resolve", "zzzzzzzz#1").returncode, 1)
        self.assertEqual(self.run_asks("resolve", "not-a-ref").returncode, 2)
        self.assertIn("already resolved", self.ok("resolve", "1").stdout)

    def test_resolved_asks_are_pruned_after_fourteen_days(self):
        self.ok("add", "old")
        self.ok("add", "kept")
        self.ok("resolve", "1")
        later = dict(self.env, ASKS_NOW="2026-11-30T12:00:00-05:00")
        self.ok("add", "new", env=later)
        self.assertEqual(sorted(i["text"] for i in self.listed("--all", env=later)), ["kept", "new"])
        self.assertEqual(self.listed("--all", "--resolved", env=later), [])

    def test_pruning_all_resolved_asks_keeps_numbers_unambiguous(self):
        self.ok("add", "only", thread=T2)
        self.ok("resolve", "1", thread=T2)
        later = dict(self.env, ASKS_NOW="2026-12-30T12:00:00-05:00")
        self.assertIn("pruned 1", self.ok("prune", env=later).stdout)
        self.assertEqual(self.listed("--all", "--resolved", env=later), [])
        self.ok("add", "new question", thread=T2, env=later)
        self.assertEqual([i["n"] for i in self.listed("--all", env=later)], [2])
        # A stale reference must never resolve the new question.
        self.assertEqual(self.run_asks("resolve", "bbbbbbbb#1", env=later).returncode, 1)
        self.assertEqual([i["text"] for i in self.listed("--all", env=later)], ["new question"])

    def test_prune_refuses_an_unreadable_register_before_changing_any_asks(self):
        self.ok("add", "only", thread=T2)
        self.ok("resolve", "1", thread=T2)
        path = self.asks_dir / (T2 + ".json")
        before = path.read_bytes()
        (self.asks_dir / "broken.json").write_text("{not json")
        later = dict(self.env, ASKS_NOW="2026-12-30T12:00:00-05:00")
        p = self.run_asks("prune", env=later)
        self.assertEqual(p.returncode, 1, p.stdout + p.stderr)
        self.assertIn("broken.json", p.stderr)
        self.assertEqual(path.read_bytes(), before)

    def test_add_reports_an_unreadable_register_before_writing(self):
        self.asks_dir.mkdir(parents=True)
        (self.asks_dir / "broken.json").write_text("{not json")
        p = self.run_asks("add", "new question")
        self.assertEqual(p.returncode, 1, p.stdout + p.stderr)
        self.assertIn("broken.json", p.stderr)
        self.assertFalse((self.asks_dir / (T1 + ".json")).exists())

    # --- files and failure modes -------------------------------------------

    def test_files_are_private(self):
        self.ok("add", "x")
        self.assertEqual(stat.S_IMODE(self.asks_dir.stat().st_mode), 0o700)
        (path,) = [p for p in self.asks_dir.iterdir() if p.suffix == ".json"]
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)

    def test_corrupt_file_is_an_error_not_an_empty_register(self):
        self.ok("add", "fine", thread=T2)
        (self.asks_dir / "broken.json").write_text("{not json")
        p = self.run_asks("list", "--all")
        self.assertEqual(p.returncode, 1)
        self.assertIn("broken.json", p.stderr)
        self.assertIn("fine", p.stdout)   # the readable thread still shows
        p = self.run_asks("resolve", "1", thread=T2)
        self.assertEqual(p.returncode, 1)
        self.assertIn("broken.json", p.stderr)

    def test_a_file_with_the_wrong_shape_is_named(self):
        self.asks_dir.mkdir(parents=True)
        (self.asks_dir / "odd.json").write_text(json.dumps({"thread": T1, "asks": [{"n": "x"}]}))
        p = self.run_asks("list", "--all")
        self.assertEqual(p.returncode, 1)
        self.assertIn("odd.json", p.stderr)

    def test_concurrent_adds_to_one_thread_all_land(self):
        errors = []

        def add(i):
            p = self.run_asks("add", "ask %d" % i)
            if p.returncode:
                errors.append(p.stderr)

        threads = [threading.Thread(target=add, args=(i,)) for i in range(8)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.assertEqual(errors, [])
        items = self.listed()
        self.assertEqual(sorted(i["n"] for i in items), list(range(1, 9)))
        self.assertEqual(len({i["text"] for i in items}), 8)

    def test_a_write_waits_for_the_register_lock(self):
        """Eight racing writers rarely hit the read-modify-write window, so prove the lock directly:
        hold it here and a writer must block until it is released, then land its ask."""
        import fcntl
        self.asks_dir.mkdir(parents=True)
        fd = os.open(str(self.asks_dir / ".lock"), os.O_CREAT | os.O_RDWR, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
        try:
            e = dict(self.env, ASKS_THREAD=T1)
            proc = subprocess.Popen([sys.executable, str(ASKS), "add", "waits"], env=e,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            with self.assertRaises(subprocess.TimeoutExpired):
                proc.communicate(timeout=1.5)
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)
        out, err = proc.communicate(timeout=15)
        self.assertEqual(proc.returncode, 0, err)
        self.assertEqual([i["text"] for i in self.listed()], ["waits"])

    def test_list_text_output_names_the_thread_and_the_recommendation(self):
        self.ok("add", "Pick one", "--rec", "A", "--title", "Prompt hooks")
        out = self.ok("list").stdout
        self.assertIn("thread aaaaaaaa (Prompt hooks)", out)
        self.assertIn("aaaaaaaa#1", out)
        self.assertIn("recommend: A", out)
        self.assertIn("nothing open", self.ok("list", thread=T2).stdout)

    # --- the OPS state directory and the platform ---------------------------

    def test_state_defaults_to_the_ops_state_directory_under_home(self):
        # With no OPS_STATE_DIR the register lives in ~/.local/state/ops/asks, the same root
        # the other OPS tools use; HOME here is a fixture, never the real one.
        env = {k: v for k, v in self.env.items() if k != "OPS_STATE_DIR"}
        self.ok("add", "default home", env=env)
        default = self.root / "home" / ".local" / "state" / "ops" / "asks"
        self.assertEqual([p.name for p in default.iterdir() if p.suffix == ".json"], [T1 + ".json"])
        self.assertFalse(self.state.exists())

    def test_a_platform_without_fcntl_gets_one_line_and_exit_1_not_a_traceback(self):
        # sys.modules["fcntl"] = None makes `import fcntl` raise ImportError, the way a
        # native Windows Python does. The command must say so once and exit 1.
        snippet = ("import runpy, sys; sys.modules['fcntl'] = None; sys.argv = ['asks', 'list']; "
                   "runpy.run_path(%r, run_name='__main__')" % str(ASKS))
        p = subprocess.run([sys.executable, "-c", snippet], capture_output=True, text=True, env=self.env, timeout=30)
        self.assertEqual(p.returncode, 1, p.stdout + p.stderr)
        self.assertEqual(p.stdout, "")
        self.assertEqual(len(p.stderr.strip().splitlines()), 1, p.stderr)
        self.assertIn("fcntl", p.stderr)
        self.assertNotIn("Traceback", p.stderr)
        self.assertFalse(self.state.exists())   # it refused before touching the register


if __name__ == "__main__":
    unittest.main()
