#!/usr/bin/env python3
"""Offline destructive-path regression tests. Every ref and file is a fixture."""
import os, runpy; runpy.run_path(os.path.join(os.path.dirname(os.path.realpath(__file__)), "..", "sandbox_guard.py"))["require"]()
import datetime
import json
import os
import shutil
import sqlite3
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "branch-gc"
OLD = "2020-01-01T00:00:00Z"


class BranchGcSafety(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.repo = self.root / "repo"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        # T3CODE_HOME too: a T3 session exports it, and no case may read the live T3 home.
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith("BRANCH_GC_") and key != "T3CODE_HOME"}
        self.env.update(HOME=str(self.root), GH_FIXTURE=str(self.root),
                        GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1",
                        GIT_AUTHOR_NAME="Test", GIT_COMMITTER_NAME="Test",
                        GIT_AUTHOR_EMAIL="test@example.invalid", GIT_COMMITTER_EMAIL="test@example.invalid",
                        BRANCH_GC_LOG=str(self.root / "log" / "gc.log"),
                        BRANCH_GC_T3_DB=str(self.root / "state.sqlite"),
                        BRANCH_GC_PROC_ROOT=str(self.root / "proc"),
                        BRANCH_GC_WORKTREE_GRACE_HOURS="24")
        (self.root / "proc/self").mkdir(parents=True)
        for key in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR"):
            self.env.pop(key, None)
        self.real_git = subprocess.check_output(["which", "git"], text=True).strip()
        self.env["REAL_GIT"] = self.real_git
        self.env["REAL_MV"] = shutil.which("mv")
        self.env["REAL_CP"] = shutil.which("cp")
        self.env["REAL_JQ"] = shutil.which("jq")
        self.env["REAL_STAT"] = shutil.which("stat")
        self.trash = self.root / ".local/state/ops/branch-gc-trash"
        self.env["PATH"] = str(self.bin) + os.pathsep + os.environ["PATH"]
        self.git("init", "-q", "-b", "main", str(self.repo), at=self.root)
        self.base = self.commit("base")
        self.git("update-ref", "refs/heads/main", self.base)
        self.git("read-tree", "--reset", "-u", self.base)
        with (self.repo / ".git/config").open("a") as config:
            config.write('\n[remote "origin"]\n\turl = https://github.com/acme/widget.git\n')
        self.prs = []
        self.stub("gh", '''#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys
root = pathlib.Path(os.environ["GH_FIXTURE"])
args = sys.argv[1:]
(root / "gh-host").write_text(os.environ.get("GH_HOST", ""))
if (root / "gh-fail").exists():
    print("HTTP 401: authentication required", file=sys.stderr)
    sys.exit(1)
if args[:2] == ["repo", "view"]:
    print(json.dumps({"nameWithOwner":"acme/widget", "defaultBranchRef":{"name":"main"}}))
elif args[:2] == ["api", "graphql"]:
    print((root / "total").read_text() if (root / "total").exists() else len(json.loads((root / "prs.json").read_text())))
elif args[:2] == ["pr", "list"]:
    if (root / "on-list.py").exists():
        subprocess.run([sys.executable, str(root / "on-list.py")], check=True)
    print((root / "prs.json").read_text())
else:
    sys.exit(64)
''')

    def stub(self, name, body):
        path = self.bin / name
        path.write_text(body)
        path.chmod(0o755)

    def git(self, *args, at=None, data=None):
        return subprocess.check_output([self.real_git, "-C", str(at or self.repo), *args],
                                       input=data, text=True, env=self.env, stderr=subprocess.PIPE).strip()

    def commit(self, message, parent=None):
        blob = self.git("hash-object", "-w", "--stdin", data="base\n")
        tree = self.git("mktree", data=f"100644 blob {blob}\tf.txt\n")
        return self.git("commit-tree", tree, *(["-p", parent] if parent else []), data=message + "\n")

    def branch(self, name="landed", oid=None, merged=True):
        oid = oid or self.commit(name, self.base)
        self.git("update-ref", "refs/heads/" + name, oid)
        if merged:
            self.prs.append({"number": len(self.prs) + 1, "state": "MERGED", "headRefName": name,
                             "headRefOid": oid, "baseRefName": "main", "mergedAt": OLD})
        return oid

    def worktree(self, name="landed", dirname=None):
        oid = self.branch(name)
        path = self.root / (dirname or "wt-" + name)
        self.git("worktree", "add", "-q", str(path), name)
        return path, oid

    def has_branch(self, name="landed"):
        return bool(self.git("for-each-ref", "--format=%(refname)", "refs/heads/" + name))

    def run_gc(self, *args, raw=None, env=None):
        (self.root / "prs.json").write_text(raw if raw is not None else json.dumps(self.prs))
        return subprocess.run(["bash", str(SCRIPT), "--tsv", *args, str(self.repo)],
                              cwd=self.root, env=env or self.env, text=True,
                              capture_output=True, timeout=30, check=False)

    def on_list(self, body):
        (self.root / "on-list.py").write_text(
            "import os, pathlib, sqlite3, subprocess\n"
            "root = pathlib.Path(os.environ['GH_FIXTURE'])\n" + body)

    def t3(self, path, updated=OLD):
        con = sqlite3.connect(self.env["BRANCH_GC_T3_DB"])
        con.executescript("""
          create table projection_threads(thread_id, worktree_path, updated_at, latest_user_message_at,
            pending_approval_count, pending_user_input_count, snoozed_until, deleted_at);
          create table projection_thread_sessions(thread_id, status, active_turn_id, updated_at);
          create table projection_thread_messages(thread_id, created_at, updated_at);
          create table projection_thread_activities(thread_id, created_at);
        """)
        con.execute("insert into projection_threads values ('t', ?, ?, null, 0, 0, null, null)",
                    (str(path), updated))
        con.commit()
        return con

    def test_malformed_tail_cannot_hide_open_pr(self):
        oid = self.branch()
        self.prs[0]["number"] = 3
        self.prs += [{"number": 2, "state": "MERGED", "headRefName": "unrelated", "headRefOid": oid,
                      "baseRefName": "main", "mergedAt": {}},
                     {"number": 1, "state": "OPEN", "headRefName": "landed", "headRefOid": oid,
                      "baseRefName": "main", "mergedAt": None}]
        result = self.run_gc("--apply")
        self.assertTrue(self.has_branch(), result.stdout + result.stderr)
        self.assertNotEqual(result.returncode, 0)

    def test_duplicate_pr_numbers_are_ambiguous(self):
        self.branch()
        self.prs.append(dict(self.prs[0]))
        result = self.run_gc("--apply")
        self.assertTrue(self.has_branch(), result.stdout + result.stderr)
        self.assertNotEqual(result.returncode, 0)

    def test_github_host_cannot_be_redirected_by_environment(self):
        self.branch()
        result = self.run_gc("--dry-run", env=dict(self.env, GH_HOST="enterprise.invalid"))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.root / "gh-host").read_text(), "github.com")

    def test_multiple_origin_urls_skip_entire_repo(self):
        self.branch()
        with (self.repo / ".git/config").open("a") as config:
            config.write('\n[remote "origin"]\n\turl = https://github.com/acme/different.git\n')
        result = self.run_gc("--apply")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.has_branch())

    def test_multiple_json_documents_are_ambiguous(self):
        self.branch()
        (self.root / "total").write_text("1")
        result = self.run_gc("--apply", raw=json.dumps(self.prs) + "\n[]")
        self.assertTrue(self.has_branch(), result.stdout + result.stderr)
        self.assertNotEqual(result.returncode, 0)

    def test_missing_detached_worktree_retains_recovery_metadata(self):
        self.branch()
        detached = self.commit("unlanded", self.base)
        wt = self.root / "detached"
        self.git("worktree", "add", "-q", "--detach", str(wt), detached)
        gd = Path(self.git("rev-parse", "--absolute-git-dir", at=wt))
        # Simulate an unavailable volume, not an intentionally discarded checkout.
        wt.rename(self.root / "offline-volume")
        result = self.run_gc("--apply")
        self.assertTrue((gd / "HEAD").exists(), result.stdout + result.stderr)

    def test_t3_activity_arriving_during_github_lookup_blocks_removal(self):
        wt, _ = self.worktree()
        self.t3(wt).close()
        now = datetime.datetime.now(datetime.timezone.utc).isoformat()
        self.on_list(f"con = sqlite3.connect(str(root / 'state.sqlite'))\n"
                     f"con.execute('update projection_threads set updated_at = ?', ({now!r},))\ncon.commit()\n")
        result = self.run_gc("--apply")
        self.assertTrue(wt.exists(), result.stdout + result.stderr)
        self.assertTrue(self.has_branch())

    def test_invalid_old_message_timestamp_is_not_hidden_by_sql_max(self):
        wt, _ = self.worktree()
        con = self.t3(wt)
        con.executemany("insert into projection_thread_messages values ('t', ?, ?)",
                        [(OLD, OLD), ("0000-invalid", "0000-invalid")])
        con.commit()
        con.close()
        result = self.run_gc("--apply")
        self.assertTrue(wt.exists(), result.stdout + result.stderr)

    def test_configured_t3_home_is_respected(self):
        wt, _ = self.worktree()
        self.t3(wt, datetime.datetime.now(datetime.timezone.utc).isoformat()).close()
        t3home = self.root / "custom-t3"
        (t3home / "userdata").mkdir(parents=True)
        (self.root / "state.sqlite").rename(t3home / "userdata/state.sqlite")
        env = dict(self.env, T3CODE_HOME=str(t3home))
        del env["BRANCH_GC_T3_DB"]
        result = self.run_gc("--apply", env=env)
        self.assertTrue(wt.exists(), result.stdout + result.stderr)

    def test_detached_checkout_created_during_lookup_survives(self):
        wt, _ = self.worktree()
        extra = self.commit("unmerged detached work", self.base)
        self.on_list(f"subprocess.run([os.environ['REAL_GIT'], '-C', {str(wt)!r}, "
                     f"'update-ref', '--no-deref', 'HEAD', {extra!r}], check=True)\n")
        result = self.run_gc("--apply")
        self.assertTrue(wt.exists(), result.stdout + result.stderr)
        self.assertEqual(self.git("rev-parse", "HEAD", at=wt), extra)

    def test_assume_unchanged_does_not_hide_data_from_removal(self):
        wt, _ = self.worktree()
        self.git("update-index", "--assume-unchanged", "f.txt", at=wt)
        (wt / "f.txt").write_text("uncommitted data\n")
        result = self.run_gc("--apply")
        self.assertTrue(wt.exists(), result.stdout + result.stderr)

    def test_status_config_cannot_hide_untracked_data(self):
        wt, _ = self.worktree()
        with (self.repo / ".git/config").open("a") as config:
            config.write("\n[status]\n\tshowUntrackedFiles = no\n")
        (wt / "untracked-research").write_text("data\n")
        result = self.run_gc("--apply")
        self.assertTrue(wt.exists(), result.stdout + result.stderr)
        self.assertIn("worktree dirty", result.stdout)

    def test_main_checkout_cannot_switch_during_ref_delete(self):
        self.branch()
        self.git_interceptor('''
if "update-ref" in args and "-d" in args:
    result = subprocess.run([real, "-C", str(root / "repo"), "symbolic-ref", "HEAD", "refs/heads/landed"], capture_output=True)
    (root / "switch-result").write_text(str(result.returncode))
''')
        result = self.run_gc("--apply")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotEqual((self.root / "switch-result").read_text(), "0")
        self.assertEqual(self.git("symbolic-ref", "HEAD"), "refs/heads/main")

    def test_missing_merge_proof_skips_whole_repo(self):
        self.branch()
        self.branch("also-merged")
        for field, value in (("mergedAt", None), ("mergedAt", "yesterday"),
                             ("mergedAt", "2020-02-31T00:00:00Z"), ("headRefOid", "")):
            with self.subTest(field=field, value=value):
                old = self.prs[0][field]
                self.prs[0][field] = value
                result = self.run_gc("--apply")
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(self.has_branch())
                self.assertTrue(self.has_branch("also-merged"))
                self.prs[0][field] = old

    def test_sequencer_and_index_lock_block_removal(self):
        for marker in ("sequencer", "index.lock"):
            with self.subTest(marker=marker):
                wt, _ = self.worktree(marker.replace(".", "-"))
                gd = Path(self.git("rev-parse", "--absolute-git-dir", at=wt))
                (gd / marker).touch()
                result = self.run_gc("--apply")
                self.assertTrue(wt.exists(), result.stdout + result.stderr)

    def test_branch_names_with_shell_characters_are_literal(self):
        name = "topic/$(id);'quote"
        self.branch(name)
        result = self.run_gc("--apply")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.has_branch(name))

    def test_unauthenticated_gh_does_not_delete_anything(self):
        wt, _ = self.worktree()
        (self.root / "gh-fail").touch()
        result = self.run_gc("--apply")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(wt.exists())
        self.assertTrue(self.has_branch())

    def git_interceptor(self, body):
        self.stub("git", '''#!/usr/bin/env python3
import os, pathlib, subprocess, sys
root = pathlib.Path(os.environ["GH_FIXTURE"])
args = sys.argv[1:]
real = os.environ["REAL_GIT"]
''' + body + '\nos.execv(real, [real, *args])\n')

    def test_tip_moving_at_branch_delete_is_never_deleted(self):
        tip = self.branch()
        extra = self.commit("follow-up", tip)
        self.git_interceptor(f'''
if (("branch" in args and "-D" in args) or ("update-ref" in args and "-d" in args)):
    subprocess.run([real, "-C", str(root / "repo"), "update-ref", "refs/heads/landed", {extra!r}], check=True)
    if "branch" in args:
        result = subprocess.run([real, *args])
        # The branch name gets reused before the old implementation's restore.
        subprocess.run([real, "-C", str(root / "repo"), "update-ref", "refs/heads/landed", {tip!r}], check=True)
        sys.exit(result.returncode)
''')
        result = self.run_gc("--apply")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.git("rev-parse", "landed"), extra)

    def test_ref_and_head_are_locked_until_worktree_is_quarantined(self):
        wt, tip = self.worktree()
        extra = self.commit("concurrent commit", tip)
        self.mv_stub(f'''
if args[-2] == {str(wt)!r}:
    real = os.environ["REAL_GIT"]
    detached = subprocess.run([real, "-C", {str(wt)!r}, "update-ref", "--no-deref", "HEAD", {extra!r}], capture_output=True)
    branch = subprocess.run([real, "-C", {str(wt)!r}, "update-ref", "refs/heads/landed", {extra!r}], capture_output=True)
    (root / "writer-results").write_text(str((detached.returncode, branch.returncode)))
''')
        result = self.run_gc("--apply")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.root / "writer-results").read_text(), "(128, 128)")
        self.assertFalse(wt.exists())

    def test_locks_released_when_git_ref_prepare_fails(self):
        wt, _ = self.worktree()
        self.git_interceptor('''
if "update-ref" in args and "--stdin" in args:
    print("injected prepare failure", file=sys.stderr)
    sys.exit(1)
''')
        result = self.run_gc("--apply")
        self.assertNotEqual(result.returncode, 0)
        gd = Path(self.git("rev-parse", "--absolute-git-dir", at=wt))
        self.assertTrue(wt.exists())
        self.assertFalse((gd / "HEAD.lock").exists())
        self.assertFalse((gd / "index.lock").exists())

    def test_process_entering_worktree_during_lookup_blocks_removal(self):
        wt, _ = self.worktree(dirname="worktree with\ttab\nand newline")
        self.on_list(f'''p = subprocess.Popen(["sleep", "30"], cwd={str(wt)!r},
    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
(root / "pid").write_text(str(p.pid))
(root / "proc" / str(p.pid)).symlink_to("/proc/" + str(p.pid))
''')
        try:
            result = self.run_gc("--apply")
            self.assertTrue(wt.exists(), result.stdout + result.stderr)
            self.assertIn("in use by pid", result.stdout)
        finally:
            if (self.root / "pid").exists():
                os.kill(int((self.root / "pid").read_text()), 15)

    def test_relative_repo_and_t3_paths_use_callers_directory(self):
        wt, _ = self.worktree()
        self.t3(wt, datetime.datetime.now(datetime.timezone.utc).isoformat()).close()
        (self.root / "prs.json").write_text(json.dumps(self.prs))
        result = subprocess.run(["bash", str(SCRIPT), "--apply", "--tsv", "repo"],
                                cwd=self.root, env=dict(self.env, BRANCH_GC_T3_DB="state.sqlite"),
                                text=True, capture_output=True, timeout=30, check=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(wt.exists())
        self.assertIn("T3 thread still active", result.stdout)

    def test_own_user_unreadable_process_is_counted_not_blocking(self):
        # systemd --user and ssh-agent are permanently unreadable on the real host;
        # blocking on them blocked every worktree. Quarantine keeps the files.
        wt, _ = self.worktree()
        pid = self.root / "proc/123"
        pid.mkdir()
        (pid / "cwd").symlink_to(wt)
        pid.chmod(0)
        try:
            result = self.run_gc("--apply")
        finally:
            pid.chmod(0o700)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(wt.exists())
        [entry] = self.entries()
        self.assertTrue((entry / "worktree/f.txt").is_file())
        self.assertIn("skipped 1 own-user unreadable (123 ", self.log())

    def test_other_user_unreadable_process_does_not_block(self):
        if os.stat("/proc/1").st_uid == os.getuid():
            self.skipTest("needs a /proc/1 owned by another user")
        wt, _ = self.worktree()
        (self.root / "proc/1").symlink_to("/proc/1")
        result = self.run_gc("--apply")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(wt.exists())
        self.assertEqual(len(self.entries()), 1)
        self.assertIn("skipped 0 own-user unreadable and 1 other-user", self.log())

    def test_own_user_process_inside_blocks_next_to_foreign_ones(self):
        if os.stat("/proc/1").st_uid == os.getuid():
            self.skipTest("needs a /proc/1 owned by another user")
        wt, _ = self.worktree()
        (self.root / "proc/1").symlink_to("/proc/1")
        p = subprocess.Popen(["sleep", "30"], cwd=wt, stdin=subprocess.DEVNULL,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.addCleanup(p.wait)
        self.addCleanup(p.kill)
        (self.root / "proc" / str(p.pid)).symlink_to(f"/proc/{p.pid}")
        result = self.run_gc("--apply")
        self.assertTrue(wt.exists(), result.stdout + result.stderr)
        self.assertTrue(self.has_branch())
        self.assertIn(f"in use by pid {p.pid} ('sleep')", result.stdout)
        self.assertEqual(self.entries(), [])

    def test_replacement_objects_cannot_forge_ancestry(self):
        tip = self.branch()
        merged = self.commit("merged elsewhere", self.base)
        forged = self.commit("forged parent", tip)
        self.git("update-ref", "refs/replace/" + merged, forged)
        self.prs[0]["headRefOid"] = merged
        result = self.run_gc("--apply")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.has_branch())

    def test_grafts_are_ambiguous(self):
        self.branch()
        (self.repo / ".git/info/grafts").write_text(self.base + "\n")
        result = self.run_gc("--apply")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.has_branch())

    def remote(self, name="origin", tip=None):
        remote = self.root / (name + ".git")
        self.git("init", "-q", "--bare", str(remote), at=self.root)
        self.git("push", "-q", str(remote), (tip or self.base) + ":refs/heads/landed")
        return remote

    def map_origin(self, remote):
        with (self.repo / ".git/config").open("a") as config:
            config.write(f'\n[url "{remote}"]\n\tinsteadOf = https://github.com/acme/widget.git\n')

    def test_remote_pushurl_mismatch_skips_entire_repo(self):
        tip = self.branch()
        fetch = self.remote(tip=tip)
        push = self.remote("other", tip)
        self.map_origin(fetch)
        with (self.repo / ".git/config").open("a") as config:
            config.write(f'\n[remote "origin"]\n\tpushurl = {push}\n')
        result = self.run_gc("--apply", "--remote")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.git("rev-parse", "landed", at=push), tip)
        self.assertTrue(self.has_branch())

    def test_remote_with_invalid_merge_date_is_preserved(self):
        tip = self.branch()
        remote = self.remote(tip=tip)
        self.map_origin(remote)
        self.git("update-ref", "-d", "refs/heads/landed")
        self.prs[0]["mergedAt"] = None
        result = self.run_gc("--apply", "--remote")
        self.assertTrue(self.git("for-each-ref", "refs/heads/landed", at=remote),
                        result.stdout + result.stderr)

    def test_remote_lease_refuses_concurrent_followup(self):
        tip = self.branch()
        remote = self.remote(tip=tip)
        self.map_origin(remote)
        extra = self.commit("remote follow-up", tip)
        # Populate its object before the simulated server-side update.
        self.git("push", "-q", str(remote), extra + ":refs/heads/other")
        self.git_interceptor(f'''
if "push" in args:
    subprocess.run([real, "-C", {str(remote)!r}, "update-ref", "refs/heads/landed", {extra!r}], check=True)
''')
        result = self.run_gc("--apply", "--remote")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.git("rev-parse", "landed", at=remote), extra)

    def test_rebase_occupancy_keeps_original_branch(self):
        wt, tip = self.worktree()
        self.git("update-ref", "--no-deref", "HEAD", tip, at=wt)
        gd = Path(self.git("rev-parse", "--absolute-git-dir", at=wt))
        (gd / "rebase-merge").mkdir()
        (gd / "rebase-merge/head-name").write_text("refs/heads/landed\n")
        result = self.run_gc("--apply")
        self.assertTrue(self.has_branch(), result.stdout + result.stderr)

    def test_daily_sync_runs_gc_last_and_logs_auth_failure_nonfatally(self):
        # OPS's daily-sync: backup (commit, pull), the project stage, then
        # branch-gc --apply last, whose failure is logged and never fatal.
        ops = self.root / "OPS"
        scripts = ops / ".claude-config/bin"
        scripts.mkdir(parents=True)
        (ops / "PROJECTS").mkdir()
        self.git("init", "-q", "-b", "main", str(ops), at=self.root)
        (ops / "README.md").write_text("ops\n")
        self.git("add", "README.md", at=ops)
        self.git("commit", "-q", "-m", "seed", at=ops)
        self.git_interceptor('''
if "pull" in args:
    with (root / "order").open("a") as f: f.write("pull\\n")
    sys.exit(0)
if "push" in args:
    raise SystemExit("unexpected daily-sync push: " + repr(args))
''')
        sync = ops / "PROJECTS/sync-check.sh"
        sync.write_text('#!/bin/sh\nprintf "sync\\n" >> "$GH_FIXTURE/order"\n')
        sync.chmod(0o755)
        gc = scripts / "branch-gc"
        gc.write_text('#!/bin/sh\nprintf "gc %s\\n" "$*" >> "$GH_FIXTURE/order"\n'
                      'echo "gh repo view failed: HTTP 401" >&2\nexit 1\n')
        gc.chmod(0o755)
        daily = SCRIPT.parent.parent / "backup/daily-sync.sh"
        result = subprocess.run(["bash", str(daily)], env=self.env, cwd=self.root,
                                text=True, capture_output=True, timeout=30, check=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.root / "order").read_text().splitlines(),
                         ["pull", "sync", "gc --apply"],
                         (ops / ".claude-config/backup/sync.log").read_text())
        log = (ops / ".claude-config/backup/sync.log").read_text()
        self.assertIn("HTTP 401", log)
        self.assertIn("BRANCH-GC: WARN branch-gc --apply exited non-zero", log)


    # --- quarantine, purge, restore ------------------------------------------------
    def entries(self):
        return sorted(self.trash.iterdir()) if self.trash.exists() else []

    def log(self):
        return (self.root / "log/gc.log").read_text()

    def tool_stub(self, name, real_env, body):
        self.stub(name, f"""#!/usr/bin/env python3
import os, pathlib, subprocess, sys
root = pathlib.Path(os.environ["GH_FIXTURE"])
args = sys.argv[1:]
{body}
real = os.environ[{real_env!r}]
os.execv(real, [real, *args])
""")

    def mv_stub(self, body):
        self.tool_stub("mv", "REAL_MV", body)

    def exdev_for_trash(self):
        # What mv --no-copy prints when rename(2) crosses filesystems (LC_ALL=C).
        return (f"if args[-1].startswith({str(self.trash)!r}):\n"
                "    print(\"mv: cannot move '%s' to '%s': Invalid cross-device link\" % (args[-2], args[-1]), file=sys.stderr)\n"
                "    sys.exit(1)\n")

    def restore(self, entry, *extra):
        return subprocess.run(["bash", str(SCRIPT), "--restore", str(entry), *extra], cwd=self.root,
                              env=self.env, text=True, capture_output=True, timeout=30, check=False)

    def fake_entry(self, days_ago, branch, raw=None, manifest=True):
        moved = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=days_ago)
        entry = self.trash / (moved.strftime("%Y%m%dT%H%M%SZ") + "__acme-widget__" + branch)
        (entry / "worktree").mkdir(parents=True)
        (entry / "worktree/data").write_text("x\n")
        if raw is not None:
            (entry / "manifest.json").write_text(raw)
        elif manifest:
            (entry / "manifest.json").write_text(json.dumps({
                "format": "branch-gc-trash/1", "repo": str(self.repo), "common_dir": str(self.repo / ".git"),
                "worktree": str(self.root / ("wt-" + branch)), "branch": branch, "tip": self.base, "pr": 7,
                "merged_at": OLD, "moved_at": moved.strftime("%Y-%m-%dT%H:%M:%SZ"), "method": "rename",
                "entries": 1, "bytes": 2, "admin_id": "wt-" + branch}))
        return entry

    def test_quarantine_moves_worktree_with_manifest(self):
        wt, tip = self.worktree()
        admin = Path(self.git("rev-parse", "--absolute-git-dir", at=wt))
        result = self.run_gc("--apply")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(wt.exists())
        self.assertFalse(admin.exists())
        self.assertFalse(self.has_branch())
        self.assertNotIn(str(wt), self.git("worktree", "list", "--porcelain"))
        [entry] = self.entries()
        self.assertRegex(entry.name, r"^\d{8}T\d{6}Z__acme-widget__landed$")
        self.assertEqual(stat.S_IMODE(self.trash.stat().st_mode), 0o700)
        self.assertEqual((entry / "worktree/f.txt").read_text(), "base\n")
        self.assertTrue((entry / "git-admin/HEAD").is_file())
        self.assertFalse((entry / "git-admin/HEAD.lock").exists())
        self.assertFalse((entry / "git-admin/index.lock").exists())
        m = json.loads((entry / "manifest.json").read_text())
        self.assertEqual({k: m[k] for k in ("repo", "worktree", "branch", "tip", "pr", "merged_at", "method", "entries")},
                         {"repo": os.path.realpath(self.repo), "worktree": os.path.realpath(wt), "branch": "landed",
                          "tip": tip, "pr": 1, "merged_at": OLD, "method": "rename", "entries": 2})
        self.assertRegex(m["moved_at"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")
        self.assertIn("\tquarantined\t", result.stdout)
        self.assertIn("quarantined worktree " + os.path.realpath(wt), self.log())

    def test_dry_run_says_quarantine_and_creates_no_trash(self):
        wt, _ = self.worktree()
        result = self.run_gc("--dry-run")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("\tquarantine\tmerged PR #1, tip == PR head; worktree clean, would move to trash", result.stdout)
        self.assertTrue(wt.exists())
        self.assertFalse(self.trash.exists())

    def test_ignored_file_written_after_validation_survives_in_trash(self):
        # Finding 1: `git worktree remove` deleted a file a non-Git writer created
        # after the last check. The mv stub is that writer, one step before the move.
        wt, _ = self.worktree()
        (self.repo / ".git/info/exclude").write_text(".env\n")
        self.mv_stub(f"""
if args[-2] == {str(wt)!r}:
    pathlib.Path(args[-2], ".env").write_text("SECRET=written-after-check\\n")
""")
        result = self.run_gc("--apply")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(wt.exists())
        [entry] = self.entries()
        self.assertEqual((entry / "worktree/.env").read_text(), "SECRET=written-after-check\n")

    def test_submodule_worktree_is_kept(self):
        wt, _ = self.worktree()
        (Path(self.git("rev-parse", "--absolute-git-dir", at=wt)) / "modules").mkdir()
        result = self.run_gc("--apply")
        self.assertTrue(wt.exists(), result.stdout + result.stderr)
        self.assertIn("worktree contains submodules", result.stdout)
        self.assertEqual(self.entries(), [])

    def cp_recorder(self):
        # Quarantine and restore move trees only by rename; any cp of a tree is the
        # removed copy-then-delete fallback coming back. The one legitimate cp is the
        # lock-protected copy of git's admin entry into <entry>/git-admin.
        self.tool_stub("cp", "REAL_CP", '''
if not args[-1].endswith("/git-admin"):
    open(root / "cp-calls", "a").write(repr(args) + "\\n")
''')

    def assert_left_in_place(self, wt, admin, text="base\n"):
        self.assertEqual((wt / "f.txt").read_text(), text)
        self.assertTrue(self.has_branch())
        self.assertIn("worktree " + os.path.realpath(wt), self.git("worktree", "list", "--porcelain"))
        self.assertFalse((admin / "HEAD.lock").exists())
        self.assertFalse((admin / "index.lock").exists())
        self.assertEqual(self.entries(), [])
        self.assertFalse((self.root / "cp-calls").exists())

    def test_exdev_rename_is_reported_never_copied(self):
        # A bind mount can share st_dev, so the rename itself is the last word:
        # EXDEV becomes a report row, never a copy and never a failed run.
        wt, _ = self.worktree()
        admin = Path(self.git("rev-parse", "--absolute-git-dir", at=wt))
        self.mv_stub(self.exdev_for_trash())
        self.cp_recorder()
        result = self.run_gc("--apply")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("\treport\tmerged PR #1, tip == PR head; quarantine skipped: worktree on a different "
                      "filesystem than the trash (rename: Invalid cross-device link)", result.stdout)
        self.assert_left_in_place(wt, admin)
        self.assertIn(f"worktree {os.path.realpath(wt)} and branch kept", self.log())

    def test_real_cross_device_trash_is_refused(self):
        shm = Path("/dev/shm")
        if not shm.is_dir() or shm.stat().st_dev == self.root.stat().st_dev:
            self.skipTest("needs /dev/shm on a different filesystem from " + str(self.root))
        trash = Path(tempfile.mkdtemp(dir=shm)) / "trash"
        self.addCleanup(shutil.rmtree, trash.parent)
        env = dict(self.env, BRANCH_GC_TRASH_DIR=str(trash))
        wt, tip = self.worktree()
        admin = Path(self.git("rev-parse", "--absolute-git-dir", at=wt))
        self.cp_recorder()
        reason = ("quarantine skipped: worktree on a different filesystem than the trash "
                  f"(device {wt.stat().st_dev} vs {trash.parent.stat().st_dev})")
        for mode in ("--dry-run", "--apply"):
            result = self.run_gc(mode, env=env)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("\treport\tmerged PR #1, tip == PR head; " + reason, result.stdout)
            self.assertNotIn("quarantine\t", result.stdout)
        self.assert_left_in_place(wt, admin)
        self.assertEqual(self.git("rev-parse", "refs/heads/landed"), tip)
        self.assertFalse(trash.exists())
        # Restore refuses the same crossing before it changes anything.
        self.assertEqual(self.run_gc("--apply").returncode, 0)
        [entry] = self.entries()
        trash.mkdir()
        moved = trash / entry.name
        shutil.move(str(entry), str(moved))
        result = self.restore(moved)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(f"are on different filesystems (device {(moved / 'worktree').stat().st_dev} "
                      f"vs {self.root.stat().st_dev})", result.stderr)
        self.assertIn("restores only by rename, never by copy. Nothing changed.", result.stderr)
        self.assertFalse(wt.exists())
        self.assertFalse(self.has_branch())
        self.assertEqual((moved / "worktree/f.txt").read_text(), "base\n")
        self.assertFalse((moved / "restore-in-progress").exists())
        self.assertFalse((self.root / "cp-calls").exists())

    def test_unreadable_device_fails_closed(self):
        wt, _ = self.worktree()
        admin = Path(self.git("rev-parse", "--absolute-git-dir", at=wt))
        self.tool_stub("stat", "REAL_STAT", f'''
if args[-1] == {os.path.realpath(wt)!r}:
    print("stat: cannot statx: Permission denied", file=sys.stderr)
    sys.exit(1)
''')
        result = self.run_gc("--apply")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("\treport\tmerged PR #1, tip == PR head; cannot compare worktree and trash filesystems",
                      result.stdout)
        self.assert_left_in_place(wt, admin)

    def test_cross_device_trash_via_symlink_parent_is_refused(self):
        shm = Path("/dev/shm")
        if not shm.is_dir() or shm.stat().st_dev == self.root.stat().st_dev:
            self.skipTest("needs /dev/shm on a different filesystem from " + str(self.root))
        outside = Path(tempfile.mkdtemp(dir=shm))
        self.addCleanup(shutil.rmtree, outside)
        parent = self.root / "trash-parent"
        parent.symlink_to(outside, target_is_directory=True)
        trash = parent / "trash"
        wt, _ = self.worktree()
        admin = Path(self.git("rev-parse", "--absolute-git-dir", at=wt))
        self.cp_recorder()
        for mode in ("--dry-run", "--apply"):
            result = self.run_gc(mode, env=dict(self.env, BRANCH_GC_TRASH_DIR=str(trash)))
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("quarantine skipped: worktree on a different filesystem than the trash (device ",
                          result.stdout)
        self.assert_left_in_place(wt, admin)
        self.assertFalse(trash.exists())

    def test_move_failure_keeps_worktree_and_branch(self):
        wt, _ = self.worktree()
        self.mv_stub(f"""
if args[-1].startswith({str(self.trash)!r}):
    print("mv: cannot move: Permission denied", file=sys.stderr)
    sys.exit(1)
""")
        result = self.run_gc("--apply")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((wt / "f.txt").is_file(), result.stdout + result.stderr)
        self.assertTrue(self.has_branch())
        self.assertEqual(self.entries(), [])
        self.assertIn("remove-failed", result.stdout)
        self.assertIn("Permission denied", result.stdout)

    def test_prune_leaves_other_missing_worktree_metadata(self):
        wt, _ = self.worktree()
        offline = self.root / "offline"
        self.git("worktree", "add", "-q", "--detach", str(offline), self.base)
        offline_admin = Path(self.git("rev-parse", "--absolute-git-dir", at=offline))
        offline.rename(self.root / "unmounted")
        result = self.run_gc("--apply")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(wt.exists())
        self.assertTrue((offline_admin / "HEAD").is_file())
        self.assertNotIn(os.path.realpath(wt), self.git("worktree", "list", "--porcelain"))

    def test_worktree_disappearing_after_prune_snapshot_keeps_metadata(self):
        wt, _ = self.worktree()
        offline = self.root / "offline"
        self.git("worktree", "add", "-q", "--detach", str(offline), self.base)
        admin = Path(self.git("rev-parse", "--absolute-git-dir", at=offline))
        self.git_interceptor(f'''
if "worktree" in args and "list" in args and not pathlib.Path({str(wt)!r}).exists() and (root / "offline").exists():
    result = subprocess.run([real, *args], capture_output=True)
    (root / "offline").rename(root / "unmounted")
    sys.stdout.buffer.write(result.stdout)
    sys.stderr.buffer.write(result.stderr)
    sys.exit(result.returncode)
''')
        result = self.run_gc("--apply")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.root / "unmounted/f.txt").exists())
        self.assertEqual((admin / "HEAD").read_text().strip(), self.base)

    def test_purge_honors_age_and_trash_days_zero(self):
        old = self.fake_entry(10, "old")
        (old / "worktree/ro").mkdir()
        (old / "worktree/ro/file").write_text("x\n")
        (old / "worktree/ro").chmod(0o555)
        new = self.fake_entry(1, "new")
        dry = self.run_gc("--dry-run")
        self.assertTrue(old.exists() and new.exists(), dry.stdout + dry.stderr)
        self.assertIn("\tpurge\tmoved ", dry.stdout)
        zero = self.run_gc("--apply", env=dict(self.env, BRANCH_GC_TRASH_DAYS="0"))
        self.assertEqual(zero.returncode, 0, zero.stdout + zero.stderr)
        self.assertTrue(old.exists())
        self.assertIn("purge disabled (BRANCH_GC_TRASH_DAYS=0)", self.log())
        result = self.run_gc("--apply")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(old.exists())
        self.assertTrue((new / "worktree/data").is_file())
        self.assertIn("trash: purged " + str(old), self.log())
        self.assertIn("\tpurged\t", result.stdout)
        bad_days = self.run_gc("--apply", env=dict(self.env, BRANCH_GC_TRASH_DAYS="soon"))
        self.assertEqual(bad_days.returncode, 2)

    def test_purge_skips_malformed_manifest(self):
        kept = [self.fake_entry(30, "garbage", raw="{not json"),
                self.fake_entry(30, "partial", raw=json.dumps({"format": "branch-gc-trash/1",
                                                               "moved_at": "2020-01-01T00:00:00Z"})),
                self.fake_entry(30, "twodocs", raw="{}\n{}"),
                self.fake_entry(30, "nomanifest", manifest=False)]
        outside = self.root / "not-trash"
        outside.mkdir()
        (outside / "precious").write_text("x\n")
        (self.trash / "20200101T000000Z__acme-widget__link").symlink_to(outside)
        result = self.run_gc("--apply")
        self.assertNotEqual(result.returncode, 0)
        for entry in kept:
            self.assertTrue((entry / "worktree/data").is_file(), entry)
        self.assertTrue((outside / "precious").is_file())
        self.assertEqual(result.stdout.count("manifest missing or malformed; kept for manual review"), 4)
        self.assertIn("not a branch-gc trash entry; kept", result.stdout)

    def test_purge_requires_complete_valid_manifest(self):
        kept = []
        for key in ("method", "entries", "bytes", "admin_id"):
            entry = self.fake_entry(30, "missing-" + key)
            m = json.loads((entry / "manifest.json").read_text())
            del m[key]
            (entry / "manifest.json").write_text(json.dumps(m))
            kept.append(entry)
        # "copy" named the removed cross-device fallback; branch-gc writes only "rename".
        for key, value in (("method", "copy"), ("entries", -1), ("bytes", "2"),
                           ("admin_id", "../escape"), ("pr", -1), ("branch", "bad..branch"),
                           ("merged_at", "not-a-date"), ("moved_at", "2020-02-31T00:00:00Z")):
            entry = self.fake_entry(30, "invalid-" + key)
            m = json.loads((entry / "manifest.json").read_text())
            m[key] = value
            (entry / "manifest.json").write_text(json.dumps(m))
            kept.append(entry)
        result = self.run_gc("--apply")
        self.assertNotEqual(result.returncode, 0)
        for entry in kept:
            self.assertTrue((entry / "worktree/data").is_file(), entry)
        self.assertEqual(result.stdout.count("manifest missing or malformed"), len(kept))

    def test_purge_refuses_symlink_root_and_manifest(self):
        entry = self.fake_entry(30, "old")
        manifest = entry / "manifest.json"
        saved = self.root / "manifest.json"
        manifest.rename(saved)
        manifest.symlink_to(saved)
        result = self.run_gc("--apply")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((entry / "worktree/data").is_file())
        manifest.unlink()
        saved.rename(manifest)
        outside = self.root / "outside"
        self.trash.rename(outside)
        self.trash.symlink_to(outside)
        result = self.run_gc("--apply")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("trash root is a symlink", result.stdout)
        self.assertTrue((outside / entry.name / "worktree/data").is_file())

    def test_purge_does_not_follow_interior_links_or_manifest_paths(self):
        entry = self.fake_entry(30, "old")
        outside = self.root / "outside"
        outside.mkdir()
        precious = outside / "data"
        precious.write_text("precious\n")
        precious.chmod(0o400)
        (entry / "worktree/link").symlink_to(outside)
        m = json.loads((entry / "manifest.json").read_text())
        m["worktree"] = str(outside)
        (entry / "manifest.json").write_text(json.dumps(m))
        result = self.run_gc("--apply")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(entry.exists())
        self.assertEqual(precious.read_text(), "precious\n")
        self.assertEqual(stat.S_IMODE(precious.stat().st_mode), 0o400)

    def after_manifest_validation(self, body):
        self.tool_stub("jq", "REAL_JQ", '''
if args == ["-r", ".moved_at | fromdateiso8601"]:
    result = subprocess.run([os.environ["REAL_JQ"], *args], input=sys.stdin.read(), text=True, capture_output=True)
''' + body + '''
    sys.stdout.write(result.stdout)
    sys.stderr.write(result.stderr)
    sys.exit(result.returncode)
''')

    def test_purge_refuses_entry_swapped_for_symlink_after_validation(self):
        entry = self.fake_entry(30, "old")
        outside = self.root / "outside"
        outside.mkdir()
        precious = outside / "data"
        precious.write_text("precious\n")
        precious.chmod(0o400)
        self.after_manifest_validation(f'''
    entry = pathlib.Path({str(entry)!r})
    entry.rename(root / "saved-entry")
    entry.symlink_to(root / "outside")
''')
        result = self.run_gc("--apply")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(precious.read_text(), "precious\n")
        self.assertEqual(stat.S_IMODE(precious.stat().st_mode), 0o400)
        self.assertTrue((self.root / "saved-entry/worktree/data").is_file())

    def test_purge_refuses_manifest_changed_after_validation(self):
        entry = self.fake_entry(30, "old")
        self.after_manifest_validation(f'''
    pathlib.Path({str(entry / 'manifest.json')!r}).write_text("{{broken")
''')
        result = self.run_gc("--apply")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((entry / "worktree/data").is_file())

    def test_restore_round_trip(self):
        wt, tip = self.worktree()
        self.assertEqual(self.run_gc("--apply").returncode, 0)
        [entry] = self.entries()
        (entry / "worktree/late.txt").write_text("written after the check\n")
        result = self.restore(entry.name)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.git("rev-parse", "refs/heads/landed"), tip)
        self.assertEqual(self.git("symbolic-ref", "HEAD", at=wt), "refs/heads/landed")
        self.assertEqual((wt / "f.txt").read_text(), "base\n")
        self.assertEqual(self.git("status", "--porcelain", at=wt), "?? late.txt")
        self.assertIn("worktree " + os.path.realpath(wt), self.git("worktree", "list", "--porcelain"))
        self.assertFalse((entry / "worktree").exists())
        self.assertIn("restored_at", json.loads((entry / "manifest.json").read_text()))
        self.assertIn("re-created", result.stdout)
        again = self.restore(entry)
        self.assertNotEqual(again.returncode, 0)
        self.assertIn("already restored", again.stderr)

    def test_restore_refuses_existing_path_and_moved_branch(self):
        wt, tip = self.worktree()
        self.assertEqual(self.run_gc("--apply").returncode, 0)
        [entry] = self.entries()
        wt.mkdir()
        result = self.restore(entry)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(f"original path {os.path.realpath(wt)} exists", result.stderr)
        self.assertTrue((entry / "worktree/f.txt").is_file())
        wt.rmdir()
        other = self.commit("reused name", self.base)
        self.git("update-ref", "refs/heads/landed", other)
        result = self.restore(entry)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("now points at " + other, result.stderr)
        self.assertEqual(self.git("rev-parse", "refs/heads/landed"), other)
        self.assertFalse(wt.exists())
        self.git("update-ref", "refs/heads/landed", tip, other)
        result = self.restore(entry)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("re-created", result.stdout)
        self.assertEqual(self.git("status", "--porcelain", at=wt), "")

    def test_failed_restore_is_held_and_can_be_retried(self):
        wt, tip = self.worktree()
        self.assertEqual(self.run_gc("--apply").returncode, 0)
        [entry] = self.entries()
        m = json.loads((entry / "manifest.json").read_text())
        m["moved_at"] = OLD
        (entry / "manifest.json").write_text(json.dumps(m))
        self.mv_stub(f'''
if args[-2] == {str(entry / 'worktree')!r}:
    print("injected restore move failure", file=sys.stderr)
    sys.exit(1)
''')
        result = self.restore(entry)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(wt.exists())
        self.assertEqual((entry / "worktree/f.txt").read_text(), "base\n")
        self.assertTrue((entry / "restore-in-progress").is_file())
        result = self.run_gc("--apply")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("interrupted restore; kept for recovery", result.stdout)
        self.assertTrue((entry / "worktree/f.txt").exists())
        self.mv_stub("")
        result = self.restore(entry)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.git("rev-parse", "HEAD", at=wt), tip)
        self.assertEqual(self.git("status", "--porcelain", at=wt), "")
        self.assertFalse((entry / "restore-in-progress").exists())

    def test_restore_holds_branch_and_head_at_manifest_tip(self):
        wt, tip = self.worktree()
        self.assertEqual(self.run_gc("--apply").returncode, 0)
        [entry] = self.entries()
        extra = self.commit("concurrent followup", tip)
        self.git_interceptor(f'''
if "worktree" in args and "add" in args:
    result = subprocess.run([real, "-C", str(root / "repo"), "update-ref", "refs/heads/landed", {extra!r}], capture_output=True)
    (root / "branch-writer-result").write_text(str(result.returncode))
''')
        self.mv_stub(f'''
if args[-2] == {str(entry / 'worktree')!r}:
    result = subprocess.run([os.environ["REAL_GIT"], "-C", args[-2], "symbolic-ref", "HEAD", "refs/heads/main"], capture_output=True)
    (root / "head-writer-result").write_text(str(result.returncode))
''')
        result = self.restore(entry)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.root / "branch-writer-result").read_text(), "128")
        self.assertNotEqual((self.root / "head-writer-result").read_text(), "0")
        self.assertEqual(self.git("rev-parse", "HEAD", at=wt), tip)
        self.assertEqual(self.git("symbolic-ref", "HEAD", at=wt), "refs/heads/landed")

    def test_restore_refuses_tip_moved_before_lock(self):
        wt, tip = self.worktree()
        self.assertEqual(self.run_gc("--apply").returncode, 0)
        [entry] = self.entries()
        extra = self.commit("concurrent followup", tip)
        self.git_interceptor(f'''
if "update-ref" in args and "--stdin" in args:
    subprocess.run([real, "-C", str(root / "repo"), "update-ref", "refs/heads/landed", {extra!r}], check=True)
''')
        result = self.restore(entry)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(wt.exists())
        self.assertEqual((entry / "worktree/f.txt").read_text(), "base\n")
        self.assertEqual(self.git("rev-parse", "refs/heads/landed"), extra)

    def test_restore_refuses_other_filesystem_before_any_change(self):
        wt, tip = self.worktree()
        self.assertEqual(self.run_gc("--apply").returncode, 0)
        [entry] = self.entries()
        self.tool_stub("stat", "REAL_STAT", f'''
if args[:2] == ["-c", "%d"] and args[-1] == {str(entry / "worktree")!r}:
    print(999999)
    sys.exit(0)
''')
        result = self.restore(entry)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("are on different filesystems (device 999999 vs ", result.stderr)
        self.assertIn("Nothing changed.", result.stderr)
        self.assertFalse(wt.exists())
        self.assertFalse(self.has_branch())
        self.assertNotIn(os.path.realpath(wt), self.git("worktree", "list", "--porcelain"))
        self.assertEqual((entry / "worktree/f.txt").read_text(), "base\n")
        self.assertFalse((entry / "restore-in-progress").exists())
        (self.bin / "stat").unlink()
        result = self.restore(entry)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.git("rev-parse", "HEAD", at=wt), tip)
        self.assertEqual(self.git("status", "--porcelain", at=wt), "")

    def test_restore_exdev_rename_is_refused_and_retained(self):
        wt, tip = self.worktree()
        self.assertEqual(self.run_gc("--apply").returncode, 0)
        [entry] = self.entries()
        self.mv_stub(f'''
if args[-2] == {str(entry / "worktree")!r}:
    print("mv: cannot move '%s' to '%s': Invalid cross-device link" % (args[-2], args[-1]), file=sys.stderr)
    sys.exit(1)
''')
        self.cp_recorder()
        result = self.restore(entry)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("different filesystems (rename: Invalid cross-device link)", result.stderr)
        self.assertIn("restores only by rename, never by copy", result.stderr)
        self.assertFalse(wt.exists())
        self.assertEqual((entry / "worktree/f.txt").read_text(), "base\n")
        self.assertTrue((entry / "restore-in-progress").is_file())
        self.assertFalse((self.root / "cp-calls").exists())
        self.mv_stub("")
        result = self.restore(entry)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.git("rev-parse", "HEAD", at=wt), tip)
        self.assertEqual(self.git("status", "--porcelain", at=wt), "")
        self.assertFalse((entry / "restore-in-progress").exists())
        self.assertFalse((self.root / "cp-calls").exists())

    def test_restore_cross_device_symlink_parent_refuses_before_any_change(self):
        shm = Path("/dev/shm")
        if not shm.is_dir() or shm.stat().st_dev == self.root.stat().st_dev:
            self.skipTest("needs /dev/shm on a different filesystem from " + str(self.root))
        outside = Path(tempfile.mkdtemp(dir=shm))
        self.addCleanup(shutil.rmtree, outside)
        wt, tip = self.worktree(dirname="original-parent/wt")
        self.assertEqual(self.run_gc("--apply").returncode, 0)
        [entry] = self.entries()
        wt.parent.rmdir()
        wt.parent.symlink_to(outside, target_is_directory=True)
        result = self.restore(entry)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("are on different filesystems (device ", result.stderr)
        self.assertIn("Nothing changed.", result.stderr)
        self.assertFalse(wt.exists())
        self.assertFalse(self.has_branch())
        self.assertNotIn("refs/heads/landed", self.git("worktree", "list", "--porcelain"))
        self.assertEqual((entry / "worktree/f.txt").read_text(), "base\n")
        self.assertFalse((entry / "restore-in-progress").exists())
        wt.parent.unlink()
        result = self.restore(entry)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.git("rev-parse", "HEAD", at=wt), tip)

    def test_restore_keeps_destination_created_after_validation(self):
        wt, tip = self.worktree()
        self.assertEqual(self.run_gc("--apply").returncode, 0)
        [entry] = self.entries()
        self.mv_stub(f'''
if args[-2] == {str(entry / "worktree")!r}:
    destination = pathlib.Path(args[-1])
    destination.mkdir()
    (root / "destination-inode").write_text(str(destination.stat().st_ino))
''')
        result = self.restore(entry)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(wt.stat().st_ino, int((self.root / "destination-inode").read_text()))
        self.assertEqual(list(wt.iterdir()), [])
        self.assertEqual((entry / "worktree/f.txt").read_text(), "base\n")
        self.assertTrue((entry / "restore-in-progress").is_file())
        # The operator resolves the destination collision, then retries the held entry.
        wt.rmdir()
        self.mv_stub("")
        result = self.restore(entry)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.git("rev-parse", "HEAD", at=wt), tip)
        self.assertEqual(self.git("status", "--porcelain", at=wt), "")

    # --- no-PR containment, merged-PR T3 rule (2026-09-24) ----------------------
    def contained(self, name="agent", oid=None):
        """A no-PR branch whose tip origin/main already holds (the default fixture has none)."""
        self.git("update-ref", "refs/remotes/origin/main", oid or self.base)
        self.branch(name, oid=oid or self.base, merged=False)

    def backdate(self, path, when):
        gd = Path(self.git("rev-parse", "--absolute-git-dir", at=path))
        for top in (path, gd):
            for root, dirs, files in os.walk(top):
                for name in dirs + files:
                    os.utime(os.path.join(root, name), (when, when), follow_symlinks=False)
            os.utime(top, (when, when))
        return gd

    def ago(self, hours):
        return int(datetime.datetime.now(datetime.timezone.utc).timestamp()) - hours * 3600

    def nopr_worktree(self, name="agent", hours=100):
        self.contained(name)
        path = self.root / ("wt-" + name)
        subprocess.check_output([self.real_git, "-C", str(self.repo), "worktree", "add", "-q", str(path), name],
                                env=dict(self.env, GIT_COMMITTER_DATE="@%d +0000" % self.ago(hours)), text=True)
        self.backdate(path, self.ago(hours))
        return path

    def git_calls(self):
        path = self.root / "git-calls"
        return [line.split("\x1f") for line in path.read_text().splitlines()] if path.exists() else []

    def record_git_calls(self, extra=""):
        self.git_interceptor('open(root / "git-calls", "a").write("\\x1f".join(args) + "\\n")\n' + extra)

    def test_contained_nopr_branch_is_deleted_with_branch_d_only(self):
        self.contained()
        self.record_git_calls()
        result = self.run_gc("--apply")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.has_branch("agent"))
        self.assertIn("\tremoved\tno PR; tip and reflog contained in origin/main", result.stdout)
        calls = self.git_calls()
        self.assertTrue(any(c[-4:] == ["branch", "-d", "--", "agent"] for c in calls), calls)
        self.assertFalse([c for c in calls if "-D" in c or ("update-ref" in c and "-d" in c)], calls)

    def test_nopr_tip_change_at_branch_d_keeps_unpushed_work(self):
        self.contained()
        private = self.commit("private main commit", self.base)
        # branch -d alone accepts the new tip because local main contains it.
        self.git("update-ref", "refs/heads/main", private)
        self.git_interceptor(f'''
if "branch" in args and "-d" in args:
    subprocess.run([real, "-C", str(root / "repo"), "update-ref", "refs/heads/agent", {private!r}], check=True)
''')
        result = self.run_gc("--apply")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.git("rev-parse", "agent"), private)
        self.assertIn("tip changed before the deletion lock", self.log())

    def test_nopr_reset_at_branch_d_keeps_reflog_only_work(self):
        self.contained()
        private = self.commit("private reset-away work", self.base)
        self.git_interceptor(f'''
if "branch" in args and "-d" in args:
    for oid in ({private!r}, {self.base!r}):
        subprocess.run([real, "-C", str(root / "repo"), "update-ref", "refs/heads/agent", oid], check=True)
''')
        result = self.run_gc("--apply")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.has_branch("agent"))
        self.assertIn(private, self.git("reflog", "show", "--format=%H", "agent"))
        self.assertIn("branch reflog changed or is uncontained", self.log())

    def test_nopr_quarantine_rechecks_branch_reflog_under_ref_lock(self):
        wt = self.nopr_worktree()
        private = self.commit("private reset before quarantine", self.base)
        self.git_interceptor(f'''
if "update-ref" in args and "--stdin" in args and not (root / "raced").exists():
    (root / "raced").touch()
    for oid in ({private!r}, {self.base!r}):
        subprocess.run([real, "-C", str(root / "repo"), "update-ref", "refs/heads/agent", oid], check=True)
''')
        result = self.run_gc("--apply")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(wt.exists())
        self.assertTrue(self.has_branch("agent"))
        self.assertIn(private, self.git("reflog", "show", "--format=%H", "agent"))
        self.assertEqual(self.entries(), [])

    def test_deletion_guard_preserves_configured_reference_hook_veto(self):
        self.contained()
        hooks = self.root / "custom hooks"
        hooks.mkdir()
        hook = hooks / "reference-transaction"
        hook.write_text('#!/bin/sh\ncat > "$GH_FIXTURE/hook-input"\n'
                        'printf "%s\\n" "$1" >> "$GH_FIXTURE/hook-phases"\n'
                        '[ "$1" != prepared ]\n')
        hook.chmod(0o755)
        self.git("config", "core.hooksPath", str(hooks))
        result = self.run_gc("--apply")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.has_branch("agent"))
        self.assertIn("prepared", (self.root / "hook-phases").read_text())
        self.assertIn("refs/heads/agent", (self.root / "hook-input").read_text())
        self.assertEqual(self.git("config", "core.hooksPath"), str(hooks))

    def test_deletion_guard_chains_successful_reference_hook(self):
        self.contained()
        hook = self.repo / ".git/hooks/reference-transaction"
        hook.write_text('#!/bin/sh\ncat >> "$GH_FIXTURE/hook-input"\n'
                        'printf "%s\\n" "$1" >> "$GH_FIXTURE/hook-phases"\n')
        hook.chmod(0o755)
        result = self.run_gc("--apply")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.has_branch("agent"))
        phases = (self.root / "hook-phases").read_text().splitlines()
        self.assertIn("prepared", phases)
        self.assertIn("committed", phases)

    def test_merged_branch_keeps_reset_away_reflog_work(self):
        tip = self.branch()
        private = self.commit("private reset-away work", tip)
        for oid in (private, tip):
            self.git("update-ref", "refs/heads/landed", oid)
        result = self.run_gc("--apply")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.has_branch())
        self.assertIn("reflog contains work not covered", result.stdout)

    def test_merged_worktree_keeps_head_reflog_work(self):
        wt, tip = self.worktree()
        private = self.commit("private detached work", tip)
        for oid in (private, tip):
            self.git("update-ref", "HEAD", oid, at=wt)
        self.git("reflog", "expire", "--expire=all", "refs/heads/landed")
        result = self.run_gc("--apply")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(wt.exists())
        self.assertTrue(self.has_branch())
        self.assertIn(private, self.git("rev-list", "--all", "--reflog"))

    def test_merged_reset_at_deletion_keeps_reflog_work(self):
        tip = self.branch()
        private = self.commit("private reset at delete", tip)
        self.git_interceptor(f'''
if "update-ref" in args and "-d" in args and "refs/heads/landed" in args:
    for oid in ({private!r}, {tip!r}):
        subprocess.run([real, "-C", str(root / "repo"), "update-ref", "refs/heads/landed", oid], check=True)
''')
        result = self.run_gc("--apply")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.has_branch())
        self.assertIn(private, self.git("reflog", "show", "--format=%H", "landed"))

    def test_new_worktree_registration_at_deletion_keeps_branch(self):
        self.branch()
        wt = self.root / "late-checkout"
        self.git_interceptor(f'''
if "update-ref" in args and "-d" in args and "refs/heads/landed" in args:
    subprocess.run([real, "-C", str(root / "repo"), "worktree", "add", "--no-checkout", "-q", {str(wt)!r}, "landed"], check=True)
''')
        result = self.run_gc("--apply")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(wt.exists())
        self.assertTrue(self.has_branch())
        self.assertEqual(self.git("symbolic-ref", "HEAD", at=wt), "refs/heads/landed")
        self.assertIn("branch is now checked out", self.log())

    def test_worktree_registration_after_final_scan_keeps_branch(self):
        # worktree add --no-checkout takes no branch ref lock, so no read made
        # before the ref commit can see this registration. branch-gc re-reads
        # every worktree HEAD after the delete and re-creates the branch at its
        # proven tip, failing the run loudly.
        for kind, branch in (("merged", "landed"), ("no-pr", "agent")):
            with self.subTest(kind=kind):
                self.setUp()
                if kind == "merged":
                    self.branch()
                else:
                    self.contained()
                wt = self.root / "after-last-check"
                # Git prepends its exec path inside hooks. Route that through
                # the fixture interceptor so the interleaving is deterministic.
                self.env["GIT_EXEC_PATH"] = str(self.bin)
                self.git_interceptor(f'''
if args[:2] == ["for-each-ref", "--format=%(worktreepath)"]:
    scan = subprocess.run([real, *args], capture_output=True, check=True)
    environment = dict(os.environ)
    environment.pop("GIT_CONFIG_PARAMETERS", None)
    # An independent creator does not inherit the GC command's hook override.
    subprocess.run([real, "-C", str(root / "repo"), "worktree", "add", "--no-checkout", "-q", {str(wt)!r}, {branch!r}],
                   capture_output=True, env=environment, check=True)
    (root / "lock-held-at-registration").write_text(str((root / "repo/.git/refs/heads/{branch}.lock").exists()))
    sys.stdout.buffer.write(scan.stdout)
    sys.exit(scan.returncode)
''')
                result = self.run_gc("--apply")
                self.assertEqual((self.root / "lock-held-at-registration").read_text(), "True")
                self.assertTrue(wt.exists())
                self.assertTrue(self.has_branch(branch), result.stdout + result.stderr)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.git("symbolic-ref", "HEAD", at=wt), f"refs/heads/{branch}")
                self.assertIn("branch re-created at", self.log())

    def test_quarantine_survives_ordinary_git_gc_until_restore(self):
        wt, tip = self.worktree()
        result = self.run_gc("--apply")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        [entry] = self.entries()
        manifest = json.loads((entry / "manifest.json").read_text())
        pin = manifest["retention_ref"]
        # Git ages objects by their existing mtime, not the quarantine date.
        loose = self.repo / ".git/objects" / tip[:2] / tip[2:]
        os.utime(loose, (self.ago(24 * 30),) * 2)
        self.git("gc")
        result = self.restore(entry)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.git("rev-parse", "HEAD", at=wt), tip)
        self.assertEqual(self.git("for-each-ref", pin), "")

    def test_purge_releases_only_its_retention_ref(self):
        self.worktree()
        self.assertEqual(self.run_gc("--apply").returncode, 0)
        [entry] = self.entries()
        manifest = json.loads((entry / "manifest.json").read_text())
        pin = manifest["retention_ref"]
        manifest["moved_at"] = OLD
        (entry / "manifest.json").write_text(json.dumps(manifest))
        other = "refs/branch-gc-trash/other-entry"
        self.git("update-ref", other, self.base)
        result = self.run_gc("--apply")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(entry.exists())
        self.assertEqual(self.git("for-each-ref", pin), "")
        self.assertEqual(self.git("rev-parse", other), self.base)

    def test_nopr_branch_with_its_own_commit_is_kept(self):
        self.git("update-ref", "refs/remotes/origin/main", self.base)
        self.branch("agent", merged=False)
        result = self.run_gc("--apply")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.has_branch("agent"))
        self.assertIn("no PR; tip has 1 commit(s) not in origin/main", result.stdout)

    def test_nopr_without_origin_default_ref_is_report_only(self):
        self.branch("agent", oid=self.base, merged=False)
        result = self.run_gc("--apply")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.has_branch("agent"))
        self.assertIn("refs/remotes/origin/main not found; containment unprovable", result.stdout)

    def test_nopr_ambiguous_default_branch_is_report_only(self):
        self.contained()
        self.git("update-ref", "refs/remotes/origin/trunk", self.base)
        self.git("symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/trunk")
        result = self.run_gc("--apply")
        self.assertTrue(self.has_branch("agent"), result.stdout + result.stderr)
        self.assertIn("default branch ambiguous (origin/HEAD is trunk, GitHub says main)", result.stdout)

    def test_nopr_contained_in_origin_but_not_head_is_kept(self):
        # The main checkout lags origin: git branch -d checks HEAD, so it would refuse.
        ahead = self.commit("landed upstream", self.base)
        self.contained(oid=ahead)
        result = self.run_gc("--apply")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.has_branch("agent"))
        self.assertIn("git branch -d would refuse: tip not merged into HEAD", result.stdout)

    def test_nopr_upstream_that_lacks_the_tip_is_kept(self):
        # With an upstream configured, git branch -d judges against it, not HEAD.
        ahead = self.commit("landed upstream", self.base)
        self.git("update-ref", "refs/heads/main", ahead)
        self.git("read-tree", "--reset", "-u", ahead)
        self.contained(oid=ahead)
        self.git("update-ref", "refs/remotes/origin/stale", self.base)
        self.git("config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*")
        self.git("config", "branch.agent.remote", "origin")
        self.git("config", "branch.agent.merge", "refs/heads/stale")
        result = self.run_gc("--apply")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.has_branch("agent"))
        self.assertIn("git branch -d would refuse: tip not merged into origin/stale", result.stdout)

    def test_nopr_branch_moved_at_delete_is_refused_by_git(self):
        self.contained()
        work = self.commit("lane work landing right now", self.base)
        self.record_git_calls(
            'if "branch" in args and "-d" in args:\n'
            f'    subprocess.run([real, "-C", str(root / "repo"), "update-ref", "refs/heads/agent", {work!r}], check=True)\n')
        result = self.run_gc("--apply")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.git("rev-parse", "refs/heads/agent"), work)
        self.assertIn("remove-failed", result.stdout)

    def test_nopr_branch_held_by_rebase_is_kept(self):
        self.contained()
        wt = self.root / "rebasing"
        self.git("worktree", "add", "-q", "--detach", str(wt), self.base)
        gd = Path(self.git("rev-parse", "--absolute-git-dir", at=wt))
        (gd / "rebase-merge").mkdir()
        (gd / "rebase-merge/head-name").write_text("refs/heads/agent\n")
        result = self.run_gc("--apply")
        self.assertTrue(self.has_branch("agent"), result.stdout + result.stderr)
        self.assertNotEqual(result.returncode, 0)

    def test_idle_nopr_worktree_is_quarantined_and_restorable(self):
        wt = self.nopr_worktree()
        result = self.run_gc("--apply")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(wt.exists())
        self.assertFalse(self.has_branch("agent"))
        [entry] = self.entries()
        m = json.loads((entry / "manifest.json").read_text())
        self.assertEqual({k: m[k] for k in ("pr", "merged_at", "basis", "contained_in", "branch", "tip")},
                         {"pr": None, "merged_at": None, "basis": "contained",
                          "contained_in": "refs/remotes/origin/main", "branch": "agent", "tip": self.base})
        restored = self.restore(entry)
        self.assertEqual(restored.returncode, 0, restored.stdout + restored.stderr)
        self.assertEqual(self.git("rev-parse", "refs/heads/agent"), self.base)
        self.assertEqual(self.git("status", "--porcelain", at=wt), "")

    def test_nopr_worktree_touched_under_the_locks_is_kept(self):
        # The last write lands after the unlocked check and before the move.
        wt = self.nopr_worktree()
        self.git_interceptor(
            'if "update-ref" in args and "--stdin" in args:\n'
            f'    pathlib.Path({str(wt / "f.txt")!r}).touch()\n')
        result = self.run_gc("--apply")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((wt / "f.txt").is_file(), result.stdout + result.stderr)
        self.assertTrue(self.has_branch("agent"))
        self.assertIn("no-PR worktrees wait 72h idle", result.stdout)
        self.assertEqual(self.entries(), [])

    def test_nopr_worktree_without_head_reflog_is_kept(self):
        wt = self.nopr_worktree()
        gd = Path(self.git("rev-parse", "--absolute-git-dir", at=wt))
        (gd / "logs/HEAD").unlink()
        result = self.run_gc("--apply")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(wt.exists())
        self.assertIn("idle time unknown", result.stdout)

    def test_nopr_worktree_reset_away_work_in_head_reflog_is_kept(self):
        wt = self.nopr_worktree()
        work = self.commit("lane work later reset away", self.base)
        self.git("update-ref", "-m", "work", "HEAD", work, at=wt)
        self.git("update-ref", "-m", "reset", "HEAD", self.base, at=wt)
        self.git("reflog", "expire", "--expire=all", "refs/heads/agent")
        self.backdate(wt, self.ago(100))
        result = self.run_gc("--apply")
        self.assertTrue(wt.exists(), result.stdout + result.stderr)
        self.assertIn("worktree HEAD reflog records " + work[:12], result.stdout)

    def test_branch_deletion_lock_churn_does_not_make_worktrees_look_touched(self):
        # delete_branch_locked holds a HEAD.lock in every admin dir; that churn
        # must not count as a lane touching an idle no-PR worktree.
        wt = self.nopr_worktree()
        self.branch("landed")
        result = self.run_gc("--apply")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.has_branch("landed"))
        self.assertFalse(wt.exists())

    def merged_t3(self, merged_h, active_h, **thread):
        wt, _ = self.worktree()
        now = datetime.datetime.now(datetime.timezone.utc)
        self.prs[0]["mergedAt"] = (now - datetime.timedelta(hours=merged_h)).strftime("%Y-%m-%dT%H:%M:%SZ")
        con = self.t3(wt, (now - datetime.timedelta(hours=active_h)).isoformat())
        for column, value in thread.items():
            con.execute("update projection_threads set %s = ?" % column, (value,))
        con.commit()
        con.close()
        return wt

    def test_t3_activity_before_the_merge_does_not_hold_merged_worktree(self):
        wt = self.merged_t3(30, 40)
        result = self.run_gc("--apply")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(wt.exists())
        self.assertIn("newest activity predates the merge; not holding", self.log())

    def test_t3_activity_after_the_merge_holds_merged_worktree(self):
        wt = self.merged_t3(30, 10)
        result = self.run_gc("--apply")
        self.assertTrue(wt.exists(), result.stdout + result.stderr)
        self.assertIn("T3 thread still active", result.stdout)

    def test_t3_waiting_or_snoozed_holds_even_before_the_merge(self):
        future = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=1)).isoformat()
        for thread in ({"pending_approval_count": 1}, {"pending_user_input_count": 2}, {"snoozed_until": future}):
            with self.subTest(thread=thread):
                self.setUp()
                wt = self.merged_t3(30, 40, **thread)
                result = self.run_gc("--apply")
                self.assertTrue(wt.exists(), result.stdout + result.stderr)
                self.assertIn("T3 thread still active", result.stdout)

    def test_purge_accepts_only_complete_nopr_manifests(self):
        def nopr(entry, **changes):
            m = json.loads((entry / "manifest.json").read_text())
            m.update({"pr": None, "merged_at": None, "basis": "contained",
                      "contained_in": "refs/remotes/origin/main"})
            m.update(changes)
            (entry / "manifest.json").write_text(json.dumps({k: v for k, v in m.items() if v != "DROP"}))
            return entry
        good = nopr(self.fake_entry(30, "nopr-good"))
        kept = [nopr(self.fake_entry(30, "no-basis"), basis="DROP"),
                nopr(self.fake_entry(30, "basis-with-pr"), pr=7),
                nopr(self.fake_entry(30, "bad-ref"), contained_in="main"),
                nopr(self.fake_entry(30, "date-without-pr"), merged_at=OLD),
                nopr(self.fake_entry(30, "no-merged-at"), merged_at="DROP")]
        result = self.run_gc("--apply")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(good.exists(), result.stdout)
        for entry in kept:
            self.assertTrue((entry / "worktree/data").is_file(), entry)
        self.assertEqual(result.stdout.count("manifest missing or malformed"), len(kept))

    def test_restore_usage_errors(self):
        for args in (("--apply",), ("--remote",), (str(self.repo),)):
            with self.subTest(args=args):
                self.assertEqual(self.restore("x", *args).returncode, 2)
        missing = subprocess.run(["bash", str(SCRIPT), "--restore"], env=self.env, text=True,
                                 capture_output=True, timeout=30, check=False)
        self.assertEqual(missing.returncode, 2)


if __name__ == "__main__":
    unittest.main()
