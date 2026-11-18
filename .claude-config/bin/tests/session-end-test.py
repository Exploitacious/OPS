#!/usr/bin/env python3
"""session-end safety and contract tests. Every repo, stamp, pool and tool is a fixture.

Oracle: the OPS files the command must agree with, not its code:
hooks/pre-compact.sh ("Branch and worktree GC": the managed set, github.com
origin, 900 s, two-thirds deadline, 30 s kill, BRANCH_GC_TRASH_DAYS=0),
hooks/session-work-init.sh and hooks/hooklib.sh (the stamp names, the key and
ops_backend), hooks/handoff-check.sh (the baton directory),
hooks/memory-digest.sh (the --ops checkout), verify-ops.sh (its summary line
and --quiet) and .claude-config/bin/README.md, session-end (the stamps a close owns).

Every tool session-end calls (branch-gc, memory-index, verify-ops.sh, asks,
active-minutes, lane-class, compact-cycle.sh, t3-api.sh, docker, the timeout
program) is a recording stub beside a COPY of the script in a fixture tree; git
runs through a recording wrapper that fails the case on any writing subcommand.
The real hooklib.sh and key.sh are copied in, so the stamp key and the baton key
come from the real helpers. The guard below refuses to run outside sandbox-run,
and a sentinel tree in the sandbox home must be byte-identical after every case,
so the suite's safety does not rest on the command under test.
"""
import os, runpy; runpy.run_path(os.path.join(os.path.dirname(os.path.realpath(__file__)), "..", "sandbox_guard.py"))["require"]()
import fcntl
import hashlib
import json
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

BIN = Path(__file__).resolve().parents[1]
CHECKOUT = BIN.parents[1]
SRC = BIN / "session-end"
REAL_GIT = shutil.which("git")
SID = "1f0e2d3c-4b5a-6978-8a9b-0c1d2e3f4a5b"
TID = "6a7b8c9d-0e1f-4a2b-8c3d-4e5f6a7b8c9d"
GIT_ENV = {"GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
           "GIT_AUTHOR_NAME": "T", "GIT_AUTHOR_EMAIL": "t@example.invalid",
           "GIT_COMMITTER_NAME": "T", "GIT_COMMITTER_EMAIL": "t@example.invalid"}

STUB = r'''#!/usr/bin/env python3
import json, os, sys, time
name = os.path.basename(sys.argv[0])
rec = os.environ["SE_REC"]
try:
    beh = json.load(open(os.path.join(rec, "behavior.json"))).get(name, {})
except FileNotFoundError:
    beh = {}
def log(event, **kw):
    with open(os.path.join(rec, "calls.jsonl"), "a") as f:
        f.write(json.dumps(dict(tool=name, event=event, argv=sys.argv[1:], cwd=os.getcwd(), t=time.time(),
            env={k: os.environ.get(k) for k in ("BRANCH_GC_TRASH_DAYS", "BRANCH_GC_DEADLINE", "BRANCH_GC_LOG", "OPS_DIR")}, **kw)) + "\n")
log("start")
args = sys.argv[1:]
if name == "branch-gc":
    repo = args[-1]
    if "raw" in beh:
        print(beh["raw"]); log("end"); sys.exit(0)
    rel = beh.get("block_until")
    if rel and "--apply" in args:
        end = time.time() + 60
        while not os.path.exists(rel):
            if time.time() > end:
                print("stub: never released"); sys.exit(70)
            time.sleep(0.02)
    if "--dry-run" in args:
        bl = os.environ.get("BRANCH_GC_LOG")
        open(bl, "a").write("dry run log line\n")
    print("branch-gc %s 2026-11-17 10:00:00 UTC  T3=ok" % ("apply" if "--apply" in args else "dry-run"))
    print("REPO\tBRANCH\tWORKTREE\tPR\tACTION\tREASON")
    for row in beh.get("rows", []):
        if row[0] == repo:
            print("\t".join(row))
    print("")
    print("Summary (remove / report / quarantine / failed):")
    print("  %s 0 0 0 0" % repo)
    if beh.get("out"):
        print(beh["out"])
    log("end")
    sys.exit(beh.get("rc_by_repo", {}).get(repo, beh.get("rc", 0)))
if name == "memory-index":
    if args[:1] == ["--pool-for"]:
        if beh.get("pool"):
            print(beh["pool"]); sys.exit(0)
        print("memory-index: no memory pool", file=sys.stderr); sys.exit(4)
    print(beh.get("out", "[memory-index] wrote 1 line(s)")); sys.exit(beh.get("rebuild_rc", 0))
if name == "lane-class":
    print(beh.get("word", "foreman")); sys.exit(0)
if name == "active-minutes":
    print(beh.get("out", "events            : 9\nACTIVE (bill this): 42.0 min = 0.7000 h -> 0.70 h\nexcluded gaps     : 1, total 50.0 min"))
    sys.exit(beh.get("rc", 0))
if name == "docker":
    if args[:1] == ["inspect"]:
        if args[-1] in beh.get("present", []):
            print("[{}]"); sys.exit(0)
        print("Error: No such object: %s" % args[-1]); sys.exit(1)
    sys.exit(64)
print(beh.get("out", "%s ok" % name))
sys.exit(beh.get("rc", 0))
'''

TIMEOUT_STUB = r'''#!/usr/bin/env python3
import json, os, sys, time
with open(os.path.join(os.environ["SE_REC"], "calls.jsonl"), "a") as f:
    f.write(json.dumps(dict(tool="gnutimeout", event="start", argv=sys.argv[1:], t=time.time())) + "\n")
a = sys.argv[1:]
assert a[0] == "-k", a
os.execv(a[3], a[3:])
'''

GIT_WRAPPER = r'''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
i = 0
while i < len(args) and args[i] in ("-C", "-c"):
    i += 2
sub = args[i] if i < len(args) else ""
rest = args[i + 1:]
WRITE = {"commit", "push", "checkout", "switch", "stash", "reset", "merge", "rebase", "pull", "fetch",
         "tag", "cherry-pick", "revert", "rm", "mv", "add", "clean", "gc", "prune", "update-ref",
         "restore", "am", "apply", "init", "clone", "remote", "notes", "replace", "reflog"}
bad = sub in WRITE
if sub == "branch":
    bad = True
if sub == "worktree" and rest[:1] != ["list"]:
    bad = True
if sub == "config" and not any(a.startswith("--get") or a in ("--list", "-l") for a in rest):
    bad = True
if sub == "symbolic-ref" and len([a for a in rest if not a.startswith("-")]) >= 2:
    bad = True
rec = os.environ["SE_REC"]
with open(os.path.join(rec, "git.jsonl"), "a") as f:
    f.write(json.dumps(args) + "\n")
if bad:
    with open(os.path.join(rec, "git-violations"), "a") as f:
        f.write(json.dumps(args) + "\n")
    sys.exit(99)
os.execv(os.environ["REAL_GIT"], [os.environ["REAL_GIT"]] + args)
'''

SIBLING_STUBS = ("branch-gc", "memory-index", "verify-ops.sh", "asks", "active-minutes",
                 "lane-class", "compact-cycle.sh", "t3-api.sh")
# The tools a run may start without writing anything: the read-only steps.
READ_ONLY_TOOLS = {"branch-gc", "gnutimeout", "memory-index", "asks", "active-minutes", "lane-class"}


def tree_state(root, with_mtime=True):
    """Every path under root: type, bytes digest or link target, mode and mtime."""
    out = {}
    root = str(root)
    for d, dirs, files in os.walk(root):
        for n in dirs + files:
            p = os.path.join(d, n)
            st = os.lstat(p)
            rel = os.path.relpath(p, root)
            if stat.S_ISLNK(st.st_mode):
                out[rel] = ("link", os.readlink(p))
            elif stat.S_ISDIR(st.st_mode):
                out[rel] = ("dir", stat.S_IMODE(st.st_mode))
            else:
                with open(p, "rb") as f:
                    h = hashlib.sha256(f.read()).hexdigest()
                out[rel] = ("file", h, stat.S_IMODE(st.st_mode), st.st_mtime_ns if with_mtime else 0)
    return out


def g(cwd, *args):
    return subprocess.run([REAL_GIT, "-C", str(cwd)] + list(args), env=dict(os.environ, **GIT_ENV),
                          check=True, capture_output=True, text=True).stdout.strip()


def make_repo(path, origin=None, extra_origin=None):
    path.mkdir(parents=True, exist_ok=True)
    g(path, "init", "-q", "-b", "main")
    (path / "README.md").write_text("fixture\n")
    g(path, "add", "README.md")
    g(path, "commit", "-q", "-m", "base")
    if origin:
        g(path, "config", "remote.origin.url", origin)
        if extra_origin:
            g(path, "config", "--add", "remote.origin.url", extra_origin)
        g(path, "update-ref", "refs/remotes/origin/main", "HEAD")
        g(path, "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main")
    return path


SENTINEL = {}


def setUpModule():
    home = Path(os.environ["HOME"])
    s = home / "session-end-sentinel"
    s.mkdir()
    (s / "notes.txt").write_text("must survive every case\n")
    repo = make_repo(s / "repo", origin="https://github.com/acme/sentinel.git")
    g(repo, "branch", "feature")
    g(repo, "worktree", "add", "-q", str(s / "repo-wt"), "feature")
    SENTINEL["root"] = s
    SENTINEL["state"] = tree_state(s)


class SessionEnd(unittest.TestCase):
    maxDiff = None

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="se-test-")).resolve()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.home = self.tmp / "home"
        self.rec = self.tmp / "rec"
        self.scratch = self.tmp / "scratch"
        self.stubbin = self.tmp / "stubbin"
        for d in (self.home, self.rec, self.scratch, self.stubbin):
            d.mkdir()
        self.cw = self.home / "OPS"
        make_repo(self.cw, origin="git@github.com:acme/harness.git")
        bin_ = self.cw / ".claude-config" / "bin"
        bin_.mkdir(parents=True)
        (self.cw / ".claude-config" / "hooks").mkdir()
        (self.cw / ".claude-handoffs" / "pending").mkdir(parents=True)
        shutil.copy2(SRC, bin_ / "session-end")
        shutil.copy2(CHECKOUT / ".claude-config" / "hooks" / "hooklib.sh", self.cw / ".claude-config" / "hooks" / "hooklib.sh")
        shutil.copy2(CHECKOUT / ".claude-handoffs" / "key.sh", self.cw / ".claude-handoffs" / "key.sh")
        for n in SIBLING_STUBS:
            self.write_exec(bin_ / n, STUB)
        (self.cw / ".gitignore").write_text("PROJECTS/\n.claude-memory/\n")
        g(self.cw, "add", "-A")
        g(self.cw, "commit", "-q", "-m", "fixture harness")
        self.script = bin_ / "session-end"
        self.bin = bin_
        self.write_exec(self.stubbin / "git", GIT_WRAPPER)
        self.write_exec(self.stubbin / "gnutimeout", TIMEOUT_STUB)
        self.write_exec(self.stubbin / "docker", STUB)
        self.proj = make_repo(self.cw / "PROJECTS" / "acme" / "widget", origin="https://github.com/acme/widget.git")
        self.other = make_repo(self.cw / "PROJECTS" / "acme" / "other", origin="ssh://git@github.com/acme/other.git")
        self.pool = self.cw / ".claude-memory" / "fixture-pool"
        self.pool.mkdir(parents=True)
        self.state = self.home / ".local" / "state" / "ops"
        self.state.mkdir(parents=True)
        self.closeout = self.state / "last-closeout"
        self.closeout.write_text("2026-11-01T09:00:00-04:00\n")
        self.run_dir = self.home / ".claude-compact-cycle"
        self.run_dir.mkdir()
        self.key = "t3-" + SID
        self.stamps = {"session-start-" + self.key: b"t0=2026-11-17T10:00:00-05:00\nrepos=OPS\n",
                       "work-log-" + self.key: b"## segment\nelapsed=1h\n",
                       "session-start-t3-sibling": b"t0=2026-11-16T08:00:00-05:00\n",
                       "work-log-t3-sibling": b"sibling log\n"}
        for n, b in self.stamps.items():
            (self.run_dir / n).write_bytes(b)
        self.behavior = {"memory-index": {"pool": str(self.pool)}}
        self.save_behavior()
        self.tx_dir = self.home / ".claude" / "projects" / "-fixture"
        self.tx_dir.mkdir(parents=True)
        self.addCleanup(self.drain_workers)

    def tearDown(self):
        self.assertFalse((self.rec / "git-violations").exists(),
                         "a writing git subcommand ran: %s" % self.read_text(self.rec / "git-violations"))
        self.assertEqual(SENTINEL["state"], tree_state(SENTINEL["root"]), "the sentinel outside the fixture changed")

    # --- helpers --------------------------------------------------------------

    @staticmethod
    def read_text(p):
        return p.read_text() if p.exists() else ""

    @staticmethod
    def write_exec(path, body):
        path.write_text(body)
        path.chmod(0o755)

    def save_behavior(self):
        (self.rec / "behavior.json").write_text(json.dumps(self.behavior))

    def drain_workers(self):
        """Release every blocked stub and wait until each GC worker has written its result."""
        rel = self.behavior.get("branch-gc", {}).get("block_until")
        if rel:
            Path(rel).touch()
        gcroot = self.state / "session-end" / "gc"
        if not gcroot.is_dir():
            return
        for rd in gcroot.iterdir():
            if rd.is_dir():
                self.wait_for(lambda rd=rd: (rd / "result.json").exists() or not self.locked(rd / "worker.lock"))

    @staticmethod
    def locked(path):
        try:
            fd = os.open(str(path), os.O_RDONLY)
        except FileNotFoundError:
            return False
        try:
            fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
            return False
        except BlockingIOError:
            return True
        finally:
            os.close(fd)

    def wait_for(self, pred, timeout=30):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if pred():
                return
            time.sleep(0.02)
        self.fail("condition not met within %ss" % timeout)

    def env(self, **over):
        path = ":".join(p for p in os.environ.get("PATH", "/usr/bin:/bin").split(":") if ".claude-config" not in p)
        e = {"PATH": "%s:%s" % (self.stubbin, path), "HOME": str(self.home), "LANG": "C.UTF-8",
             "TMPDIR": str(self.scratch), "SE_REC": str(self.rec), "REAL_GIT": REAL_GIT,
             "CLAUDE_CODE_SESSION_ID": SID, "T3CODE_THREAD_ID": TID}
        e.update(GIT_ENV)
        for k, v in over.items():
            if v is None:
                e.pop(k, None)
            else:
                e[k] = v
        return e

    def se(self, *args, cwd=None, env=None, timeout=90, script=None):
        return subprocess.run([sys.executable, str(script or self.script)] + list(args), cwd=str(cwd or self.cw),
                              env=env or self.env(), capture_output=True, text=True, timeout=timeout)

    def sej(self, *args, **kw):
        p = self.se(*args, "--json", **kw)
        try:
            obj = json.loads(p.stdout)
        except ValueError:
            self.fail("stdout is not one JSON object (exit %s):\n%s\nstderr:\n%s" % (p.returncode, p.stdout, p.stderr))
        self.assertEqual(obj["exit"], p.returncode)
        return p, obj

    @staticmethod
    def step(obj, name):
        hits = [s for s in obj["steps"] if s["step"] == name]
        return hits[-1] if hits else None

    def calls(self, tool=None, event="start"):
        p = self.rec / "calls.jsonl"
        rows = [json.loads(l) for l in p.read_text().splitlines()] if p.exists() else []
        return [r for r in rows if (tool is None or r["tool"] == tool) and (event is None or r["event"] == event)]

    def gc_applies(self):
        rows = [c for c in self.calls("branch-gc") if "--apply" in c["argv"]]
        for c in self.calls("branch-gc"):
            for bad in ("--force", "-f", "--remote", "-D"):
                self.assertNotIn(bad, c["argv"], "branch-gc got %s" % bad)
        return rows

    def transcript(self, uses=(), sid=SID, lines_extra=(), first_offset=3600):
        """A Claude transcript for sid: uses are (tool, input, result text, is_error)."""
        t0 = time.time() - first_offset
        iso = lambda t: time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(t))
        lines = [{"type": "user", "sessionId": sid, "timestamp": iso(t0), "message": {"role": "user", "content": "go"}}]
        for i, (name, inp, res, err) in enumerate(uses):
            uid = "toolu_%02d" % i
            lines.append({"type": "assistant", "sessionId": sid, "timestamp": iso(t0 + i + 1),
                          "message": {"role": "assistant", "content": [{"type": "tool_use", "id": uid, "name": name, "input": inp}]}})
            r = {"type": "tool_result", "tool_use_id": uid, "content": res}
            if err:
                r["is_error"] = True
            lines.append({"type": "user", "sessionId": sid, "timestamp": iso(t0 + i + 1.5),
                          "message": {"role": "user", "content": [r]}})
        lines.extend(lines_extra)
        p = self.tx_dir / ("%s.jsonl" % sid)
        p.write_text("".join(json.dumps(l) + "\n" for l in lines))
        return p

    def stamps_now(self):
        return {n: (self.run_dir / n).read_bytes() for n in self.stamps if (self.run_dir / n).exists()}

    # --- step 2 and 4: which repos reach branch-gc ------------------------------

    def test_gc_gets_current_plus_explicit_never_a_transcript_only_candidate(self):
        self.transcript([("Read", {"file_path": str(self.proj / "README.md")}, "fixture", False),
                         ("Bash", {"command": "ls ~/OPS/PROJECTS/acme/widget"}, "README.md", False)])
        p, obj = self.sej("pause", "--repo", str(self.other), "--wait", "30")
        self.assertEqual(p.returncode, 0, p.stdout)
        applied = sorted(c["argv"][-1] for c in self.gc_applies())
        self.assertEqual(applied, sorted([str(self.cw), str(self.other)]))
        self.assertNotIn(str(self.proj), applied, "a transcript-only candidate reached --apply")
        repos = self.step(obj, "repos")
        self.assertIn("pass --repo for any of these you changed", repos["output"])
        self.assertIn(str(self.proj), repos["output"])

    def test_gc_without_a_verified_transcript_gets_only_explicit_repos(self):
        p, obj = self.sej("pause", "--repo", str(self.proj), "--wait", "30")
        self.assertEqual(p.returncode, 0, p.stdout)
        self.assertEqual([c["argv"][-1] for c in self.gc_applies()], [str(self.proj)])
        self.assertEqual(self.step(obj, "transcript")["status"], "skipped")

    def test_canonical_duplicates_make_one_invocation_and_keep_the_worktree_snapshot(self):
        sub = self.proj / "src"
        sub.mkdir()
        wt = self.tmp / "widget-lane"
        g(self.proj, "worktree", "add", "-q", "-b", "lane", str(wt))
        (wt / "dirty.txt").write_text("unlanded\n")
        p, obj = self.sej("pause", "--repo", str(self.proj), "--repo", str(sub), "--repo", str(wt), "--wait", "30", cwd=wt)
        self.assertEqual(p.returncode, 0, p.stdout)
        self.assertEqual([c["argv"][-1] for c in self.gc_applies()], [str(self.proj)])
        snap = self.step(obj, "git snapshot")["output"]
        self.assertRegex(snap, r"%s \(linked worktree of %s\): branch lane; .*1 changed or untracked" % (re.escape(str(wt)), re.escape(str(self.proj))))
        self.assertIn("?? dirty.txt", snap)
        self.assertRegex(snap, r"%s: branch main; .*; clean" % re.escape(str(self.proj)))

    def test_unmanaged_and_non_github_or_multiple_origins_never_reach_apply(self):
        unmanaged = make_repo(self.home / "elsewhere" / "tool", origin="https://github.com/acme/tool.git")
        gitlab = make_repo(self.cw / "PROJECTS" / "acme" / "gitlab", origin="https://gitlab.com/acme/gitlab.git")
        multi = make_repo(self.cw / "PROJECTS" / "acme" / "multi", origin="https://github.com/acme/multi.git",
                          extra_origin="https://github.com/acme/fork.git")
        deep = make_repo(self.cw / "PROJECTS" / "acme" / "nest" / "deep", origin="https://github.com/acme/deep.git")
        p, obj = self.sej("pause", "--repo", str(unmanaged), "--repo", str(gitlab), "--repo", str(multi),
                          "--repo", str(deep), "--wait", "30")
        self.assertEqual(p.returncode, 0, p.stdout)
        self.assertEqual(self.calls("branch-gc"), [])
        out = self.step(obj, "branch-gc")["output"]
        self.assertIn("not run: %s is not a repo branch-gc manages" % unmanaged, out)
        self.assertIn("not run: %s is not a repo branch-gc manages" % deep, out)
        self.assertIn("not run: %s has no github.com origin (or multiple origins)" % gitlab, out)
        self.assertIn("not run: %s has no github.com origin (or multiple origins)" % multi, out)

    def test_gc_runs_under_the_hook_timeout_numbers_and_prints_recovery(self):
        tip = g(self.proj, "rev-parse", "HEAD")
        g(self.proj, "update-ref", "refs/heads/feat", tip)
        entry = "~/.local/state/ops/branch-gc-trash/20261117T100000Z__widget__lane"
        self.behavior["branch-gc"] = {"rows": [
            [str(self.proj), "feat", "-", "#7 MERGED", "removed", "tip == merged PR #7 head"],
            [str(self.proj), "lane", str(self.tmp / "gone"), "#8 MERGED", "quarantined", "merged; worktree moved to " + entry]]}
        self.save_behavior()
        t0 = time.time()
        p, obj = self.sej("pause", "--repo", str(self.proj), "--wait", "30")
        self.assertEqual(p.returncode, 0, p.stdout)
        to = self.calls("gnutimeout")
        self.assertEqual(len(to), 1)
        self.assertEqual(to[0]["argv"], ["-k", "30", "900", str(self.bin / "branch-gc"), "--apply", "--tsv", str(self.proj)])
        call = self.gc_applies()[0]
        self.assertEqual(call["env"]["BRANCH_GC_TRASH_DAYS"], "0")
        self.assertLessEqual(abs(int(call["env"]["BRANCH_GC_DEADLINE"]) - (t0 + 600)), 30)
        out = self.step(obj, "branch-gc")["output"]
        self.assertIn("branch-gc --restore %s" % (str(self.home) + entry[1:]), out)
        self.assertIn("git -C %s branch feat %s" % (self.proj, tip), out)
        self.assertIn("including other threads' eligible idle work", out)

    def test_a_failing_branch_gc_exits_1_with_its_output_and_later_steps_run(self):
        self.behavior["branch-gc"] = {"rc": 1, "out": "branch-gc: gh said HTTP 401"}
        self.save_behavior()
        p, obj = self.sej("close", "--repo", str(self.proj), "--wait", "30")
        self.assertEqual(p.returncode, 1)
        gc = self.step(obj, "branch-gc")
        self.assertEqual(gc["status"], "failed")
        self.assertIn("HTTP 401", gc["output"])
        for later in ("memory index", "disk", "vault view", "open asks"):
            self.assertIsNotNone(self.step(obj, later), later)
        self.assertEqual(len(self.calls("asks")), 1, "a later step's tool did not run")

    # --- step 4: the worker, the wait budget, pending -------------------------

    def block_gc(self):
        rel = self.tmp / "release"
        self.behavior["branch-gc"] = dict(self.behavior.get("branch-gc", {}), block_until=str(rel))
        self.save_behavior()
        return rel

    def result_of(self, obj):
        return Path(self.step(obj, "branch-gc")["result"])

    def test_two_repos_one_serial_worker_pending_survives_and_is_reused(self):
        rel = self.block_gc()
        p, obj = self.sej("pause", "--repo", str(self.proj), "--repo", str(self.other), "--wait", "0")
        self.assertEqual(p.returncode, 3, p.stdout)
        gc = self.step(obj, "branch-gc")
        self.assertEqual(gc["status"], "pending")
        result = self.result_of(obj)
        self.assertFalse(result.exists())
        p2, obj2 = self.sej("pause", "--repo", str(self.other), "--repo", str(self.proj), "--wait", "0")
        self.assertEqual(p2.returncode, 3)
        self.assertIn("reusing the pending worker", self.step(obj2, "branch-gc")["summary"])
        self.assertEqual(len(list((self.state / "session-end" / "gc").glob("*/plan.json"))), 1)
        rel.touch()
        self.wait_for(result.exists)
        starts = [(c["argv"][-1], c["t"]) for c in self.calls("branch-gc") if "--apply" in c["argv"]]
        ends = [(c["argv"][-1], c["t"]) for c in self.calls("branch-gc", event="end")]
        self.assertEqual([s[0] for s in starts], sorted([str(self.proj), str(self.other)]))
        self.assertLessEqual(ends[0][1], starts[1][1], "the second repo started before the first finished")
        self.assertEqual(json.loads(result.read_text())["status"], "completed")
        before = self.closeout.read_text()
        f = self.se("finish")
        self.assertEqual(f.returncode, 0, f.stdout + f.stderr)
        self.assertNotEqual(self.closeout.read_text(), before)

    def test_a_pending_run_for_another_selection_is_not_started_twice(self):
        self.block_gc()
        p, _ = self.sej("pause", "--repo", str(self.proj), "--wait", "0")
        self.assertEqual(p.returncode, 3)
        p2, obj2 = self.sej("pause", "--repo", str(self.other), "--wait", "0")
        self.assertEqual(p2.returncode, 1)
        self.assertIn("not starting a conflicting copy", self.step(obj2, "branch-gc")["summary"])
        self.assertEqual(len(list((self.state / "session-end" / "gc").glob("*/plan.json"))), 1)

    def test_finish_refuses_while_gc_runs_and_after_a_later_failure(self):
        rel = self.block_gc()
        self.behavior["branch-gc"]["rc"] = 1
        self.save_behavior()
        p, obj = self.sej("pause", "--repo", str(self.proj), "--wait", "0")
        self.assertEqual(p.returncode, 3)
        before = self.closeout.read_bytes()
        f = self.se("finish")
        self.assertEqual(f.returncode, 1)
        self.assertIn("GC is still running", f.stdout)
        rel.touch()
        self.wait_for(self.result_of(obj).exists)
        self.assertEqual(json.loads(self.result_of(obj).read_text())["status"], "failed")
        f = self.se("finish")
        self.assertEqual(f.returncode, 1)
        self.assertIn("GC finished with a failure", f.stdout)
        self.assertEqual(self.closeout.read_bytes(), before, "a failed or pending GC advanced last-closeout")

    def test_missing_prerequisites_fail_visibly_without_a_worker(self):
        (self.bin / "branch-gc").unlink()
        p, obj = self.sej("pause", "--repo", str(self.proj), "--wait", "0")
        self.assertEqual(p.returncode, 1)
        self.assertIn("branch-gc not found", self.step(obj, "branch-gc")["summary"])
        self.write_exec(self.bin / "branch-gc", STUB)
        (self.bin / "memory-index").unlink()
        p, obj = self.sej("pause", "--repo", str(self.proj), "--wait", "30")
        self.assertEqual(p.returncode, 1)
        self.assertIn("memory-index not found", self.step(obj, "memory index")["summary"])
        self.assertEqual(self.step(obj, "branch-gc")["status"], "completed")

    def test_no_timeout_program_starts_no_worker(self):
        nobin = self.tmp / "nobin"
        nobin.mkdir()
        for d in os.environ.get("PATH", "").split(":"):
            if not d or ".claude-config" in d or not os.path.isdir(d):
                continue
            for n in os.listdir(d):
                if n in ("timeout", "gnutimeout", "git") or os.path.lexists(nobin / n):
                    continue
                os.symlink(os.path.join(d, n), nobin / n)
        os.symlink(self.stubbin / "git", nobin / "git")
        p, obj = self.sej("pause", "--repo", str(self.proj), "--wait", "0", env=self.env(PATH=str(nobin)))
        self.assertEqual(p.returncode, 1, p.stdout)
        self.assertIn("no timeout program", self.step(obj, "branch-gc")["summary"])
        self.assertFalse((self.state / "session-end" / "gc").exists())
        self.assertEqual(self.calls("branch-gc"), [])

    def test_worker_launch_failure_is_a_failure(self):
        (self.state / "session-end").mkdir()
        (self.state / "session-end" / "gc").write_text("not a directory\n")
        p, obj = self.sej("pause", "--repo", str(self.proj), "--wait", "0")
        self.assertEqual(p.returncode, 1)
        self.assertIn("could not start the GC worker", self.step(obj, "branch-gc")["summary"])
        self.assertEqual(self.calls("branch-gc"), [])

    # --- dry run ----------------------------------------------------------------

    def test_dry_run_passes_no_apply_detaches_nothing_and_writes_nothing(self):
        self.transcript([("Edit", {"file_path": str(self.cw / ".claude-config" / "bin" / "x")}, "ok", False)])
        (self.pool / "entry.md").write_text("---\nname: entry\nmetadata:\n  modified: 2020-01-01\n---\nbody\n")
        (self.state / "branch-gc.log").write_text("older run\n")
        (self.state / "session-end").mkdir()
        (self.state / "session-end" / ("%s.json" % self.key)).write_text('{"old": true}\n')
        before_home, before_scratch = tree_state(self.home), tree_state(self.scratch)
        p, obj = self.sej("close", "--dry-run", "--repo", str(self.proj), "--wait", "30")
        self.assertEqual(p.returncode, 0, p.stdout)
        self.assertEqual(tree_state(self.home), before_home, "a dry run changed the fixture home")
        self.assertEqual(tree_state(self.scratch), before_scratch, "a dry run left files in TMPDIR")
        gcs = self.calls("branch-gc")
        self.assertTrue(gcs)
        for c in gcs:
            self.assertNotIn("--apply", c["argv"])
            self.assertIn("--dry-run", c["argv"])
            self.assertTrue(c["env"]["BRANCH_GC_LOG"].startswith(str(self.scratch) + "/"))
        self.assertEqual([c["argv"][0] for c in self.calls("memory-index")], ["--pool-for"])
        self.assertEqual(self.calls("verify-ops.sh"), [])
        # Only read-only helpers ran: no gate, no writer, no T3 tool.
        self.assertLessEqual({c["tool"] for c in self.calls()}, READ_ONLY_TOOLS)
        self.assertIsNone(obj["receipt"])

    # --- close: what the thread made --------------------------------------------

    def test_close_lists_only_this_threads_creations_and_removes_nothing(self):
        s = self.scratch
        other = s / "other-thread"
        other.mkdir()
        (other / "work.txt").write_text("theirs\n")
        (s / "mine").mkdir()
        (s / "mine" / "a.txt").write_text("mine\n")
        (s / "mydir").mkdir()
        (s / "maybe").mkdir()
        (s / "edited.txt").write_text("existed before\n")
        wt = s / "wt-new"
        g(self.proj, "worktree", "add", "-q", "-b", "x", str(wt))
        self.behavior["docker"] = {"present": ["mybox", "shared"]}
        self.behavior["branch-gc"] = {"rows": [[str(self.proj), "x", str(wt), "-", "kept", "dirty: untracked files"]]}
        self.save_behavior()
        self.transcript([
            ("Write", {"file_path": str(s / "mine" / "a.txt")}, "File created successfully at: %s" % (s / "mine" / "a.txt"), False),
            ("Write", {"file_path": str(s / "edited.txt")}, "The file %s has been updated successfully." % (s / "edited.txt"), False),
            ("Bash", {"command": "mkdir %s && mkdir -p %s" % (s / "mydir", s / "maybe")}, "", False),
            ("Bash", {"command": "mkdir %s" % s}, "", False),
            ("Bash", {"command": "mkdir %s" % (s / "failed")}, "mkdir: cannot create", True),
            ("Bash", {"command": "ls %s; cat %s/work.txt" % (other, other)}, "work.txt", False),
            ("Bash", {"command": "git -C %s worktree add %s -b x" % (self.proj, wt)}, "Preparing worktree", False),
            ("Bash", {"command": "docker run --rm alpine:3 true; docker run -d --name mybox img; docker run --name gone img"}, "", False),
            ("Bash", {"command": "docker volume create shared"}, "shared", False),
        ])
        before_other = tree_state(other)
        p, obj = self.sej("close", "--repo", str(self.proj), "--wait", "30")
        lst = self.step(obj, "cleanup list")["output"]
        owned, _, unknown = lst.partition("ownership unknown")
        for want in (str(s / "mine" / "a.txt"), str(s / "mydir"), str(wt)):
            self.assertIn(want, owned)
        self.assertIn("GC: kept: dirty: untracked files", owned)
        for want in (str(s / "maybe"), str(s / "edited.txt"), "volume shared", "container mybox"):
            self.assertIn(want, unknown)
            self.assertNotIn(want, owned)
        for never in (str(other), "alpine", "gone", "dir %s (" % s, str(s / "failed")):
            self.assertNotIn(never, lst)
        self.assertIn("check for anything else you created, by exact path or id", lst)
        for path in (s / "mine" / "a.txt", s / "mydir", s / "maybe", wt, s / "edited.txt"):
            self.assertTrue(path.exists(), path)
        self.assertEqual(tree_state(other), before_other)

    def test_a_compound_shell_success_does_not_prove_each_object_was_created(self):
        shared = self.scratch / "another-threads-dir"
        shared.mkdir()
        self.behavior["docker"] = {"present": ["shared-box", "shared-image", "shared-net", "shared-cached"]}
        self.save_behavior()
        self.transcript([
            ("Bash", {"command": "mkdir %s; true" % shared}, "mkdir: File exists", False),
            ("Bash", {"command": "docker create --name shared-box img || true"}, "name already in use", False),
            ("Bash", {"command": "docker build -t shared-image .; true"}, "build failed", False),
            ("Bash", {"command": "docker network create shared-net | cat"}, "network already exists", False),
            ("Bash", {"command": "docker build -t shared-cached ."}, "Using cache\nSuccessfully tagged shared-cached", False),
        ])
        p, obj = self.sej("close", "--dry-run", "--wait", "30")
        self.assertEqual(p.returncode, 0, p.stdout)
        owned, _, unknown = self.step(obj, "cleanup list")["output"].partition("ownership unknown")
        for name in (str(shared), "shared-box", "shared-image", "shared-net", "shared-cached"):
            self.assertNotIn(name, owned, "a successful final command proves nothing about an earlier failure")
            self.assertIn(name, unknown)

    # --- finish and the billing stamps ------------------------------------------

    def close_then(self, *finish_args, env=None):
        self.transcript()
        p, _ = self.sej("close", "--wait", "30", env=env)
        self.assertEqual(p.returncode, 0, p.stdout)
        return self.se("finish", *finish_args, env=env)

    def archive_dirs(self):
        reaped = self.run_dir / "reaped"
        return sorted(d for d in reaped.iterdir() if d.is_dir()) if reaped.is_dir() else []

    def test_finish_moves_exact_bytes_of_only_this_threads_stamps_beside_a_meta(self):
        f = self.close_then("--logged", "2")
        self.assertEqual(f.returncode, 0, f.stdout + f.stderr)
        dirs = self.archive_dirs()
        self.assertEqual(len(dirs), 1, dirs)
        adir = dirs[0]
        self.assertRegex(adir.name, r"^%s-\d{8}T\d{6}-[0-9a-f]{8}$" % re.escape(self.key))
        self.assertEqual(stat.S_IMODE(adir.stat().st_mode), 0o700)
        names = ["work-log-" + self.key, "session-start-" + self.key]
        self.assertEqual(sorted(p.name for p in adir.iterdir()), sorted(names + ["reaped.meta"]))
        meta = (adir / "reaped.meta").read_text()
        for want in ("reaped_reason=session-end finish: logged=2 time entries created and read back",
                     "reaped_key=%s" % self.key, "status=complete"):
            self.assertIn(want, meta)
        for live in names:
            b = self.stamps[live]
            self.assertFalse((self.run_dir / live).exists())
            self.assertEqual((adir / live).read_bytes(), b, "the archived stamp must hold exactly the original bytes")
            self.assertIn("file=%s\toriginal=%s\tsize=%d\tsha256=%s" % (live, self.run_dir / live, len(b),
                                                                   hashlib.sha256(b).hexdigest()), meta)
            self.assertIn("mv -n %s %s" % (adir / live, self.run_dir / live), f.stdout)
        for sib in ("session-start-t3-sibling", "work-log-t3-sibling"):
            self.assertEqual((self.run_dir / sib).read_bytes(), self.stamps[sib])
        self.assertRegex(self.closeout.read_text(), r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d[+-]\d\d:\d\d\n$")
        self.assertNotEqual(self.closeout.read_text(), "2026-11-01T09:00:00-04:00\n")
        self.assertFalse((self.state / "session-end" / ("%s.json" % self.key)).exists())
        again = self.close_then("--logged", "0")
        self.assertEqual(again.returncode, 0, again.stdout)
        self.assertIn("nothing archived", again.stdout)
        self.assertEqual(len(self.archive_dirs()), 1, "a no-op finish made an archive directory")

    def test_finish_flags_are_exclusive_required_after_close_and_refused_otherwise(self):
        self.transcript()
        self.assertEqual(self.sej("close", "--wait", "30")[0].returncode, 0)
        for bad in ([], ["--logged", "1", "--declined", "x"], ["--logged", "-1"], ["--logged", "1.5"],
                    ["--logged", "+1"], ["--declined", ""], ["--declined", "   "]):
            r = self.se("finish", *bad)
            self.assertEqual(r.returncode, 2, (bad, r.stdout, r.stderr))
        self.assertEqual(self.stamps_now(), self.stamps)
        self.assertEqual(self.closeout.read_text(), "2026-11-01T09:00:00-04:00\n")
        self.assertEqual(self.sej("pause", "--wait", "30")[0].returncode, 0)
        self.assertEqual(self.se("finish", "--logged", "1").returncode, 2)
        self.assertEqual(self.se("finish", "--declined", "x").returncode, 2)
        r = self.se("finish")
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertEqual(self.stamps_now(), self.stamps, "finish after a pause touched billing stamps")

    def test_lanes_are_refused_every_writing_mode_without_changes(self):
        before = tree_state(self.home)
        for env in (self.env(T3CODE_THREAD_ID="thread:delegated-task:abc"),
                    self.env(T3CODE_THREAD_ID="thread:provider:xyz")):
            for args in (["close", "--repo", str(self.proj)], ["finish", "--declined", "x"]):
                p, obj = self.sej(*args, env=env)
                self.assertEqual(p.returncode, 1, "a delegated lane was not refused (%s): %s" % (env["T3CODE_THREAD_ID"], args))
                self.assertIn("session-end belongs to the main thread", p.stdout)
        self.behavior["lane-class"] = {"word": "t3-lane"}
        self.save_behavior()
        p, _ = self.sej("pause", "--repo", str(self.proj))
        self.assertEqual(p.returncode, 1)
        self.assertIn("lane-class --self: t3-lane", p.stdout)
        self.behavior["lane-class"] = {"word": "weird"}
        self.save_behavior()
        self.assertEqual(self.sej("pause", "--repo", str(self.proj))[0].returncode, 1)
        self.assertEqual(self.calls("branch-gc"), [])
        self.assertEqual(self.calls("memory-index"), [])
        self.assertEqual(tree_state(self.home), before)
        p, _ = self.sej("pause", "--dry-run", env=self.env(T3CODE_THREAD_ID="thread:delegated-task:abc"))
        self.assertEqual(p.returncode, 0, p.stdout)

    def test_cwd_fallback_key_is_refused_and_leaves_stamps(self):
        # ops_backend says t3code only with T3CODE_HOME or T3CODE_THREAD_ID set.
        env = self.env(T3CODE_THREAD_ID=None)
        cwdkey = re.sub(r"[^A-Za-z0-9-]", "", str(self.cw).replace("/", "-"))
        (self.run_dir / ("session-start-" + cwdkey)).write_bytes(b"shared cwd stamp\n")
        (self.run_dir / ("work-log-" + cwdkey)).write_bytes(b"shared cwd log\n")
        f = self.close_then("--logged", "1", env=env)
        self.assertEqual(f.returncode, 1, f.stdout)
        self.assertIn("refusing to archive", f.stdout)
        self.assertEqual((self.run_dir / ("session-start-" + cwdkey)).read_bytes(), b"shared cwd stamp\n")
        self.assertEqual((self.run_dir / ("work-log-" + cwdkey)).read_bytes(), b"shared cwd log\n")
        self.assertFalse((self.run_dir / "reaped").exists())
        self.assertEqual(self.closeout.read_text(), "2026-11-01T09:00:00-04:00\n")

    def test_a_receipt_of_another_thread_is_refused(self):
        self.transcript()
        self.assertEqual(self.sej("close", "--wait", "30")[0].returncode, 0)
        f = self.se("finish", "--logged", "1", env=self.env(T3CODE_THREAD_ID="0d0d0d0d-0000-4000-8000-000000000000"))
        self.assertEqual(f.returncode, 1, "finish acted on another thread's receipt: " + f.stdout)
        self.assertIn("belongs to another thread", f.stdout)
        self.assertEqual(self.stamps_now(), self.stamps)

    def test_codex_only_runs_explicit_repos_and_finish_archives_nothing(self):
        env = self.env(CLAUDE_CODE_SESSION_ID=None, CODEX_THREAD_ID="019a-codex-thread")
        self.transcript()
        p, obj = self.sej("close", "--repo", str(self.proj), "--wait", "30", env=env)
        self.assertEqual(p.returncode, 0, p.stdout)
        self.assertEqual([c["argv"][-1] for c in self.gc_applies()], [str(self.proj)])
        self.assertIn("unsupported provider", self.step(obj, "transcript")["summary"])
        self.assertIn("unsupported provider", self.step(obj, "time")["summary"])
        self.assertEqual(self.calls("active-minutes"), [])
        f = self.se("finish", "--declined", "no ticket work", env=env)
        self.assertEqual(f.returncode, 0, f.stdout)
        self.assertIn("unsupported provider", f.stdout)
        self.assertEqual(self.stamps_now(), self.stamps)
        self.assertFalse((self.run_dir / "reaped").exists())

    def test_archive_failure_keeps_every_original_and_retry_completes(self):
        reaped = self.run_dir / "reaped"
        reaped.mkdir()
        reaped.chmod(0o500)
        self.addCleanup(reaped.chmod, 0o700)
        f = self.close_then("--declined", "personal work")
        self.assertEqual(f.returncode, 1, f.stdout)
        self.assertEqual(self.stamps_now(), self.stamps)
        self.assertEqual(self.closeout.read_text(), "2026-11-01T09:00:00-04:00\n")
        reaped.chmod(0o700)
        f = self.se("finish", "--declined", "personal work")
        self.assertEqual(f.returncode, 0, f.stdout)
        self.assertFalse((self.run_dir / ("session-start-" + self.key)).exists())

    def test_a_symlinked_or_special_source_moves_nothing(self):
        live = self.run_dir / ("session-start-" + self.key)
        wl = self.run_dir / ("work-log-" + self.key)
        live.unlink()
        target = self.tmp / "elsewhere-stamp"
        target.write_bytes(self.stamps[live.name])
        live.symlink_to(target)
        f = self.close_then("--logged", "1")
        self.assertEqual(f.returncode, 1, f.stdout)
        self.assertIn("not a regular file", f.stdout)
        self.assertTrue(live.is_symlink())
        self.assertEqual(target.read_bytes(), self.stamps[live.name])
        self.assertEqual(wl.read_bytes(), self.stamps[wl.name], "a refusal must move nothing, the work-log included")
        self.assertEqual(self.archive_dirs(), [])
        live.unlink()
        live.write_bytes(self.stamps[live.name])
        wl.unlink()
        os.mkfifo(str(wl))
        f = self.se("finish", "--logged", "1")
        self.assertEqual(f.returncode, 1, f.stdout)
        self.assertEqual(live.read_bytes(), self.stamps[live.name])
        self.assertEqual(self.archive_dirs(), [])
        wl.unlink()
        wl.write_bytes(self.stamps[wl.name])
        f = self.se("finish", "--logged", "1")
        self.assertEqual(f.returncode, 0, f.stdout)
        self.assertFalse(live.exists() or wl.exists())
        self.assertEqual(len(self.archive_dirs()), 1)

    def test_a_symlinked_reaped_directory_is_refused(self):
        real = self.tmp / "reaped-target"
        real.mkdir()
        (self.run_dir / "reaped").symlink_to(real)
        f = self.close_then("--logged", "1")
        self.assertEqual(f.returncode, 1)
        self.assertEqual(self.stamps_now(), self.stamps)
        self.assertEqual(list(real.iterdir()), [])

    def test_an_existing_archive_directory_is_never_reused(self):
        hook = self.tmp / "hook"
        self.write_exec(hook, '#!/bin/sh\nif [ "$1" = archive-target ] && [ ! -e "$SE_MARK" ]; then\n'
                              '  mkdir "$2" && printf "earlier archive\\n" > "$2/theirs" && : > "$SE_MARK"\nfi\nexit 0\n')
        f = self.close_then("--logged", "1", env=self.env(SESSION_END_TEST_HOOK=str(hook), SE_MARK=str(self.tmp / "mark")))
        self.assertEqual(f.returncode, 0, f.stdout)
        dirs = self.archive_dirs()
        self.assertEqual(len(dirs), 2, dirs)
        theirs = [d for d in dirs if (d / "theirs").exists()]
        ours = [d for d in dirs if (d / "reaped.meta").exists()]
        self.assertEqual(len(theirs), 1)
        self.assertEqual(sorted(p.name for p in theirs[0].iterdir()), ["theirs"])
        self.assertEqual((theirs[0] / "theirs").read_bytes(), b"earlier archive\n")
        self.assertEqual(len(ours), 1)
        self.assertNotEqual(ours[0], theirs[0])
        self.assertEqual((ours[0] / ("work-log-" + self.key)).read_bytes(), self.stamps["work-log-" + self.key])

    def test_a_writer_holding_the_work_log_open_appends_into_the_archive(self):
        self.transcript()
        self.assertEqual(self.sej("close", "--wait", "30")[0].returncode, 0)
        wl = self.run_dir / ("work-log-" + self.key)
        fd = os.open(str(wl), os.O_WRONLY | os.O_APPEND)
        try:
            f = self.se("finish", "--logged", "1")
            os.write(fd, b"late segment\n")
        finally:
            os.close(fd)
        self.assertEqual(f.returncode, 0, f.stdout)
        self.assertIn("still live: none", f.stdout)
        self.assertFalse(wl.exists())
        archived = self.archive_dirs()[0] / wl.name
        self.assertEqual(archived.read_bytes(), self.stamps[wl.name] + b"late segment\n",
                         "bytes a writer appends through its open descriptor must land in the archive")

    def test_a_session_start_created_by_name_after_the_move_stays_live(self):
        hook = self.tmp / "hook"
        self.write_exec(hook, '#!/bin/sh\ncase "$1:$2" in archived:*session-start-*) printf "t0=fresh window\\n" > "$2" ;; esac\nexit 0\n')
        f = self.close_then("--logged", "1", env=self.env(SESSION_END_TEST_HOOK=str(hook)))
        self.assertEqual(f.returncode, 0, f.stdout)
        live = self.run_dir / ("session-start-" + self.key)
        self.assertEqual(live.read_bytes(), b"t0=fresh window\n", "a new stamp written by name must stay live and untouched")
        self.assertEqual((self.archive_dirs()[0] / live.name).read_bytes(), self.stamps[live.name])

    def test_a_writer_at_the_old_compare_and_unlink_point_loses_no_bytes(self):
        # A review's reproduction appended unbilled bytes between the copy's last
        # compare and the unlink; finish erased them and reported success. The
        # writer here appends by name at both edges of the move.
        hook = self.tmp / "hook"
        self.write_exec(hook, '''#!/usr/bin/env python3
import os, sys
phase, path = sys.argv[1], sys.argv[2]
live = os.path.join(os.environ["SE_RUN"], os.path.basename(path))
if os.path.basename(path).startswith("work-log-") and phase in ("before-move", "archived"):
    chunk = ("unbilled %s\\n" % phase).encode()
    with open(live, "ab") as f:
        f.write(chunk)
    with open(os.environ["SE_WROTE"], "ab") as f:
        f.write(chunk)
''')
        wrote = self.tmp / "wrote"
        f = self.close_then("--logged", "1", env=self.env(SESSION_END_TEST_HOOK=str(hook), SE_RUN=str(self.run_dir),
                                                          SE_WROTE=str(wrote)))
        name = "work-log-" + self.key
        live = self.run_dir / name
        archived = self.archive_dirs()[0] / name
        together = archived.read_bytes() + (live.read_bytes() if live.exists() else b"")
        self.assertEqual(together, self.stamps[name] + wrote.read_bytes(),
                         "every byte the writer wrote must be in the archive or the live file")
        self.assertEqual(live.read_bytes(), b"unbilled archived\n")
        self.assertEqual(f.returncode, 1, "a new segment keeps the window open: " + f.stdout)
        self.assertEqual((self.run_dir / ("session-start-" + self.key)).read_bytes(), self.stamps["session-start-" + self.key])
        self.assertEqual(self.closeout.read_text(), "2026-11-01T09:00:00-04:00\n")

    def test_a_failed_rename_leaves_the_live_stamp_and_exits_1(self):
        hook = self.tmp / "hook"
        self.write_exec(hook, '#!/bin/sh\ncase "$1:$2" in before-move:*work-log-*) chmod 500 "$(dirname "$2")" ;; esac\nexit 0\n')
        self.addCleanup(lambda: [d.chmod(0o700) for d in self.archive_dirs()])
        f = self.close_then("--logged", "1", env=self.env(SESSION_END_TEST_HOOK=str(hook)))
        self.assertEqual(f.returncode, 1, f.stdout)
        self.assertIn("FAILED", f.stdout)
        self.assertEqual(self.stamps_now(), self.stamps)
        self.assertEqual(self.archive_dirs(), [], "an archive directory with nothing moved is removed")
        self.assertEqual(self.closeout.read_text(), "2026-11-01T09:00:00-04:00\n")

    def test_a_post_rename_hash_failure_records_the_move_and_keeps_the_window_live(self):
        # A rename can succeed before hashing fails. The moved file still needs
        # a recovery path, and an unsuccessful finish must retain the billing flag.
        live = self.run_dir / ("session-start-" + self.key)
        live.chmod(0o000)
        try:
            f = self.close_then("--logged", "1")
        finally:
            if live.exists():
                live.chmod(0o600)
            for adir in self.archive_dirs():
                archived = adir / live.name
                if archived.exists():
                    archived.chmod(0o600)
        self.assertEqual(f.returncode, 1, f.stdout)
        self.assertEqual(self.closeout.read_text(), "2026-11-01T09:00:00-04:00\n")
        adir = self.archive_dirs()[0]
        self.assertEqual((adir / live.name).read_bytes(), self.stamps[live.name])
        self.assertIn("restore %s" % live.name, f.stdout)
        meta = (adir / "reaped.meta").read_text()
        self.assertIn("file=%s\t" % live.name, meta)
        self.assertIn("size=unknown\tsha256=unavailable", meta)
        self.assertTrue(live.exists(), "a failed finish cleared the unbilled-window flag")
        self.assertEqual(live.read_bytes(), self.stamps[live.name])

    def test_a_failed_meta_write_keeps_the_window_live_and_reports_the_archive(self):
        hook = self.tmp / "meta-hook"
        self.write_exec(hook, '''#!/usr/bin/env python3
import os, sys
from pathlib import Path
if sys.argv[1] == "archived" and os.path.basename(sys.argv[2]).startswith("session-start-"):
    reaped = Path(os.environ["SE_RUN"]) / "reaped"
    for adir in reaped.iterdir():
        adir.chmod(0o500)
''')
        f = self.close_then("--logged", "1", env=self.env(SESSION_END_TEST_HOOK=str(hook), SE_RUN=str(self.run_dir)))
        for adir in self.archive_dirs():
            adir.chmod(0o700)
        self.assertEqual(f.returncode, 1, f.stdout)
        self.assertEqual(self.closeout.read_text(), "2026-11-01T09:00:00-04:00\n")
        adir = self.archive_dirs()[0]
        self.assertFalse((adir / "reaped.meta").exists())
        self.assertIn(str(adir), f.stdout)
        self.assertNotIn("reaped.meta holds the outcome", f.stdout)
        live = self.run_dir / ("session-start-" + self.key)
        self.assertTrue(live.exists(), "a metadata failure cleared the unbilled-window flag")
        self.assertEqual(live.read_bytes(), self.stamps[live.name])
        retry = self.se("finish", "--logged", "1")
        self.assertEqual(retry.returncode, 0, retry.stdout + retry.stderr)
        self.assertFalse(live.exists())

    def test_a_failed_meta_write_never_replaces_a_newer_live_flag(self):
        hook = self.tmp / "meta-hook"
        self.write_exec(hook, '''#!/usr/bin/env python3
import os, sys
from pathlib import Path
if sys.argv[1] == "archived" and os.path.basename(sys.argv[2]).startswith("session-start-"):
    Path(sys.argv[2]).write_bytes(b"newer unbilled window\\n")
    for adir in (Path(os.environ["SE_RUN"]) / "reaped").iterdir():
        adir.chmod(0o500)
''')
        f = self.close_then("--logged", "1", env=self.env(SESSION_END_TEST_HOOK=str(hook), SE_RUN=str(self.run_dir)))
        for adir in self.archive_dirs():
            adir.chmod(0o700)
        self.assertEqual(f.returncode, 1, f.stdout)
        live = self.run_dir / ("session-start-" + self.key)
        self.assertEqual(live.read_bytes(), b"newer unbilled window\n")
        self.assertEqual((self.archive_dirs()[0] / live.name).read_bytes(), self.stamps[live.name])
        self.assertEqual(self.closeout.read_text(), "2026-11-01T09:00:00-04:00\n")

    def test_a_sync_failure_after_the_start_rename_keeps_recovery_and_window_live(self):
        archive = runpy.run_path(str(self.script))["archive_billing"]
        real_sync = archive.__globals__["fsync_dir"]
        live = self.run_dir / ("session-start-" + self.key)
        injected = False

        def fail_once(path):
            nonlocal injected
            if Path(path) == self.run_dir and not live.exists() and not injected:
                injected = True
                raise OSError("injected sync failure after the flag move")
            real_sync(path)

        with mock.patch.dict(archive.__globals__, {"stamp_dir": lambda: str(self.run_dir),
                                                  "fsync_dir": fail_once, "test_hook": lambda *_: None}):
            ok, lines = archive(self.key, "logged=1")
        self.assertTrue(injected)
        self.assertFalse(ok)
        self.assertEqual(live.read_bytes(), self.stamps[live.name])
        adir = self.archive_dirs()[0]
        self.assertEqual((adir / live.name).read_bytes(), self.stamps[live.name])
        self.assertIn("file=%s\t" % live.name, (adir / "reaped.meta").read_text())
        self.assertIn("restore %s" % live.name, "\n".join(lines))

    def test_a_sync_failure_after_flag_restoration_does_not_record_a_missing_archive(self):
        archive = runpy.run_path(str(self.script))["archive_billing"]
        real_sync = archive.__globals__["fsync_dir"]
        live = self.run_dir / ("session-start-" + self.key)
        work_log = self.run_dir / ("work-log-" + self.key)
        injected = False

        def write_segment(phase, path):
            if phase == "archived" and Path(path) == live:
                work_log.write_bytes(b"new unbilled segment\n")

        def fail_once(path):
            nonlocal injected
            if Path(path) == self.run_dir and live.exists() and work_log.exists() and not injected:
                injected = True
                raise OSError("injected sync failure after the flag was restored")
            real_sync(path)

        with mock.patch.dict(archive.__globals__, {"stamp_dir": lambda: str(self.run_dir),
                                                  "fsync_dir": fail_once, "test_hook": write_segment}):
            ok, lines = archive(self.key, "logged=1")
        self.assertTrue(injected)
        self.assertFalse(ok)
        self.assertEqual(live.read_bytes(), self.stamps[live.name])
        self.assertEqual(work_log.read_bytes(), b"new unbilled segment\n")
        adir = self.archive_dirs()[0]
        self.assertFalse((adir / live.name).exists())
        self.assertNotIn("file=%s\t" % live.name, (adir / "reaped.meta").read_text())
        self.assertNotIn("restore %s," % live.name, "\n".join(lines))

    def test_a_competing_finish_holds_the_lock(self):
        self.transcript()
        self.assertEqual(self.sej("close", "--wait", "30")[0].returncode, 0)
        locks = self.state / "session-end" / "locks"
        locks.mkdir(parents=True, exist_ok=True)
        fd = os.open(str(locks / ("billing-%s.lock" % self.key)), os.O_RDWR | os.O_CREAT, 0o600)
        self.addCleanup(os.close, fd)
        fcntl.flock(fd, fcntl.LOCK_EX)
        f = self.se("finish", "--logged", "1", env=self.env(SESSION_END_LOCK_WAIT="0"))
        self.assertEqual(f.returncode, 1)
        self.assertIn("holds the billing lock", f.stdout)
        self.assertEqual(self.stamps_now(), self.stamps)

    def test_a_running_finish_cannot_retire_a_newer_ending_receipt(self):
        self.transcript()
        self.assertEqual(self.sej("close", "--wait", "30")[0].returncode, 0)
        receipt = self.state / "session-end" / (self.key + ".json")
        original = receipt.read_bytes()
        ready, release = self.tmp / "finish-ready", self.tmp / "finish-release"
        hook = self.tmp / "archive-hook"
        self.write_exec(hook, '''#!/usr/bin/env python3
import os, sys, time
from pathlib import Path
if sys.argv[1] == "archived" and os.path.basename(sys.argv[2]).startswith("work-log-"):
    Path(os.environ["SE_FINISH_READY"]).touch()
    end = time.monotonic() + 20
    while not Path(os.environ["SE_FINISH_RELEASE"]).exists():
        if time.monotonic() >= end:
            sys.exit(1)
        time.sleep(0.02)
''')
        child = subprocess.Popen([sys.executable, str(self.script), "finish", "--logged", "1"],
            cwd=self.cw, env=self.env(SESSION_END_TEST_HOOK=str(hook), SE_FINISH_READY=str(ready),
                                      SE_FINISH_RELEASE=str(release)),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            self.wait_for(ready.exists)
            p, obj = self.sej("pause", "--wait", "0", env=self.env(SESSION_END_LOCK_WAIT="0"))
            self.assertEqual(p.returncode, 1, "an overlapping ending replaced the receipt: " + p.stdout)
            self.assertIn("holds the billing lock", p.stdout)
            self.assertEqual(receipt.read_bytes(), original)
        finally:
            release.touch()
            out, err = child.communicate(timeout=30)
        self.assertEqual(child.returncode, 0, out + err)
        done = list((self.state / "session-end" / "done").iterdir())
        self.assertEqual(len(done), 1)
        self.assertEqual(done[0].read_bytes(), original)

    def test_a_new_work_log_during_start_stamp_archival_keeps_the_window_live(self):
        hook = self.tmp / "new-work-hook"
        self.write_exec(hook, '''#!/usr/bin/env python3
import os, sys
if sys.argv[1] == "archived" and os.path.basename(sys.argv[2]).startswith("session-start-"):
    key = os.path.basename(sys.argv[2])[len("session-start-"):]
    with open(os.path.join(os.path.dirname(sys.argv[2]), "work-log-" + key), "w") as f:
        f.write("new unbilled segment\\n")
''')
        f = self.close_then("--logged", "1", env=self.env(SESSION_END_TEST_HOOK=str(hook)))
        self.assertEqual(f.returncode, 1, f.stdout)
        self.assertEqual((self.run_dir / ("session-start-" + self.key)).read_bytes(),
                         self.stamps["session-start-" + self.key])
        self.assertEqual((self.run_dir / ("work-log-" + self.key)).read_bytes(), b"new unbilled segment\n")
        self.assertEqual(self.closeout.read_text(), "2026-11-01T09:00:00-04:00\n")

    def test_the_first_call_never_advances_last_closeout(self):
        self.transcript()
        for mode in ("pause", "move", "close"):
            p, _ = self.sej(mode, "--wait", "30")
            self.assertEqual(p.returncode, 0, p.stdout)
            self.assertEqual(self.closeout.read_text(), "2026-11-01T09:00:00-04:00\n", mode)
        self.assertEqual(self.se("finish").returncode, 2, "finish after a close needs a billing flag")
        self.assertEqual(self.closeout.read_text(), "2026-11-01T09:00:00-04:00\n")

    def test_finish_without_a_receipt_fails(self):
        f = self.se("finish")
        self.assertEqual(f.returncode, 1)
        self.assertIn("no receipt", f.stdout)
        self.assertEqual(self.closeout.read_text(), "2026-11-01T09:00:00-04:00\n")

    # --- lint, extras, modes ------------------------------------------------------

    def test_lint_runs_only_when_the_transcript_names_a_harness_file(self):
        self.transcript([("Read", {"file_path": str(self.proj / "README.md")}, "x", False)])
        p, obj = self.sej("pause", "--wait", "30")
        self.assertEqual(p.returncode, 0, p.stdout)
        self.assertEqual(self.calls("verify-ops.sh"), [])
        self.transcript([("Edit", {"file_path": str(self.cw / "SKILLS" / "x" / "SKILL.md")}, "ok", False)])
        self.behavior["verify-ops.sh"] = {"rc": 1, "out": "FAIL: check 7: something broke\n" + self.LINT_SUMMARY}
        self.save_behavior()
        p, obj = self.sej("pause", "--wait", "30")
        # Settled behavior: a completed lint's FAILs are findings, not a failed receipt.
        self.assertEqual(p.returncode, 0, p.stdout)
        self.assertEqual(self.step(obj, "lint")["status"], "findings")
        self.assertEqual([c["argv"] for c in self.calls("verify-ops.sh")], [["--quiet"]])
        self.assertIn("FAIL: check 7: something broke", self.step(obj, "lint")["output"])

    LINT_SUMMARY = "verify-ops: 57 ok · 1 warn · 2 fail (2026-11-17T18:00:00-05:00)"

    def lint_run(self, rc, out, *args):
        self.transcript([("Edit", {"file_path": str(self.cw / ".claude-config" / "bin" / "x")}, "ok", False)])
        self.behavior["verify-ops.sh"] = {"rc": rc, "out": out}
        self.save_behavior()
        return self.sej("pause", "--wait", "30", *args)

    def test_lint_fail_lines_with_the_gate_summary_are_findings_and_finish_still_stamps(self):
        out = ("FAIL: the launch environment overrides the auto-compact policy:\n  detail line\n"
               "WARN: disk-guard: last run is not healthy\n"
               "FAIL: SessionStart hook stdout over 8192B budget\n" + self.LINT_SUMMARY)
        self.behavior["verify-ops.sh"] = {"rc": 1, "out": out}
        self.save_behavior()
        self.transcript([("Edit", {"file_path": str(self.cw / ".claude-config" / "bin" / "x")}, "ok", False)])
        text = self.se("pause", "--wait", "30")
        self.assertEqual(text.returncode, 0, text.stdout)
        self.assertIn("[findings] lint:", text.stdout)
        p, obj = self.sej("pause", "--wait", "30")
        self.assertEqual(p.returncode, 0, "lint findings must not fail the receipt: " + p.stdout)
        self.assertEqual(obj["status"], "completed")
        lint = self.step(obj, "lint")
        self.assertEqual(lint["status"], "findings")
        self.assertEqual(lint["fail_lines"], ["FAIL: the launch environment overrides the auto-compact policy:",
                                              "FAIL: SessionStart hook stdout over 8192B budget"])
        self.assertIn("  - Lint reported 2 FAIL line(s) above: fix the ones on files this thread changed, "
                      "and name the rest as other work's in your report.", obj["remainder"])
        receipt = json.loads((self.state / "session-end" / (self.key + ".json")).read_text())
        self.assertEqual(receipt["status"], "completed")
        self.assertEqual(len(receipt["lint_findings"]), 2)
        f = self.se("finish")
        self.assertEqual(f.returncode, 0, f.stdout)
        self.assertIn("lint findings were reported at the start: 2", f.stdout)
        self.assertNotEqual(self.closeout.read_text(), "2026-11-01T09:00:00-04:00\n")

    def test_lint_without_a_readable_result_stays_failed_and_finish_refuses(self):
        for rc, out, why in ((1, "FAIL: check 7: something broke", "without the gate's summary line"),
                             (1, "", "without the gate's summary line"),
                             (1, self.LINT_SUMMARY.replace("2 fail", "0 fail"), "without the gate's summary line"),
                             (2, "verify-ops: unknown option", "exit 2 is neither")):
            p, obj = self.lint_run(rc, out)
            self.assertEqual(p.returncode, 1, (rc, out, p.stdout))
            lint = self.step(obj, "lint")
            self.assertEqual(lint["status"], "failed", (rc, out))
            self.assertIn(why, lint["summary"])
            self.assertFalse(any("Lint reported" in l for l in obj["remainder"]))
        f = self.se("finish")
        self.assertEqual(f.returncode, 1, f.stdout)
        self.assertEqual(self.closeout.read_text(), "2026-11-01T09:00:00-04:00\n")
        self.write_exec(self.bin / "verify-ops.sh", "#!/no-such-interpreter\n")
        self.transcript([("Edit", {"file_path": str(self.cw / ".claude-config" / "bin" / "x")}, "ok", False)])
        p, obj = self.sej("pause", "--wait", "30")
        self.assertEqual(p.returncode, 1)
        self.assertEqual(self.step(obj, "lint")["status"], "failed")
        self.assertIn("could not start", self.step(obj, "lint")["summary"])

    def test_a_clean_lint_is_completed_with_no_remainder_line(self):
        p, obj = self.lint_run(0, self.LINT_SUMMARY.replace("2 fail", "0 fail"))
        self.assertEqual(p.returncode, 0, p.stdout)
        self.assertEqual(self.step(obj, "lint")["status"], "completed")
        self.assertNotIn("fail_lines", self.step(obj, "lint"))
        self.assertFalse(any("Lint reported" in l for l in obj["remainder"]))

    def test_exit_zero_without_a_clean_gate_summary_cannot_complete_the_receipt(self):
        for out in ("", "a helper stopped before the summary", self.LINT_SUMMARY,
                    "FAIL: inconsistent result\n" + self.LINT_SUMMARY.replace("2 fail", "0 fail")):
            with self.subTest(output=out):
                p, obj = self.lint_run(0, out)
                self.assertEqual(p.returncode, 1, p.stdout)
                self.assertEqual(self.step(obj, "lint")["status"], "failed")
                f = self.se("finish")
                self.assertEqual(f.returncode, 1, f.stdout)
                self.assertEqual(self.closeout.read_text(), "2026-11-01T09:00:00-04:00\n")

    def test_lint_recognizes_relative_paths_and_another_harness_worktree(self):
        lane = self.home / "harness-worktree"
        g(self.cw, "worktree", "add", "-q", "-b", "lint-lane", str(lane))
        for inp in ({"file_path": str(lane / ".claude-config" / "bin" / "changed")},
                    {"file_path": ".claude-config/bin/changed"},
                    {"command": "sed -n '1p' SKILLS/example/SKILL.md"}):
            self.transcript([("Bash" if "command" in inp else "Edit", inp, "ok", False)])
            p, obj = self.sej("pause", "--dry-run", "--wait", "0", cwd=lane)
            self.assertEqual(p.returncode, 0, p.stdout)
            self.assertEqual(self.step(obj, "lint")["status"], "completed", inp)
            self.assertIn("would run", self.step(obj, "lint")["summary"])

    def test_a_helper_that_cannot_start_reports_the_os_error(self):
        self.write_exec(self.bin / "asks", "#!/no-such-interpreter\n")
        p, obj = self.sej("pause", "--wait", "30")
        self.assertEqual(p.returncode, 1, p.stdout)
        self.assertIn("cannot run", self.step(obj, "open asks")["output"])

    def test_vault_view_is_an_explicit_skip_that_runs_nothing(self):
        # OPS ships no vault renderer: the step says so, even beside a NOTES tree,
        # and starts no tool of its own in a real run or a dry run.
        (self.cw / "NOTES").mkdir()
        for args in (["pause", "--wait", "30"], ["pause", "--dry-run", "--wait", "30"]):
            p, obj = self.sej(*args)
            self.assertEqual(p.returncode, 0, p.stdout)
            vv = self.step(obj, "vault view")
            self.assertEqual(vv["status"], "skipped", args)
            self.assertIn("ships no vault renderer", vv["summary"])
        self.assertLessEqual({c["tool"] for c in self.calls()}, READ_ONLY_TOOLS)

    @staticmethod
    def section(text, step):
        """The human-output block of one step: its status line and indented lines."""
        m = re.search(r"^\[\w+\] %s:.*?(?=^\[|^\Z|\n\n)" % re.escape(step), text, re.M | re.S)
        return m.group(0) if m else ""

    def test_baton_is_resolved_where_the_notifier_reads_it_from_a_linked_worktree(self):
        # hooks/handoff-check.sh reads ${OPS_DIR:-$HOME/OPS}/.claude-handoffs, so a
        # run from a linked worktree (which holds no batons of its own) names ~/OPS's.
        lane = self.home / "ops-lane"
        g(self.cw, "worktree", "add", "-q", "-b", "lane", str(lane))
        script = lane / ".claude-config" / "bin" / "session-end"
        key = str(lane).replace("/", "-").lstrip("-")
        p = self.se("move", "--wait", "30", script=script, cwd=lane)
        self.assertEqual(p.returncode, 0, p.stdout)
        baton = self.cw / ".claude-handoffs" / "pending" / (key + ".md")
        self.assertIn("the baton is %s (not written yet)" % baton, p.stdout)
        self.assertNotIn(str(lane / ".claude-handoffs"), p.stdout)
        other = self.tmp / "ops-dir"
        p = self.se("move", "--wait", "30", script=script, cwd=lane, env=self.env(OPS_DIR=str(other)))
        self.assertEqual(p.returncode, 0, p.stdout)
        self.assertIn("the baton is %s (not written yet)" % (other / ".claude-handoffs" / "pending" / (key + ".md")),
                      p.stdout)

    def test_worktree_list_is_printed_once_and_capped(self):
        wts = []
        for i in range(5):
            w = self.home / "wt" / ("wl-%d" % i)
            g(self.proj, "worktree", "add", "-q", "-b", "wl%d" % i, str(w))
            wts.append(w)
        self.transcript([("Read", {"file_path": str(wts[3] / "README.md")}, "fixture", False)])
        p = self.se("pause", "--repo", str(self.proj), "--repo", str(wts[1]), "--wait", "30", cwd=wts[0])
        self.assertEqual(p.returncode, 0, p.stdout)
        snap = self.section(p.stdout, "git snapshot")
        self.assertEqual(snap.count("worktrees of main checkout %s: 6" % self.proj), 1, snap)
        self.assertEqual(snap.count("worktrees: see main checkout %s" % self.proj), 3, snap)
        self.assertIn("worktree %s [wl0] (this call's cwd)" % wts[0], snap)
        self.assertIn("worktree %s [wl3]" % wts[3], snap)
        for hidden in (wts[2], wts[4]):
            self.assertNotIn(str(hidden), snap)
        self.assertIn("... and 4 more (git -C %s worktree list)" % self.proj, snap)

    def gc_rows_fixture(self):
        P = str(self.proj)
        wt = self.home / "wt-named"
        self.behavior["branch-gc"] = {"rows": [
            [P, "feat-done", "-", "#7 MERGED", "remove", "tip == merged PR #7 head"],
            [P, "named-br", "-", "#9 OPEN", "report", "open PR"],
            [P, "lane", str(wt), "-", "report", "dirty worktree"],
            [P, "unnamed-a", "-", "-", "report", "no PR"],
            [P, "unnamed-b", "-", "-", "report", "no PR"],
            [P, "gone", "-", "-", "skip", "worktree quarantined earlier in this run"]]}
        self.save_behavior()
        self.transcript([("Bash", {"command": "git -C %s log --oneline named-br" % P}, "abc", False),
                         ("Read", {"file_path": str(wt / "notes.txt")}, "x", False)])

    def test_gc_human_output_keeps_actions_and_named_rows_and_counts_the_rest(self):
        self.gc_rows_fixture()
        for args, ref in ((["--dry-run"], "they are in --json"), ([], "full output: ")):
            p = self.se("pause", "--repo", str(self.proj), "--wait", "30", *args)
            self.assertEqual(p.returncode, 0, p.stdout)
            gc = self.section(p.stdout, "branch-gc")
            for shown in ("branch-gc ", "feat-done\t-\t#7 MERGED\tremove", "named-br", "dirty worktree",
                          "gone\t-\t-\tskip", "Summary (remove / report / quarantine / failed):"):
                self.assertIn(shown, gc, args)
            for hidden in ("unnamed-a", "unnamed-b"):
                self.assertNotIn(hidden, gc, "an unnamed report row reached the human output %s" % args)
            self.assertIn("2 report-only rows not shown; " + ref, gc)
            pj, obj = self.sej("pause", "--repo", str(self.proj), "--wait", "30", *args)
            full = self.step(obj, "branch-gc")["output"]
            self.assertIn("unnamed-a", full, "--json must keep the full child output %s" % args)
            self.assertNotIn("human", self.step(obj, "branch-gc"))
        self.assertRegex(gc, r"full output: \S+/session-end/gc/[^/\s]+/run\.log")

    def test_gc_output_that_is_not_the_documented_tsv_is_printed_whole(self):
        self.behavior["branch-gc"] = {"raw": "branch-gc: something unexpected\nreport\tonly\tfour\tcols"}
        self.save_behavior()
        p = self.se("pause", "--dry-run", "--repo", str(self.proj), "--wait", "30")
        gc = self.section(p.stdout, "branch-gc")
        self.assertIn("branch-gc: something unexpected", gc)
        self.assertIn("report\tonly\tfour\tcols", gc)
        self.assertNotIn("not shown", gc)

    def test_json_retains_child_output_beyond_the_human_limit(self):
        raw = "branch-gc: " + "x" * 70000 + "\nLAST CHILD OUTPUT LINE"
        self.behavior["branch-gc"] = {"raw": raw}
        self.save_behavior()
        for extra in (["--dry-run"], []):
            p, obj = self.sej("pause", "--repo", str(self.proj), "--wait", "30", *extra)
            self.assertEqual(p.returncode, 0, p.stdout[-1000:])
            full = self.step(obj, "branch-gc")["output"]
            self.assertTrue(raw.splitlines()[0] in full, "JSON truncated the child's output")
            self.assertIn("LAST CHILD OUTPUT LINE", full)
            human = self.se("pause", "--repo", str(self.proj), "--wait", "30", *extra)
            self.assertEqual(human.returncode, 0, human.stdout[-1000:])
            self.assertIn("output cut at 65536 characters", human.stdout)
            self.assertNotIn("LAST CHILD OUTPUT LINE", human.stdout)

    def test_modes_unknown_is_2_pause_has_no_settle_close_has_no_compact(self):
        self.assertEqual(self.se("wrap").returncode, 2)
        self.assertEqual(self.se("pause", "--wait", "-1").returncode, 2)
        self.assertEqual(self.se("pause", "--wait", "nan").returncode, 2)
        self.assertEqual(self.se("pause", "--repo", str(self.tmp / "missing")).returncode, 2)
        self.transcript()
        p = self.se("pause", "--wait", "30")
        self.assertIn("compact-cycle.sh --target %s" % TID, p.stdout)
        self.assertIn("Never compact over an unanswered question", p.stdout)
        self.assertNotIn("Settle", p.stdout)
        c = self.se("close", "--wait", "30")
        self.assertNotIn("compact-cycle", c.stdout)
        self.assertIn('t3_thread_organize with action "settle"', c.stdout)
        self.assertIn("Never both", c.stdout)
        self.assertNotIn("settled", c.stdout.replace("unsettled", ""))
        for field in ("NEXT ACTION (one step)", "VERIFY FIRST", "DO NOT (with who said so)", "DEAD ENDS", "ASK THE OWNER"):
            self.assertIn(field, c.stdout)

    def test_move_reports_the_baton_from_key_sh_in_the_original_cwd(self):
        key = str(self.proj).replace("/", "-").lstrip("-")
        p = self.se("move", "--wait", "30", cwd=self.proj)
        baton = self.cw / ".claude-handoffs" / "pending" / (key + ".md")
        self.assertIn("the baton is %s (not written yet)" % baton, p.stdout)
        baton.write_text("status: pending\n")
        p = self.se("move", "--wait", "30", cwd=self.proj)
        self.assertIn("the baton is %s (exists" % baton, p.stdout)

    # --- the transcript, time and ids -------------------------------------------

    def test_missing_or_foreign_transcript_infers_nothing_and_gives_no_time(self):
        p, obj = self.sej("close", "--repo", str(self.proj), "--wait", "30")
        self.assertEqual(p.returncode, 0, p.stdout)
        self.assertEqual([c["argv"][-1] for c in self.gc_applies()], [str(self.proj)])
        self.assertIn("no time figure", self.step(obj, "time")["summary"])
        self.assertEqual(self.calls("active-minutes"), [])
        bad = self.tmp / "foreign.jsonl"
        bad.write_text(json.dumps({"type": "user", "sessionId": "another-session", "message": {"content": "x"}}) + "\n")
        p, obj = self.sej("close", "--transcript", str(bad), "--wait", "30")
        self.assertIn("another session", self.step(obj, "transcript")["summary"])
        self.assertEqual(self.step(obj, "time")["status"], "skipped")
        torn = self.tmp / "torn.jsonl"
        torn.write_text(json.dumps({"type": "user", "sessionId": SID, "message": {"content": "x"}}) + "\nnot json\n"
                        + json.dumps({"type": "assistant", "sessionId": SID, "message": {"content": []}}) + "\n")
        p, obj = self.sej("close", "--transcript", str(torn), "--wait", "30")
        self.assertIn("unsupported format", self.step(obj, "transcript")["summary"])
        self.assertEqual(obj["identity"]["session_id"], SID)
        self.assertEqual(obj["identity"]["t3_thread_id"], TID)
        self.assertNotIn(str(self.cw), [c["argv"][-1] for c in self.gc_applies()])

    def test_time_passes_lane_transcripts_and_never_a_silent_total(self):
        tx = self.transcript([("Agent", {"prompt": "lane"}, "done", False)])
        base = Path(str(tx)[:-len(".jsonl")])
        (base / "subagents" / "workflows" / "w1").mkdir(parents=True)
        lane = base / "subagents" / "agent-a1.jsonl"
        lane.write_text("{}\n")
        wf = base / "subagents" / "workflows" / "w1" / "agent-b2.jsonl"
        wf.write_text("{}\n")
        p, obj = self.sej("close", "--wait", "30")
        self.assertEqual(self.calls("active-minutes")[0]["argv"], [str(tx), "--also", str(lane), str(wf)])
        t = self.step(obj, "time")
        self.assertTrue(t["confident"])
        self.assertIn("evidence, not an amount to enter", t["summary"])
        shutil.rmtree(base)
        p, obj = self.sej("close", "--wait", "30")
        t = self.step(obj, "time")
        self.assertFalse(t["confident"])
        self.assertIn("NOT CONFIDENT", t["summary"])
        self.behavior["active-minutes"] = {"rc": 1, "out": "not enough timestamped events to measure"}
        self.save_behavior()
        p, obj = self.sej("close", "--wait", "30")
        self.assertEqual(p.returncode, 1)
        self.assertEqual(self.step(obj, "time")["status"], "failed")
        self.assertIn("no time figure", self.step(obj, "time")["summary"])

    # --- memory -------------------------------------------------------------------

    def test_memory_pool_backfill_absent_pool_and_failed_rebuild(self):
        p, obj = self.sej("pause", "--wait", "30", cwd=self.proj, env=self.env(CLAUDE_PROJECT_DIR=str(self.other)))
        self.assertEqual(self.calls("memory-index")[0]["argv"], ["--pool-for", "--cwd", str(self.other),
                                                                 "--ops", str(self.cw)])
        self.assertEqual(self.calls("memory-index")[1]["argv"], [str(self.pool)])
        self.behavior["memory-index"] = {"pool": str(self.pool), "rebuild_rc": 2}
        self.save_behavior()
        p, obj = self.sej("pause", "--wait", "30")
        self.assertEqual(p.returncode, 0)
        self.assertIn("need backfill", self.step(obj, "memory index")["summary"])
        self.behavior["memory-index"] = {"pool": str(self.pool), "rebuild_rc": 1}
        self.save_behavior()
        p, obj = self.sej("pause", "--wait", "30")
        self.assertEqual(p.returncode, 1)
        self.assertEqual(self.step(obj, "memory index")["status"], "failed")
        self.behavior["memory-index"] = {}
        self.save_behavior()
        n = len(self.calls("memory-index"))
        p, obj = self.sej("pause", "--wait", "30")
        self.assertEqual(p.returncode, 0)
        self.assertEqual(self.step(obj, "memory index")["status"], "skipped")
        self.assertEqual(len(self.calls("memory-index")), n + 1, "a rebuild ran without a pool")

    def test_memory_stewardship_lists_only_entries_in_the_window_and_changes_none(self):
        inside = self.pool / "lesson-new.md"
        inside.write_text("---\nname: lesson-new\nmetadata:\n  type: feedback\n  modified: %s\n---\nbody\n" % time.strftime("%Y-%m-%d"))
        outside = self.pool / "lesson-old.md"
        outside.write_text("---\nname: lesson-old\nmetadata:\n  type: feedback\n  modified: 2020-01-01\n---\nold\n")
        os.utime(outside, (1577880000, 1577880000))
        before = tree_state(self.pool)
        self.transcript()
        p = self.se("pause", "--wait", "30")
        self.assertIn("lesson-new.md", p.stdout)
        self.assertNotIn("lesson-old.md", p.stdout)
        # The pool is shared by concurrent threads: the label must not claim authorship.
        self.assertIn("entries written or changed in this pool during this thread's window, "
                      "by this thread or another one sharing the pool", p.stdout)
        self.assertIn("session-end changed no entry", p.stdout)
        self.assertEqual(tree_state(self.pool), before)

    # --- OPS: what this port must agree with ---------------------------------------

    def test_gc_reaches_exactly_the_repos_the_pre_compact_hook_would(self):
        # hooks/pre-compact.sh hands branch-gc ~/OPS, ~/OPS/PROJECTS/<org>/<repo> and
        # ~/linuxploitacious by name under the real HOME, wherever the hook itself
        # lives. A clone of OPS under another name is not managed, even when this
        # command runs from it; ~/OPS still is.
        copy = self.home / "ops-copy"
        g(self.home, "clone", "-q", str(self.cw), str(copy))
        g(copy, "config", "remote.origin.url", "https://github.com/acme/harness-copy.git")
        lx = make_repo(self.home / "linuxploitacious", origin="https://github.com/acme/linuxploitacious.git")
        script = copy / ".claude-config" / "bin" / "session-end"
        p, obj = self.sej("pause", "--repo", str(copy), "--repo", str(self.cw), "--repo", str(lx),
                          "--wait", "30", script=script, cwd=copy)
        self.assertEqual(p.returncode, 0, p.stdout)
        self.assertEqual(sorted(c["argv"][-1] for c in self.gc_applies()), sorted([str(self.cw), str(lx)]))
        self.assertIn("not run: %s is not a repo branch-gc manages" % copy, self.step(obj, "branch-gc")["output"])

    def test_lint_is_verify_ops_quiet_against_this_checkout_and_reads_its_summary(self):
        p, obj = self.lint_run(1, "FAIL: check 3: drift\n" + self.LINT_SUMMARY)
        self.assertEqual(p.returncode, 0, p.stdout)
        call = self.calls("verify-ops.sh")[0]
        self.assertEqual(call["argv"], ["--quiet"], "verify-ops.sh has no lint mode; --quiet is the quiet run")
        self.assertEqual(call["env"]["OPS_DIR"], str(self.cw), "the gate must check this checkout, not ~/OPS")
        self.assertEqual(self.step(obj, "lint")["status"], "findings")
        p, obj = self.lint_run(1, "FAIL: check 3: drift\n" + self.LINT_SUMMARY.replace("verify-ops:", "verify-other:"))
        self.assertEqual(p.returncode, 1, p.stdout)
        self.assertEqual(self.step(obj, "lint")["status"], "failed", "another gate's summary line is not this gate's result")
        p, obj = self.lint_run(0, "", "--dry-run")
        self.assertIn("would run OPS_DIR=%s %s --quiet" % (self.cw, self.bin / "verify-ops.sh"),
                      self.step(obj, "lint")["summary"])

    def test_ops_state_dir_wins_and_a_missing_gate_is_visible(self):
        alt = self.tmp / "alt-state"
        self.transcript()
        p, obj = self.sej("pause", "--wait", "30", env=self.env(OPS_STATE_DIR=str(alt)))
        self.assertEqual(p.returncode, 0, p.stdout)
        self.assertTrue((alt / "session-end" / (self.key + ".json")).is_file())
        self.assertFalse((self.state / "session-end").exists(), "OPS_STATE_DIR was ignored")
        (self.bin / "verify-ops.sh").unlink()
        before = len(self.calls("branch-gc"))
        p, obj = self.sej("pause", "--wait", "30")
        self.assertEqual(p.returncode, 1, p.stdout)
        self.assertIn("no gate script beside session-end", self.step(obj, "receipt")["summary"])
        self.assertEqual(len(self.calls("branch-gc")), before, "GC started without a state directory")
        self.transcript([("Edit", {"file_path": str(self.cw / ".claude-config" / "bin" / "x")}, "ok", False)])
        p, obj = self.sej("pause", "--wait", "30", env=self.env(OPS_STATE_DIR=str(alt)))
        self.assertEqual(p.returncode, 1, p.stdout)
        self.assertEqual(self.step(obj, "lint")["status"], "failed")
        self.assertIn("no gate script sits beside session-end", self.step(obj, "lint")["summary"])

    def test_the_stamp_key_and_backend_come_from_ops_hooklib(self):
        # T3CODE_HOME alone marks a T3 thread for ops_backend: the key is t3-<session id>.
        env = self.env(T3CODE_THREAD_ID=None, T3CODE_HOME=str(self.tmp / "t3home"))
        f = self.close_then("--logged", "1", env=env)
        self.assertEqual(f.returncode, 0, f.stdout)
        self.assertEqual(len(self.archive_dirs()), 1)
        self.assertFalse((self.run_dir / ("session-start-" + self.key)).exists())
        # A tmux session keys stamps by session name, which finish does not verify.
        self.write_exec(self.stubbin / "tmux", "#!/bin/sh\necho fixture-tmux\n")
        env = self.env(TMUX="/tmp/fixture-tmux,1,0")
        (self.run_dir / "session-start-fixture-tmux").write_bytes(b"tmux window\n")
        self.transcript()
        self.assertEqual(self.sej("close", "--wait", "30", env=env)[0].returncode, 0)
        f = self.se("finish", "--logged", "1", env=env)
        self.assertEqual(f.returncode, 1, f.stdout)
        self.assertIn("the tmux backend keys stamps by session name", f.stdout)
        self.assertEqual((self.run_dir / "session-start-fixture-tmux").read_bytes(), b"tmux window\n")
        # A hooklib.sh without ops_backend gives no key at all, and says why.
        self.write_exec(self.cw / ".claude-config" / "hooks" / "hooklib.sh",
                        "work_session_key() { printf t3-x; }\nhook_timeout() { printf gnutimeout; }\n")
        before = len(self.calls("branch-gc"))
        p, obj = self.sej("pause", "--repo", str(self.proj), "--wait", "30")
        self.assertEqual(p.returncode, 1, p.stdout)
        self.assertIn("defines no work_session_key or ops_backend", p.stdout)
        self.assertEqual(len(self.calls("branch-gc")), before, "GC started without a trusted stamp key")

    def test_memory_pool_lookup_names_the_checkout_the_digest_hook_passes(self):
        self.assertEqual(self.sej("pause", "--wait", "30")[0].returncode, 0)
        other = self.tmp / "ops-dir"
        self.assertEqual(self.sej("pause", "--wait", "30", env=self.env(OPS_DIR=str(other)))[0].returncode, 0)
        looks = [c["argv"] for c in self.calls("memory-index") if c["argv"][:1] == ["--pool-for"]]
        self.assertEqual(looks, [["--pool-for", "--cwd", str(self.cw), "--ops", str(self.cw)],
                                 ["--pool-for", "--cwd", str(self.cw), "--ops", str(other)]])


if __name__ == "__main__":
    unittest.main(verbosity=2)
