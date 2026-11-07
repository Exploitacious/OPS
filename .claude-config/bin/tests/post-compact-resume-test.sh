#!/usr/bin/env bash
# post-compact-resume-test.sh: behavior tests for the deferred-tool re-select block
# that hooks/post-compact-resume.sh prints after a compaction, and for
# hooks/mcp-reselect.py, the helper that picks the names.
#
# The defect: a compaction drops every deferred tool's schema (every mcp__ tool and
# built-ins such as Monitor and WebFetch) while the summary still names the tool, so
# the resumed session calls it from memory and the call fails. Nothing told a
# resumed session which tools to re-select.
#
# Pinned, with fixture transcripts shaped like the real ones (compact_boundary system
# records carrying compactMetadata.preCompactDiscoveredTools, assistant tool_use
# blocks):
#   - a fresh boundary's preCompactDiscoveredTools is the source, most recently used
#     tools first, with the instruction to select LAZILY, one name before its first call;
#   - a stale boundary (an older compaction) is not trusted: the snapshot's "Deferred
#     tools" section is the source, and the snapshot prints without that section so no
#     name is listed twice;
#   - with neither, the tool calls since the previous compaction are the source, and a
#     tool called only before that earlier boundary is not named;
#   - nothing to name prints no block at all, and the snapshot prints as before;
#   - a long list is capped at 40 with a "+N more" line; names that are not tool-name
#     shaped are dropped; garbage transcript lines never crash it;
#   - the block also prints when there is no snapshot, and not for source=startup;
#   - the hook exits 0 and prints nothing extra when python or the helper is missing.
#
# Every path is a fixture under a temp dir; the real ~/.claude is never read. The hook
# finds its snapshot under CLAUDE_CONFIG_DIR/projects/<cwd with / as ->, so the fixture
# puts the snapshot there and runs the hook from a fixture work directory.
#
# Usage: post-compact-resume-test.sh    (exit 0 all pass, 1 otherwise)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
HOOK="${POST_COMPACT_UNDER_TEST:-$HERE/../../hooks/post-compact-resume.sh}"
HELPER="$HERE/../../hooks/mcp-reselect.py"
[ -f "$HOOK" ] && [ -f "$HELPER" ] || { echo "FAIL: hook or helper missing"; exit 1; }
command -v python3 >/dev/null || { echo "FAIL: python3 required"; exit 1; }
command -v jq >/dev/null || { echo "FAIL: jq required (the hook's own parser)"; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1"; [ $# -gt 1 ] && printf '    %s\n' "$2"; }
mkdir -p "$T/home" "$T/cfg" "$T/work"
# Where the hook looks for this workspace's snapshot.
SNAPDIR="$T/cfg/projects/$(printf '%s' "$T/work" | sed 's|/|-|g')"
mkdir -p "$SNAPDIR"
export PYTHONDONTWRITEBYTECODE=1

# tx <file> <record>...: write a transcript from python-built records
# Records: "use NAME" | "usesc NAME" | "boundary AGE_SECONDS NAME,NAME,..." | "raw TEXT"
tx() {
  local f="$1"; shift
  python3 -I - "$f" "$@" <<'PY'
import json, sys, time
from datetime import datetime, timezone
f, recs = sys.argv[1], sys.argv[2:]
with open(f, "w") as out:
    for r in recs:
        kind, _, rest = r.partition(" ")
        if kind in ("use", "usesc"):
            out.write(json.dumps({"type": "assistant", "isSidechain": kind == "usesc", "message": {"role": "assistant", "content": [
                {"type": "text", "text": "x"}, {"type": "tool_use", "id": "t", "name": rest, "input": {}}]}}) + "\n")
        elif kind == "boundary":
            age, _, names = rest.partition(" ")
            ts = datetime.fromtimestamp(time.time() - int(age), timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
            meta = {"trigger": "manual", "preTokens": 1}
            if names != "-":
                meta["preCompactDiscoveredTools"] = names.split(",") if names else []
            out.write(json.dumps({"type": "system", "subtype": "compact_boundary", "compactMetadata": meta, "timestamp": ts}) + "\n")
        elif kind == "raw":
            out.write(rest + "\n")
PY
}

# run_hook <payload JSON> [VAR=value ...]: stdout in $out, exit code in $rc.
run_hook() {
  local payload="$1"; shift
  out="$(cd "$T/work" && printf '%s' "$payload" | env HOME="$T/home" CLAUDE_CONFIG_DIR="$T/cfg" \
      POST_COMPACT_RESUME_DEBUG_LOG="$T/debug.log" "$@" bash "$HOOK" 2>"$T/err")"
  rc=$?
}
compact_payload() { printf '{"source":"compact","session_id":"sess-rs","transcript_path":"%s"}' "$1"; }
has() { case "$out" in *"$1"*) return 0 ;; esac; return 1; }
# the names listed under the block (two-space indented lines after the "Tools you had" line)
listed() { printf '%s\n' "$out" | awk '/^Tools you had loaded or used/ {on=1; next} on && /^  \(\+/ {next} on && /^  [A-Za-z]/ {sub(/^  /,""); print} on && /^====/ {on=0}'; }
SNAP="$SNAPDIR/pre-compact-20261107-100000.md"

echo "post-compact-resume-test:"

# --- 1. a fresh boundary is the source --------------------------------------------
printf '# Pre-compact snapshot\n\n- trigger: `manual`\n' > "$SNAP"
tx "$T/t1.jsonl" "use mcp__old__only_before" "boundary 5000 WebFetch" \
  "use mcp__example-server__lookup" "use Bash" "use mcp__example-other__read" \
  "boundary 3 WebFetch,mcp__example-other__read,mcp__never__called,mcp__example-server__lookup"
run_hook "$(compact_payload "$T/t1.jsonl")"
{ [ "$rc" -eq 0 ] && has "DEFERRED TOOL SCHEMAS DID NOT SURVIVE THIS COMPACTION" && has "Claude Code's own record of the tools it had discovered"; } \
  && ok "a fresh boundary: the block prints, sourced from Claude Code's own discovered-tools record" || bad "fresh boundary block: rc=$rc" "$out"
got="$(listed | tr '\n' ' ')"
[ "$got" = "mcp__example-other__read mcp__example-server__lookup WebFetch mcp__never__called " ] \
  && ok "most recently used first (other read, then server lookup), then the rest in the recorded order (WebFetch, never-called)" || bad "ordering: '$got'"
{ has 'select:<exact name>' && has 'never type it from memory' && has 'lazily' && has 'far more often'; } \
  && ok "the block says to select lazily, one name before its first call, copying names, and why" || bad "instruction text missing" "$out"
has 'Pre-compact snapshot' && ok "the snapshot still prints, above the block" || bad "snapshot missing"
[ "$(printf '%s\n' "$out" | grep -n 'DEFERRED TOOL SCHEMAS' | head -1 | cut -d: -f1)" -gt "$(printf '%s\n' "$out" | grep -n 'Pre-compact snapshot' | head -1 | cut -d: -f1)" ] \
  && ok "the block prints after the snapshot, closest to the next turn" || bad "block precedes the snapshot"

# --- 2. a stale boundary is not this compaction: the snapshot's section is the source
printf '# Pre-compact snapshot\n\n## Deferred tools used before this compaction\n\nTheir schemas do not survive.\n\n- mcp__from__snapshot_one\n- mcp__from__snapshot_two\n\n## Post-compact reading order\n\n1. here\n' > "$SNAP"
tx "$T/t2.jsonl" "use mcp__transcript__ignored" "boundary 4000 mcp__stale__listed"
run_hook "$(compact_payload "$T/t2.jsonl")"
got="$(listed | tr '\n' ' ')"
{ [ "$got" = "mcp__from__snapshot_one mcp__from__snapshot_two " ] && has 'the pre-compact snapshot'; } \
  && ok "a stale boundary (4000 s old) is ignored; the snapshot's section is the source" || bad "stale boundary: '$got'" "$out"
[ "$(printf '%s' "$out" | grep -c 'mcp__from__snapshot_one')" = 1 ] && ok "the snapshot prints without its Deferred tools section, so no name is listed twice" || bad "snapshot names listed more than once"
has '## Post-compact reading order' && ok "the rest of the snapshot is intact after the section is dropped" || bad "snapshot truncated"
case "$out" in *"Their schemas do not survive."*) bad "the dropped section's body leaked" ;; *) ok "the dropped section's body is gone too" ;; esac

# Two compactions can happen within five minutes. Calls after the newest visible
# boundary prove it is the previous one, so the new snapshot must win.
tx "$T/rapid.jsonl" "boundary 3 mcp__earlier__compaction" "use mcp__new__called"
run_hook "$(compact_payload "$T/rapid.jsonl")"
got="$(listed | tr '\n' ' ')"
{ [ "$got" = "mcp__from__snapshot_one mcp__from__snapshot_two " ] && has 'the pre-compact snapshot'; } \
  && ok "a recent earlier boundary cannot override the new snapshot after subsequent tool calls" || bad "rapid compaction: '$got'" "$out"

# --- 3. no boundary record and no snapshot section: the transcript's own calls ----
printf '# Pre-compact snapshot\n\n- trigger: `auto`\n' > "$SNAP"
tx "$T/t3.jsonl" "use mcp__before__earlier_compaction" "boundary 90000 -" "use mcp__a__first" "use Monitor" "use mcp__b__second" "usesc mcp__side__ignored"
run_hook "$(compact_payload "$T/t3.jsonl")"
got="$(listed | tr '\n' ' ')"
{ [ "$got" = "mcp__b__second Monitor mcp__a__first " ] && has 'the tool calls since the previous compaction'; } \
  && ok "falls back to the calls since the previous boundary: most recent first, a tool used only before it is not named" || bad "transcript fallback: '$got'" "$out"

# --- 4. nothing to name: no block --------------------------------------------------
tx "$T/t4.jsonl" "use Bash" "use Read" "boundary 3 -"
run_hook "$(compact_payload "$T/t4.jsonl")"
{ [ "$rc" -eq 0 ] && ! has "DEFERRED TOOL SCHEMAS" && has 'Pre-compact snapshot'; } && ok "no deferred tools anywhere: no block, snapshot as before" || bad "empty case printed a block" "$out"
run_hook "$(compact_payload "$T/missing.jsonl")"
{ [ "$rc" -eq 0 ] && ! has "DEFERRED TOOL SCHEMAS"; } && ok "a transcript that does not exist: no block, exit 0" || bad "missing transcript" "$out"
run_hook '{"source":"compact","session_id":"sess-rs"}'
{ [ "$rc" -eq 0 ] && ! has "DEFERRED TOOL SCHEMAS"; } && ok "a payload with no transcript_path: no block, exit 0" || bad "no transcript_path" "$out"

# --- 5. no snapshot at all: the block still prints ---------------------------------
rm -f "$SNAP"
run_hook "$(compact_payload "$T/t1.jsonl")"
{ has "No pre-compact snapshot found" && has "DEFERRED TOOL SCHEMAS DID NOT SURVIVE" && has "mcp__never__called"; } \
  && ok "with no snapshot the no-snapshot notice prints and the block follows it" || bad "no-snapshot case" "$out"
printf '# Pre-compact snapshot\n' > "$SNAP"

# --- 6. the cap, name hygiene, garbage lines --------------------------------------
names="$(python3 -I -c 'print(",".join("mcp__bulk__tool_%02d" % i for i in range(45)))')"
tx "$T/t6.jsonl" "boundary 2 $names"
run_hook "$(compact_payload "$T/t6.jsonl")"
{ [ "$(listed | wc -l | tr -d ' ')" = 40 ] && has '(+5 more were loaded'; } && ok "45 discovered tools: 40 listed and '(+5 more were loaded'" || bad "cap: $(listed | wc -l) listed" "$out"
tx "$T/t7.jsonl" "raw not json at all" "raw {broken" "use mcp__good__one" "boundary 2 mcp__good__one,bad name;rm -rf,../etc/passwd,mcp__good__two" "raw {\"type\":\"assistant\",\"message\":{\"content\":\"oops\"}}"
run_hook "$(compact_payload "$T/t7.jsonl")"
got="$(listed | tr '\n' ' ')"
{ [ "$rc" -eq 0 ] && [ "$got" = "mcp__good__one mcp__good__two " ]; } && ok "garbage lines are skipped and names that are not tool-name shaped are dropped" || bad "hygiene: rc=$rc got='$got'" "$out"
tx "$T/malformed.jsonl" \
  'raw ["deferred_tools_delta"]' \
  'raw {"attachment":{"type":"deferred_tools_delta","removedNames":[{}]}}' \
  'raw {"type":"assistant","message":[]}' \
  'raw {"type":"assistant","message":{"content":[{"type":"tool_use","name":"mcp__valid__after_bad_records","input":{"compact_boundary":true}}]}}'
out="$(python3 -I "$HELPER" used "$T/malformed.jsonl")"
[ "$out" = mcp__valid__after_bad_records ] && ok "malformed records and boundary-like tool inputs do not suppress later valid calls" || bad "malformed record scan: '$out'"

# --- 7. when it must not print ----------------------------------------------------
run_hook "{\"source\":\"startup\",\"session_id\":\"s\",\"transcript_path\":\"$T/t1.jsonl\"}"
[ -z "$out" ] && ok "source=startup: nothing printed" || bad "startup printed" "$out"

# --- 8. fails open ------------------------------------------------------------------
printf '# Pre-compact snapshot\n\n## Deferred tools used before this compaction\n\n- mcp__persisted__fallback\n\n## Post-compact reading order\n\n1. here\n' > "$SNAP"
mkdir -p "$T/nopy"; ln -s "$(command -v jq)" "$T/nopy/jq"; for t in cat date head tail ls pwd sed tr cut awk grep dirname basename; do ln -s "$(command -v $t)" "$T/nopy/$t" 2>/dev/null; done
out="$(cd "$T/work" && printf '%s' "$(compact_payload "$T/t1.jsonl")" | env HOME="$T/home" CLAUDE_CONFIG_DIR="$T/cfg" \
    POST_COMPACT_RESUME_DEBUG_LOG="$T/debug.log" PATH="$T/nopy" "$(command -v bash)" "$HOOK" 2>/dev/null)"; rc=$?
{ [ "$rc" -eq 0 ] && ! has "DEFERRED TOOL SCHEMAS" && has '## Deferred tools used before this compaction' && has mcp__persisted__fallback; } \
  && ok "no python on PATH: exit 0, no block, the snapshot retains its persisted names" || bad "no python: rc=$rc" "$out"

# --- 9. the helper on its own --------------------------------------------------------
out="$(python3 -I "$HELPER" used "$T/t3.jsonl")"
[ "$out" = "$(printf 'mcp__b__second\nMonitor\nmcp__a__first')" ] && ok "helper 'used' prints the calls since the last boundary, most recent first, names only" || bad "helper used: '$out'"
out="$(python3 -I "$HELPER" used "$T/missing.jsonl"; python3 -I "$HELPER" bogus x; python3 -I "$HELPER")"
[ -z "$out" ] && ok "helper with a missing file, a bad mode or no arguments prints nothing" || bad "helper junk input" "$out"
python3 -I "$HELPER" resume "$T/t1.jsonl" >/dev/null 2>&1; [ $? -eq 0 ] && ok "helper always exits 0" || bad "helper exit code"

echo "post-compact-resume-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
