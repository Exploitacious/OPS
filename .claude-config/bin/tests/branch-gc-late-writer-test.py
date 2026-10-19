#!/usr/bin/env python3
"""Late writers against quarantine: branch-gc moves a worktree only by rename.

The removed cross-device copy/verify/delete fallback destroyed a same-size edit
made after the copy and a file written through a retained cwd after
verification, and the run still reported success. These gates pin what replaced
it: a candidate on another filesystem is reported and left exactly where it is,
and a same-filesystem rename keeps every byte a writer adds afterwards.

Run directly with python3 -B; fixtures and stubs come from branch-gc-safety-test.py.
"""
import os, runpy; runpy.run_path(os.path.join(os.path.dirname(os.path.realpath(__file__)), "..", "sandbox_guard.py"))["require"]()
import os
import runpy
import subprocess
import sys
import time
import unittest
from pathlib import Path

HELPERS = runpy.run_path(str(Path(__file__).with_name("branch-gc-safety-test.py")))
REASON = "quarantine skipped: worktree on a different filesystem than the trash ("


def wait_for(path, what, seconds=10):
    deadline = time.monotonic() + seconds
    while not path.exists():
        if time.monotonic() > deadline:
            raise AssertionError(what + " never happened")
        time.sleep(0.01)


class LateWriters(unittest.TestCase):
    def fixture(self):
        case = HELPERS["BranchGcSafety"]()
        case.setUp()
        self.addCleanup(case.doCleanups)
        return case

    def test_cross_device_candidate_is_reported_and_untouched(self):
        # Both ways a crossing shows up: st_dev differs before the attempt, or the
        # rename itself returns EXDEV (a bind mount shares st_dev). Each hook is
        # also the late writer: a same-size edit and a new file, landing after
        # every status check and before or during the refused rename.
        write_late = ('    pathlib.Path(%r, "f.txt").write_text("late\\n")\n'
                      '    pathlib.Path(%r, "late.txt").write_text("precious\\n")\n')
        for mechanism in ("st_dev", "EXDEV"):
            with self.subTest(mechanism=mechanism):
                c = self.fixture()
                wt, tip = c.worktree()
                real_wt = os.path.realpath(wt)
                admin = Path(c.git("rev-parse", "--absolute-git-dir", at=wt))
                if mechanism == "st_dev":
                    c.tool_stub("stat", "REAL_STAT",
                                f"if args[:2] == ['-c', '%d'] and args[-1] == {real_wt!r}:\n"
                                + write_late % (real_wt, real_wt)
                                + "    print(999999)\n    sys.exit(0)\n")
                else:
                    c.mv_stub(f"if args[-1].startswith({str(c.trash)!r}):\n"
                              + write_late % (real_wt, real_wt)
                              + "    print(\"mv: cannot move '%s' to '%s': Invalid cross-device link\""
                                " % (args[-2], args[-1]), file=sys.stderr)\n    sys.exit(1)\n")
                c.cp_recorder()
                result = c.run_gc("--apply")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("\treport\tmerged PR #1, tip == PR head; " + REASON, result.stdout)
                self.assertNotIn("quarantined", result.stdout)
                self.assertEqual((wt / "late.txt").read_text(), "precious\n")
                c.assert_left_in_place(wt, admin, text="late\n")
                self.assertEqual(c.git("rev-parse", "refs/heads/landed"), tip)

    def test_writer_holding_cwd_and_fd_keeps_every_byte_after_move(self):
        c = self.fixture()
        wt, _ = c.worktree()
        # Opening a tracked file for append changes neither content nor mtime, so
        # the worktree is still clean. The proc fixture omits this process: it is
        # the writer the scan missed or that arrived after it.
        writer = subprocess.Popen([sys.executable, "-c", r'''
import os, pathlib, sys, time
root = pathlib.Path(sys.argv[1])
def wait(name):
    deadline = time.monotonic() + 20
    while not (root / name).exists():
        if time.monotonic() > deadline:
            raise SystemExit("writer was not signalled: " + name)
        time.sleep(0.01)
fd = os.open("f.txt", os.O_WRONLY | os.O_APPEND)
(root / "writer-ready").touch()
wait("phase-1")
os.write(fd, b"fd-1\n")
pathlib.Path("late.txt").write_text("cwd-1\n")
(root / "phase-1-done").touch()
wait("phase-2")
os.write(fd, b"fd-2\n")
with open("late.txt", "a") as late:
    late.write("cwd-2\n")
os.mkdir("sub")
pathlib.Path("sub/deep.txt").write_text("cwd-3\n")
os.close(fd)
''', str(c.root)], cwd=wt, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

        def stop_writer():
            if writer.poll() is None:
                writer.kill()
            writer.wait(timeout=5)
            writer.stderr.close()
        self.addCleanup(stop_writer)
        wait_for(c.root / "writer-ready", "writer start")
        # Phase 1 runs right after the rename, while branch-gc still holds the
        # locks; phase 2 after the run has dropped the admin entry and the branch.
        c.mv_stub(f'''
if args[-1].startswith({str(c.trash)!r}):
    import time
    moved = subprocess.run([os.environ["REAL_MV"], *args])
    if moved.returncode == 0:
        (root / "phase-1").touch()
        deadline = time.monotonic() + 10
        while not (root / "phase-1-done").exists():
            if time.monotonic() > deadline:
                sys.exit("writer did not finish phase 1")
            time.sleep(0.01)
    sys.exit(moved.returncode)
''')
        c.cp_recorder()
        result = c.run_gc("--apply")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("\tquarantined\t", result.stdout)
        self.assertFalse(c.has_branch())
        (c.root / "phase-2").touch()
        _, err = writer.communicate(timeout=10)
        self.assertEqual(writer.returncode, 0, err.decode())
        self.assertFalse(wt.exists())
        [entry] = c.entries()
        moved = entry / "worktree"
        self.assertEqual((moved / "f.txt").read_text(), "base\nfd-1\nfd-2\n")
        self.assertEqual((moved / "late.txt").read_text(), "cwd-1\ncwd-2\n")
        self.assertEqual((moved / "sub/deep.txt").read_text(), "cwd-3\n")
        self.assertFalse((c.root / "cp-calls").exists())

    def test_term_while_counting_leaves_a_restorable_entry(self):
        # Second-vendor review 2026-10-15: the PreCompact worker's hard timeout could land
        # between the rename into trash and the manifest, while branch-gc counted
        # a large tree, stranding the checkout with nothing to restore from. The
        # manifest now follows the rename at once and the count comes after.
        import json
        import shutil
        import signal
        c = self.fixture()
        wt, tip = c.worktree()
        c.env["REAL_FIND"] = shutil.which("find")
        c.tool_stub("find", "REAL_FIND",
                    f"if '-printf' in args and any(a.startswith({str(c.trash)!r}) for a in args):\n"
                    "    import signal\n"
                    "    os.killpg(os.getpgid(0), signal.SIGTERM)\n"
                    "    sys.exit(143)\n")
        (c.root / "prs.json").write_text(json.dumps(c.prs))
        result = subprocess.run(["bash", str(HELPERS["SCRIPT"]), "--tsv", "--apply", str(c.repo)],
                                cwd=c.root, env=c.env, text=True, capture_output=True,
                                timeout=30, check=False, start_new_session=True)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(wt.exists(), "the rename into trash should have happened before the count")
        [entry] = c.entries()
        self.assertTrue((entry / "worktree").is_dir())
        manifest = json.loads((entry / "manifest.json").read_text())
        self.assertIsNone(manifest["entries"])
        self.assertEqual(manifest["tip"], tip)
        restored = c.restore(entry)
        self.assertEqual(restored.returncode, 0, restored.stdout + restored.stderr)
        self.assertTrue((wt / "f.txt").exists())
        self.assertEqual(c.git("rev-parse", "refs/heads/landed"), tip)


if __name__ == "__main__":
    unittest.main()
