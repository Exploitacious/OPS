"""Remote deadline regressions, with GitHub and every remote git call stubbed."""
import os, runpy; runpy.run_path(os.path.join(os.path.dirname(os.path.realpath(__file__)), "..", "sandbox_guard.py"))["require"]()
import json
import os
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "branch-gc"


class RemoteDeadlineTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.repo = self.root / "repo"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        # T3CODE_HOME too: a T3 session exports it, and no case may read the live T3 home.
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(("BRANCH_GC_", "GIT_")) and key != "T3CODE_HOME"}
        self.env.update(HOME=str(self.root), GIT_CONFIG_GLOBAL="/dev/null",
                        GIT_CONFIG_NOSYSTEM="1", GIT_AUTHOR_NAME="Test",
                        GIT_COMMITTER_NAME="Test", GIT_AUTHOR_EMAIL="test@example.invalid",
                        GIT_COMMITTER_EMAIL="test@example.invalid", FIXTURE=str(self.root),
                        REAL_GIT=shutil.which("git"), REAL_DATE=shutil.which("date"),
                        BRANCH_GC_LOG=str(self.root / "state/gc.log"),
                        BRANCH_GC_T3_DB=str(self.root / "missing.sqlite"),
                        BRANCH_GC_TRASH_DAYS="0", BRANCH_GC_SKIP_SECONDS="0",
                        BRANCH_GC_DEADLINE=str(int(time.time()) + 60))
        subprocess.run([self.env["REAL_GIT"], "init", "-q", "-b", "main", str(self.repo)],
                       env=self.env, check=True)
        subprocess.run([self.env["REAL_GIT"], "-C", str(self.repo), "commit", "-q",
                        "--allow-empty", "-m", "base"], env=self.env, check=True)
        oid = subprocess.check_output([self.env["REAL_GIT"], "-C", str(self.repo),
                                       "rev-parse", "HEAD"], env=self.env, text=True).strip()
        with (self.repo / ".git/config").open("a") as config:
            config.write('\n[remote "origin"]\n\turl = https://github.com/acme/widget.git\n')
        prs = [{"number": n, "state": "MERGED", "headRefName": f"remote-{n}",
                "headRefOid": oid, "baseRefName": "main", "mergedAt": "2020-01-01T00:00:00Z"}
               for n in (1, 2)]
        (self.root / "prs.json").write_text(json.dumps(prs))
        (self.root / "remote.tsv").write_text("".join(
            f"{oid}\trefs/heads/remote-{n}\n" for n in (1, 2)))
        self.stub("gh", '''#!/bin/sh
case "$1 $2" in
  "repo view") printf '%s\n' '{"nameWithOwner":"acme/widget","defaultBranchRef":{"name":"main"}}' ;;
  "api graphql") printf '2\n' ;;
  "pr list") cat "$FIXTURE/prs.json" ;;
  *) exit 99 ;;
esac
''')
        self.stub("git", '''#!/bin/sh
case " $* " in
  *" ls-remote "*)
    [ "$CROSS_AT" != listing ] || touch "$FIXTURE/expired"
    cat "$FIXTURE/remote.tsv"; exit 0 ;;
  *" push "*)
    printf '%s\n' "$*" >> "$FIXTURE/pushes"
    [ "$CROSS_AT" != push ] || touch "$FIXTURE/expired"
    exit 0 ;;
esac
exec "$REAL_GIT" "$@"
''')
        self.stub("date", '''#!/bin/sh
if [ "$1" = +%s ] && [ -e "$FIXTURE/expired" ]; then
  printf '%s\n' "$((BRANCH_GC_DEADLINE + 1))"
else
  exec "$REAL_DATE" "$@"
fi
''')
        self.env["PATH"] = str(self.bin) + os.pathsep + os.environ["PATH"]

    def stub(self, name, source):
        path = self.bin / name
        path.write_text(source)
        path.chmod(0o755)

    def run_gc(self, cross_at):
        result = subprocess.run(["bash", str(SCRIPT), "--apply", "--remote", "--tsv",
                                 str(self.repo)], env=dict(self.env, CROSS_AT=cross_at),
                                text=True, capture_output=True, timeout=15, check=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout

    def test_deadline_during_remote_listing_starts_no_remote_branch(self):
        out = self.run_gc("listing")
        self.assertFalse((self.root / "pushes").exists(), out)
        self.assertEqual(out.count("not evaluated: the run's deadline passed"), 2, out)
        self.assertIn("stopped at the deadline: 2 branch(es) not evaluated", out)

    def test_deadline_after_one_remote_branch_does_not_start_the_next(self):
        out = self.run_gc("push")
        self.assertEqual(len((self.root / "pushes").read_text().splitlines()), 1, out)
        self.assertIn("not evaluated: the run's deadline passed", out)
        self.assertIn("stopped at the deadline: 1 branch(es) not evaluated", out)

    def test_deadline_not_reached_processes_all_remote_branches(self):
        out = self.run_gc("none")
        self.assertEqual(len((self.root / "pushes").read_text().splitlines()), 2, out)
        self.assertNotIn("not evaluated", out)


if __name__ == "__main__":
    unittest.main()
