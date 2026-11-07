#!/usr/bin/env python3
"""Regression tests for digest and memory-hint failure boundaries; no live state.

The digest cases call bin/memory-index's own functions. The hint cases run the
real hooks/memory-hint.sh against a stub scorer and check that every failure of
the hook's own plumbing (a crashed scorer, a timeout, an unreadable input, no
interpreter) leaves one line in the hook's log and nothing in the session. They
skip, and say so, in a copy that does not carry memory-hint.sh. The write-time
secrets guard has its own suite; its boundary cases are not repeated here.
"""

import json
import os
import runpy
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

CONFIG = Path(__file__).resolve().parents[2]
MEMORY = runpy.run_path(str(CONFIG / "bin" / "memory-index"))
HINT_HOOK = CONFIG / "hooks" / "memory-hint.sh"


class DigestBoundaryTests(unittest.TestCase):
    def test_long_pinned_name_keeps_its_description(self):
        for src in ("this", "root"):
            for stem in ("pinned-" + "r" * 180, "pinned-" + "r" * 130 + "\U0001F9ED" * 12):
                with self.subTest(src=src, stem=stem):
                    entry = {
                        "stem": stem,
                        "desc": "Never bypass the credential guard.",
                        "src": src,
                        "tier": 0,
                    }
                    line = MEMORY["entry_line"](entry, True)
                    self.assertIn(": " + entry["desc"], line)
                    self.assertLessEqual(MEMORY["u16"](line), MEMORY["LINE_CAP"])

    def test_short_pinned_label_is_unchanged(self):
        entry = {"stem": "pinned-rule", "desc": "Keep this ruling.", "src": "root", "tier": 0}
        self.assertEqual(
            MEMORY["entry_line"](entry, True), "- [root] pinned-rule: Keep this ruling."
        )

    def test_twenty_long_pins_stay_described_within_the_budget(self):
        entries = [
            {
                "stem": f"pin-{i:02d}-" + "r" * 180,
                "desc": f"Ruling {i}: never bypass the credential guard.",
                "src": "this" if i % 2 else "root",
                "type": "feedback",
                "when": (2026, 11, 7, 0, 0, i),
                "pinned": True,
            }
            for i in range(20)
        ]
        entries += [
            {
                "stem": f"reference-{i:03d}",
                "desc": "An ordinary long description. " * 8,
                "src": "this",
                "type": "reference",
                "when": (2026, 11, 7, 0, 0, 0),
                "pinned": False,
            }
            for i in range(300)
        ]
        order = MEMORY["order_entries"](entries, set())
        k, j = MEMORY["fit_order"](order, 6000, True)
        blocks = MEMORY["render"](order, k, j, True)
        text = "\n".join(line for block in blocks for line in block)
        self.assertGreaterEqual(k, 20)
        self.assertLessEqual(MEMORY["cost"](blocks), 6000)
        for entry in order[:20]:
            self.assertIn(entry["desc"], text)

    def test_the_home_account_name_is_not_a_project_word(self):
        # /home/alice/OPS/PROJECTS/ExampleOrg/Billing names one project, billing;
        # the account name sits on every path under HOME and must not match entries.
        home = os.environ.get("HOME")
        os.environ["HOME"] = "/home/alice"
        try:
            words = MEMORY["cwd_tokens"]("/home/alice/OPS/PROJECTS/ExampleOrg/Billing")
        finally:
            if home is None:
                del os.environ["HOME"]
            else:
                os.environ["HOME"] = home
        self.assertIn("billing", words)
        self.assertNotIn("alice", words)
        self.assertNotIn("ops", words)

    def test_the_pool_cap_warns_and_never_fails(self):
        self.assertEqual(MEMORY["POOL_CAP"], 60)
        with tempfile.TemporaryDirectory(prefix="memory-cap-") as pool:
            for i in range(MEMORY["POOL_CAP"] + 1):
                Path(pool, f"entry-{i:03d}.md").write_text(
                    f"---\nname: entry-{i:03d}\ndescription: entry {i}\nmetadata:\n  type: feedback\n---\n"
                )
            run = subprocess.run(
                ["python3", "-I", str(CONFIG / "bin" / "memory-index"), "--check", pool],
                capture_output=True, text=True, check=False,
            )
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("WARN", run.stderr)
        self.assertEqual(len(run.stdout.splitlines()), MEMORY["POOL_CAP"] + 1)


@unittest.skipUnless(HINT_HOOK.is_file(), "hooks/memory-hint.sh is not in this copy")
class HintHookBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="memory-boundary-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.hooks = self.root / "config" / "hooks"
        self.bin = self.root / "config" / "bin"
        self.hooks.mkdir(parents=True)
        self.bin.mkdir()
        for name in ("hooklib.sh", "memory-hint.sh"):
            shutil.copy2(CONFIG / "hooks" / name, self.hooks / name)
        self.env = dict(
            os.environ,
            HOME=str(self.root),
            OPS_DIR=str(self.root),
            OPS_STATE_DIR=str(self.root / "state"),
            MEMORY_HINT="1",
        )

    def hooklib_append(self, code):
        with (self.hooks / "hooklib.sh").open("a") as stream:
            stream.write("\n" + code + "\n")

    def hint(self):
        return subprocess.run(
            ["bash", str(self.hooks / "memory-hint.sh")],
            input=json.dumps({"prompt": "Review the credential guard", "cwd": str(self.root)}),
            capture_output=True, text=True, env=self.env, check=False,
        )

    def scorer(self, status):
        # The stub names the mode: memory-hint.sh stays silent, with no log line,
        # for an indexer that has no --hint (an older bin/memory-index), which
        # memory-hint-test.sh pins. These cases are about an indexer that has it.
        (self.bin / "memory-index").write_text(f"# stub with a --hint mode\nimport sys\nsys.exit({status})\n")

    def assert_hint_failure_logged(self, reason):
        result = self.hint()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout + result.stderr, "")
        log = self.root / "state" / "memory-hint.log"
        self.assertTrue(log.is_file(), "hook failure was silently discarded")
        lines = log.read_text().splitlines()
        self.assertEqual(len(lines), 1)
        self.assertIn(reason, lines[0])

    def test_hint_logs_a_crashed_scorer(self):
        self.scorer(7)
        self.assert_hint_failure_logged("status 7")

    def test_hint_logs_an_input_read_failure(self):
        self.scorer(0)
        self.hooklib_append("cat() { command cat; return 74; }")
        self.assert_hint_failure_logged("read")

    def test_hint_logs_a_crash_without_timeout_available(self):
        self.hooklib_append("hook_timeout() { return 1; }")
        self.scorer(7)
        self.assert_hint_failure_logged("status 7")

    def test_hint_logs_a_timeout(self):
        timeout = self.bin / "test-timeout"
        timeout.write_text("#!/usr/bin/env bash\nexit 124\n")
        timeout.chmod(0o755)
        self.env["MEMORY_TEST_TIMEOUT"] = str(timeout)
        self.hooklib_append('hook_timeout() { printf "%s" "$MEMORY_TEST_TIMEOUT"; }')
        self.scorer(0)
        self.assert_hint_failure_logged("status 124")

    def test_hint_logs_a_missing_indexer(self):
        self.assert_hint_failure_logged("indexer")

    def test_hint_logs_an_unavailable_interpreter(self):
        self.scorer(0)
        self.hooklib_append("hook_python() { return 2; }")
        self.assert_hint_failure_logged("Python")

    def test_a_clean_no_match_is_silent(self):
        self.scorer(0)
        result = self.hint()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout + result.stderr, "")
        self.assertFalse((self.root / "state" / "memory-hint.log").exists())


if __name__ == "__main__":
    unittest.main()
