#!/usr/bin/env python3
"""Pin sandbox-run's source identity across both invocations, its refusal of
a bwrap that can be replaced, and what it may make writable.

No namespaces or payload commands run here. An inert bwrap recorder inspects
the arguments and source inodes it receives (the source tests also swap one
fixture path for a symlink after the dry run). A private runner copy accepts
the recorder: the expected bwrap owner becomes this user, and except for the
refusal test the walk over the directories above bwrap is skipped (the fixture
lives under /tmp, which anyone can write). Path validation and mount argument
construction stay the production code. Every fixture and cleanup stays inside
TemporaryDirectory, so these tests also run inside sandbox-run (the mutation
checks of the bind policy run them there).
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

RUNNER = Path(__file__).resolve().parents[1] / "sandbox-run"


def runner_copies(test, root):
    """(walking, runner): private copies of sandbox-run that trust a bwrap
    owned by this user; runner also skips the walk above bwrap."""
    text = RUNNER.read_text()
    owner = '[ "${_owner:-}" = 0 ]'
    walk = 'while [ "$_d" != / ]; do'
    test.assertEqual(text.count(owner), 1)
    test.assertEqual(text.count(walk), 1)
    text = text.replace(owner, f'[ "${{_owner:-}}" = {os.getuid()} ]')
    # The walk stays in this copy: a bwrap in a directory the user can write
    # is what it must refuse.
    walking = root / "sandbox-run-walk"
    walking.write_text(text)
    runner = root / "sandbox-run"
    runner.write_text(text.replace(walk, "while false; do"))
    return walking, runner


class SourceIdentityTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.source = self.root / "source"
        self.home = self.root / "home"
        self.home.mkdir()
        self.record = self.root / "record.json"
        self.fake = self.root / "bwrap"
        self.fake.write_text(f"#!{sys.executable}\n" + '''
import json, os, sys
from pathlib import Path

source = Path(os.environ["SB_TEST_SOURCE"])
record = Path(os.environ["SB_TEST_RECORD"])
rows = json.loads(record.read_text()) if record.exists() else []
args = sys.argv[1:]
for i, arg in enumerate(args[:-2]):
    if arg not in ("--bind", "--ro-bind", "--bind-fd", "--ro-bind-fd"):
        continue
    if args[i + 2] != str(source):
        continue
    st = os.fstat(int(args[i + 1])) if arg.endswith("-fd") else os.stat(args[i + 1])
    rows.append([st.st_dev, st.st_ino])
    break
record.write_text(json.dumps(rows))
if len(rows) == 1:
    source.rename(source.with_name("moved"))
    source.symlink_to(os.environ["HOME"])
''')
        self.fake.chmod(0o755)
        self.walking, self.runner = runner_copies(self, self.root)

    def run_race(self, option, file=False):
        if file:
            self.source.write_text("fixture\n")
        else:
            self.source.mkdir()
        st = self.source.stat()
        expected = [st.st_dev, st.st_ino]
        env = dict(os.environ, PATH=str(self.root) + os.pathsep + os.environ["PATH"],
                   HOME=str(self.home), SB_TEST_SOURCE=str(self.source), SB_TEST_RECORD=str(self.record))
        args = ["bash", str(self.runner), option, str(self.source), "--chdir", str(self.root)]
        if option == "--ro-bind":
            args.append("--no-bind")
        # The recorder never dispatches this command. Even a broken test stub
        # can only run /bin/true, never a destructive tool.
        r = subprocess.run([*args, "--", "/bin/true"], cwd=self.root, env=env,
                           capture_output=True, text=True, timeout=30, check=False)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(json.loads(self.record.read_text()), [expected, expected],
                         "the second bwrap opened the replacement home instead of the validated source")

    def test_writable_bind_keeps_the_validated_directory(self):
        self.run_race("--bind")

    def test_readonly_bind_keeps_the_validated_directory(self):
        self.run_race("--ro-bind")

    def test_readonly_bind_keeps_the_validated_file(self):
        self.run_race("--ro-bind", file=True)

    def test_a_bwrap_in_a_directory_the_user_can_change_is_refused(self):
        # Root owning the file is not enough: its directory here is this
        # user's, so the file could be renamed away and replaced before the
        # exec. The walk must refuse it before bwrap ever runs.
        env = dict(os.environ, PATH=str(self.root) + os.pathsep + os.environ["PATH"],
                   SB_TEST_SOURCE=str(self.source), SB_TEST_RECORD=str(self.record))
        r = subprocess.run(["bash", str(self.walking), "--no-bind", "--", "/bin/true"],
                           cwd=self.root, env=env, capture_output=True, text=True,
                           timeout=30, check=False)
        self.assertEqual(r.returncode, 4, r.stdout + r.stderr)
        real = Path(os.path.realpath(self.fake))
        self.assertIn("%s, a directory above %s" % (real.parent, real), r.stderr)
        self.assertFalse(self.record.exists(), "bwrap ran from a directory the user can change")

    def test_a_fifo_named_bwrap_is_refused_without_blocking(self):
        self.fake.unlink()
        os.mkfifo(self.fake, mode=0o755)
        env = dict(os.environ, PATH=str(self.root) + os.pathsep + os.environ["PATH"])
        r = subprocess.run(["bash", str(self.runner), "--no-bind", "--", "/bin/true"],
                           cwd=self.root, env=env, capture_output=True, text=True,
                           timeout=3, check=False)
        self.assertEqual(r.returncode, 4, r.stdout + r.stderr)
        self.assertIn("not an executable regular file", r.stderr)
        self.assertFalse(self.record.exists())


class BindPolicyTests(unittest.TestCase):
    """Nothing writable by default; never a primary checkout; a linked worktree
    is fine. The fixture repositories are made by hand in the layout git
    writes (sandbox-run-test.sh checks git agrees with it)."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(os.path.realpath(tmp.name))
        self.home = self.root / "home"
        self.home.mkdir()
        self.record = self.root / "record.json"
        fake = self.root / "bwrap"
        fake.write_text(f"#!{sys.executable}\n" + '''
import json, os, sys
from pathlib import Path

record = Path(os.environ["SB_TEST_RECORD"])
rows = json.loads(record.read_text()) if record.exists() else []
rows.append(sys.argv[1:])
record.write_text(json.dumps(rows))
''')
        fake.chmod(0o755)
        _, self.runner = runner_copies(self, self.root)
        r = self.root
        git = r / "prim/.git"
        for d in ("prim/sub", "prim/.git/objects", "prim/.git/refs", "prim/.git/modules/sm", "wt", "wt2", "sm",
                  "hollow/.git", "hollow/sub"):
            (r / d).mkdir(parents=True)
        (git / "HEAD").write_text("ref: refs/heads/main\n")
        for w in ("wt", "wt2"):
            (git / "worktrees" / w).mkdir(parents=True)
            (git / "worktrees" / w / "HEAD").write_text("ref: refs/heads/%s\n" % w)
            (git / "worktrees" / w / "commondir").write_text("../..\n")
        (r / "wt/.git").write_text("gitdir: %s\n" % (git / "worktrees/wt"))
        (r / "wt2/.git").write_text("gitdir: ../prim/.git/worktrees/wt2\n")
        (r / "sm/.git").write_text("gitdir: %s\n" % (git / "modules/sm"))

    def run_runner(self, *args, cwd=None):
        if self.record.exists():
            self.record.unlink()
        env = dict(os.environ, PATH=str(self.root) + os.pathsep + os.environ["PATH"],
                   HOME=str(self.home), SB_TEST_RECORD=str(self.record))
        # The recorder never dispatches the command; /bin/true in any case.
        return subprocess.run(["bash", str(self.runner), *args, "--chdir", str(self.root), "--", "/bin/true"],
                              cwd=cwd or self.root, env=env, capture_output=True, text=True,
                              timeout=30, check=False)

    def writable(self):
        """The writable mount destinations of each bwrap invocation recorded."""
        rows = json.loads(self.record.read_text())
        self.assertEqual(len(rows), 2, rows)   # the /bin/true dry run, then the command
        return [[a[i + 2] for i in range(len(a) - 2) if a[i] in ("--bind", "--bind-fd", "--dev-bind")]
                for a in rows]

    def test_nothing_is_writable_by_default_even_inside_a_work_tree(self):
        for start in ("prim", "prim/sub", "wt", "wt2"):
            for flags in ((), ("--no-bind",)):
                with self.subTest(start=start, flags=flags):
                    r = self.run_runner(*flags, cwd=self.root / start)
                    self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
                    self.assertEqual(self.writable(), [[], []])

    def test_a_primary_checkout_or_anything_in_it_is_refused_before_bwrap_runs(self):
        for target, why in (("prim", "prim is the primary checkout of a repository"),
                            ("prim/sub", "prim is the primary checkout of a repository"),
                            ("prim/.git", "prim/.git is a git directory"),
                            ("prim/.git/worktrees/wt", "prim/.git is a git directory"),
                            ("sm", "does not name a linked worktree")):
            with self.subTest(target=target):
                r = self.run_runner("--bind", str(self.root / target))
                self.assertEqual(r.returncode, 3, r.stdout + r.stderr)
                self.assertIn("refusing %s: " % (self.root / target), r.stderr)
                self.assertIn(why, r.stderr)
                self.assertFalse(self.record.exists(), "bwrap ran with a shared checkout writable")

    def test_a_linked_worktree_is_the_one_writable_mount(self):
        for w in ("wt", "wt2"):
            with self.subTest(worktree=w):
                r = self.run_runner("--bind", str(self.root / w))
                self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
                self.assertEqual(self.writable(), [[str(self.root / w)]] * 2)

    def test_a_plain_scratch_directory_is_allowed(self):
        (self.root / "scratch").mkdir()
        # hollow/.git is empty, as a sandbox's mount target leaves it: git does
        # not take it for a repository, and neither does sandbox-run.
        for d in ("scratch", "hollow/sub"):
            with self.subTest(dir=d):
                r = self.run_runner("--bind", str(self.root / d))
                self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
                self.assertEqual(self.writable(), [[str(self.root / d)]] * 2)


if __name__ == "__main__":
    unittest.main()
