#!/usr/bin/env python3
"""mcp-reselect.py: which deferred tools did this session have, so that a resumed
session can re-select them.

Why. Every MCP tool and a few built-ins (Monitor, WebFetch, WebSearch, ...) are
deferred: their schemas reach the model only after ToolSearch selects them. A
compaction drops that selection while the summary still names the tool, so the
model calls it from memory and the call fails ("This tool's schema was not sent to
the API", or an input-validation error from a guessed parameter name). In one
operator's replay of 56 long sessions, 51 of 858 calls (5.9%) to a deferred tool
that was not re-selected after a compaction failed, against 7 of 15,691 (0.045%)
once it was selected. The failed calls are harmless retries, but they were the
largest MCP error bucket, and nothing told a resumed session which tools to
re-select. post-compact-resume.sh now does, from this helper.

Two modes, both printing one tool name per line (nothing when there are none):

  mcp-reselect.py used <transcript>
      The deferred tools CALLED since the previous compaction, most recent first.
      pre-compact.sh runs this before the compaction and writes the list into the
      snapshot, so it is on disk before Claude Code writes anything.

  mcp-reselect.py resume <transcript> [--snapshot FILE] [--max N]
      The tools to re-select after the compaction that just happened, most recently
      used first, at most N (default 40). Source, in order:
        1. compactMetadata.preCompactDiscoveredTools of the newest compact_boundary
           record in the transcript, when that record is fresh (written in the last
           5 minutes, so it is THIS compaction and not an older one): these are the
           names Claude Code itself tracked as discovered. 17 to 54 names per
           compaction were seen. Claude Code writes the boundary a fraction of a
           second before it runs the SessionStart(compact) hooks, but whether the
           record is flushed to disk when the hook reads it is UNVERIFIED, hence the
           fallbacks.
        2. The snapshot's "Deferred tools used before this compaction" section,
           which pre-compact.sh wrote from the `used` mode.
        3. The transcript itself: tools called since the boundary before the newest
           one (or since the start of the window).
      The first line printed is a source tag, `# source: boundary|snapshot|transcript`,
      then a `# total: N` line, then the names. A name is kept only if it matches
      [A-Za-z0-9_.-]+.

Deferred means an mcp__ tool, or one of the deferred built-ins: the names in the
transcript's own deferred_tools_delta records when the window holds them, else a
constant set. The transcript is read from its last 8 MB; a session whose newest
boundary is older than that is treated as having none. Read-only; never raises:
any failure prints nothing and exits 0, so a hook that calls it stays quiet.

Example (synthetic names): after a session that called mcp__example-server__lookup,
then Bash, then Monitor, `mcp-reselect.py used <transcript>` prints
    Monitor
    mcp__example-server__lookup
(Bash is never deferred, and the most recent use comes first).
"""
import json
import os
import re
import sys
import time
from datetime import datetime, timezone

WINDOW_BYTES = 8_000_000
FRESH_SECONDS = 300
NAME_RE = re.compile(r"^[A-Za-z0-9_.-]{1,160}$")
SECTION = "## Deferred tools used before this compaction"

# The built-ins that Claude Code defers (seen in its tool lists, 2026-11-07). The
# transcript's deferred_tools_delta records override this.
DEFERRED_BUILTINS = {
    "ArtifactComments", "ArtifactData", "CronCreate", "CronDelete", "CronList",
    "DesignSync", "EnterWorktree", "ExitWorktree", "ListMcpResourcesTool", "Monitor",
    "NotebookEdit", "PushNotification", "ReadMcpResourceDirTool", "ReadMcpResourceTool",
    "RemoteTrigger", "SendMessage", "TaskStop", "WebFetch", "WebSearch",
}


def read_window(path):
    size = os.path.getsize(path)
    with open(path, "rb") as f:
        start = max(0, size - WINDOW_BYTES)
        f.seek(start)
        data = f.read()
    text = data.decode("utf-8", "replace")
    lines = text.split("\n")
    if start > 0 and lines:
        lines = lines[1:]  # the first line is cut mid-record
    return lines


def parse_ts(value):
    if not isinstance(value, str) or not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc).timestamp()
    except ValueError:
        return None


def scan(lines):
    """(events, deferred names announced) from the window's lines.

    events: ("boundary", index, record) and ("use", index, name) in file order."""
    events = []
    announced = set()
    for i, line in enumerate(lines):
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if not isinstance(e, dict) or e.get("isSidechain"):
            continue
        if e.get("type") == "system" and e.get("subtype") == "compact_boundary":
            events.append(("boundary", i, e))
            continue
        a = e.get("attachment")
        if isinstance(a, dict) and a.get("type") == "deferred_tools_delta":
            added, removed = a.get("addedNames"), a.get("removedNames")
            if isinstance(added, list):
                for n in added:
                    if isinstance(n, str):
                        announced.add(n)
            if isinstance(removed, list):
                for n in removed:
                    if not isinstance(n, str):
                        continue
                    announced.discard(n)
            continue
        message = e.get("message")
        if e.get("type") != "assistant" or not isinstance(message, dict):
            continue
        content = message.get("content")
        if not isinstance(content, list):
            continue
        for b in content:
            if isinstance(b, dict) and b.get("type") == "tool_use" and isinstance(b.get("name"), str):
                events.append(("use", i, b["name"]))
    return events, announced


def used_names(events, announced, lo, hi):
    """Deferred tool names called at line indexes in (lo, hi), most recent first."""
    deferred = announced or DEFERRED_BUILTINS
    seen, out = set(), []
    for kind, i, v in reversed(events):
        if kind != "use" or not (lo < i < hi):
            continue
        if v in seen or not NAME_RE.match(v):
            continue
        if v.startswith("mcp__") or v in deferred or v in DEFERRED_BUILTINS:
            seen.add(v)
            out.append(v)
    return out


def snapshot_names(path):
    names, inside = [], False
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for raw in f:
                line = raw.rstrip("\n")
                if line.strip() == SECTION:
                    inside = True
                    continue
                if inside and line.startswith("## "):
                    break
                if inside and line.startswith("- "):
                    n = line[2:].strip().strip("`")
                    if NAME_RE.match(n):
                        names.append(n)
    except OSError:
        pass
    return names


def main(argv):
    if len(argv) < 3 or argv[1] not in ("used", "resume"):
        return 0
    mode, transcript = argv[1], argv[2]
    snapshot, cap = "", 40
    rest = argv[3:]
    while rest:
        a = rest.pop(0)
        if a == "--snapshot" and rest:
            snapshot = rest.pop(0)
        elif a == "--max" and rest:
            try:
                cap = max(1, int(rest.pop(0)))
            except ValueError:
                pass
    lines = []
    if transcript and os.path.isfile(transcript):
        lines = read_window(transcript)
    events, announced = scan(lines)
    boundaries = [(i, e) for k, i, e in events if k == "boundary"]

    if mode == "used":
        lo = boundaries[-1][0] if boundaries else -1
        for n in used_names(events, announced, lo, len(lines) + 1):
            print(n)
        return 0

    now = time.time()
    fresh = None
    if boundaries:
        ts = parse_ts(boundaries[-1][1].get("timestamp"))
        # Calls after a boundary prove it belongs to an earlier compaction, even
        # if that happened less than five minutes ago. The current boundary may
        # not be flushed yet; in that case prefer the just-written snapshot.
        called_after = any(k == "use" and i > boundaries[-1][0] for k, i, _ in events)
        if ts is not None and 0 <= now - ts <= FRESH_SECONDS and not called_after:
            fresh = boundaries[-1]
    # Where the segment before this compaction lies: from the boundary before the
    # newest (or the window's start) to the newest boundary when it is fresh, else
    # to the end of the window (the boundary has not been flushed yet).
    if fresh is not None:
        hi = fresh[0]
        lo = boundaries[-2][0] if len(boundaries) >= 2 else -1
    else:
        hi = len(lines) + 1
        lo = boundaries[-1][0] if boundaries else -1
    recent = used_names(events, announced, lo, hi)

    names, source = [], ""
    if fresh is not None:
        metadata = fresh[1].get("compactMetadata")
        listed = metadata.get("preCompactDiscoveredTools") if isinstance(metadata, dict) else None
        if isinstance(listed, list):
            names = [n for n in listed if isinstance(n, str) and NAME_RE.match(n)]
            source = "boundary"
    if not names and snapshot:
        names = snapshot_names(snapshot)
        source = "snapshot"
    if not names:
        names, source = list(recent), "transcript"
    if not names:
        return 0
    # Most recently used first, then the rest in the order they were listed.
    rank = {n: k for k, n in enumerate(recent)}
    names = sorted(dict.fromkeys(names), key=lambda n: (rank.get(n, len(rank)), names.index(n)))
    print(f"# source: {source}")
    print(f"# total: {len(names)}")
    for n in names[:cap]:
        print(n)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Exception:  # noqa: BLE001 - the hook boundary deliberately fails open
        sys.exit(0)
