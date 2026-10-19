"""sandbox_guard.py - the Python twin of sandbox-guard.sh.

The first statement of every Python test suite that runs a destructive tool
(after the docstring and any __future__ import) is this one line:

    import os, runpy; runpy.run_path(os.path.join(os.path.dirname(os.path.realpath(__file__)), "..", "sandbox_guard.py"))["require"]()

require() exits 97 with "refusing to run outside sandbox-run: <reason>" unless
the process is inside a sandbox built by bin/sandbox-run. The environment alone
never satisfies it: the mount table must show the root filesystem read-only, a
tmpfs mounted at the account's home directory, $HOME on a tmpfs (a suite may
point it at a fixture under /tmp before starting another guarded suite), and
the nonce file /tmp/.ops-sandbox/nonce as a read-only mount whose content
equals OPS_SANDBOX_NONCE; OPS_SANDBOX must be 1. Keep it in step with
sandbox-guard.sh (tests/sandbox-run-test.sh runs both on the same cases).

run_path, not import: loading the file this way leaves sys.path and
sys.modules as the suite found them. Stdlib only, no side effects on load.

Run as a script it prints "ok" (exit 0) or the refusal (exit 97).
"""
import os
import pwd
import re
import sys

NONCE_FILE = "/tmp/.ops-sandbox/nonce"
REFUSAL = "refusing to run outside sandbox-run"


def _escape(path):
    """PATH escaped the way /proc/self/mountinfo writes it."""
    return (path.replace("\\", "\\134").replace(" ", "\\040")
            .replace("\t", "\\011").replace("\n", "\\012"))


def top_mount(path, mountinfo="/proc/self/mountinfo"):
    """(options, fstype) of the mount visible at exactly PATH, or None when
    nothing is mounted there, the table cannot be read, or the stack of
    mounts on that point has more than one top (never guess)."""
    want = _escape(path)
    entries = []
    try:
        with open(mountinfo, encoding="utf-8", errors="surrogateescape") as f:
            for line in f:
                fields = line.split()
                if len(fields) < 7 or fields[4] != want:
                    continue
                if "-" not in fields[6:]:
                    return None
                sep = fields.index("-", 6)
                if sep + 1 >= len(fields):
                    return None
                entries.append((fields[0], fields[1], fields[5], fields[sep + 1]))
    except OSError:
        return None
    tops = [e for e in entries if not any(o[1] == e[0] for o in entries)]
    if len(tops) != 1:
        return None
    return tops[0][2], tops[0][3]


def holder(path, mountinfo="/proc/self/mountinfo"):
    """The mount point (unescaped) of the mount holding PATH: the longest
    mount point that is PATH or a parent of it; None if unreadable."""
    want = _escape(path)
    best = None
    try:
        with open(mountinfo, encoding="utf-8", errors="surrogateescape") as f:
            for line in f:
                fields = line.split()
                if len(fields) < 5:
                    continue
                mp = fields[4]
                if (want + "/").startswith(mp.rstrip("/") + "/") and (best is None or len(mp) > len(best)):
                    best = mp
    except OSError:
        return None
    if best is None:
        return None
    return (best.replace("\\040", " ").replace("\\011", "\t")
            .replace("\\012", "\n").replace("\\134", "\\"))


def check():
    """(True, "") inside the sandbox, else (False, the first failed condition)."""
    root = top_mount("/")
    if root is None:
        return False, "cannot read the mount at / from /proc/self/mountinfo"
    if "ro" not in root[0].split(","):
        return False, "the root filesystem is mounted read-write"
    home = os.environ.get("HOME", "")
    if not home.startswith("/"):
        return False, "HOME is unset or not absolute"
    h = holder(os.path.realpath(home))
    m = top_mount(h) if h is not None else None
    if m is None or m[1] != "tmpfs":
        return False, "HOME (%s) is not on a tmpfs" % home
    try:
        pw_home = os.path.realpath(pwd.getpwuid(os.getuid()).pw_dir)
    except KeyError:
        return False, "cannot find the account's home directory"
    m = top_mount(pw_home)
    if m is None or m[1] != "tmpfs":
        return False, "the account's home directory (%s) is not hidden behind a tmpfs" % pw_home
    if os.environ.get("OPS_SANDBOX") != "1":
        return False, "OPS_SANDBOX is not 1"
    nonce = os.environ.get("OPS_SANDBOX_NONCE", "")
    if not re.fullmatch(r"[0-9a-f]{32}", nonce):
        return False, "OPS_SANDBOX_NONCE is missing or malformed"
    m = top_mount(NONCE_FILE)
    if m is None:
        return False, "the nonce file %s is not a mount" % NONCE_FILE
    if "ro" not in m[0].split(","):
        return False, "the nonce file is not mounted read-only"
    try:
        with open(NONCE_FILE, encoding="ascii", errors="replace") as f:
            content = f.readline().rstrip("\n")
    except OSError:
        content = ""
    if content != nonce:
        return False, "the nonce file does not match OPS_SANDBOX_NONCE"
    return True, ""


def require():
    """Return inside the sandbox; otherwise print the refusal and exit 97."""
    ok, reason = check()
    if ok:
        return
    sys.stderr.write("%s: %s\n  run it through the sandbox (bin/README.md, sandbox-run): "
                     ".claude-config/bin/sandbox-run --no-net --ro-bind <checkout> -- python3 %s\n"
                     % (REFUSAL, reason, sys.argv[0] or "<suite>"))
    sys.stderr.flush()
    raise SystemExit(97)


if __name__ == "__main__":
    require()
    print("ok")
