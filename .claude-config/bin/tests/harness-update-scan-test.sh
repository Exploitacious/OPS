#!/usr/bin/env bash
# Behavior tests for .claude-config/bin/harness-update-scan.sh.
#
# Two contracts the template's own users depend on:
#   1. Self-contained: a copy that predates the scanner runs it straight from
#      the template (git show ops-template/main:<path> > tmp; bash tmp) inside
#      an old layout with no marker and no helper files. It must find its root
#      from the cwd, stay report-only, and write nothing.
#   2. History rewrite: a last_synced from before the 2026-10-19 rewrite is
#      translated to its rewritten twin (same tree), so the scan stays in delta
#      mode instead of a first-sync compare; an unknown sha still falls back.
# No network: the ops-template remote points at a local bare repo.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN_SRC="$HERE/../harness-update-scan.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "PASS: $*"; }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $*"; }
g(){ git -c user.name=t -c user.email=t@example.invalid -c init.defaultBranch=main "$@"; }

# Upstream template: two commits; the second changes a file and adds one.
g init -q "$T/up"
mkdir -p "$T/up/SKILLS/demo" "$T/up/.claude-config/bin"
echo v1 > "$T/up/SKILLS/demo/SKILL.md"; echo keep > "$T/up/README.md"
g -C "$T/up" add -A; g -C "$T/up" commit -qm one; OLD_TIP="$(git -C "$T/up" rev-parse HEAD)"
echo v2 > "$T/up/SKILLS/demo/SKILL.md"; echo new > "$T/up/NEWFILE.md"
g -C "$T/up" add -A; g -C "$T/up" commit -qm two
g clone -q --bare "$T/up" "$T/up.git"

# Run the scanner the way an old copy does: from a temp file, cwd = the copy.
SCAN_TMP="$T/scan.sh"; cp "$SCAN_SRC" "$SCAN_TMP"
run_scan(){ (cd "$1" && OPS_UPSTREAM=local/test bash "$SCAN_TMP" "${@:2}"); }

# --- 1. old layout, no marker, no .claude-config at all ---
g init -q "$T/old"; echo keep > "$T/old/README.md"; echo mine > "$T/old/NOTES.md"
g -C "$T/old" add -A; g -C "$T/old" commit -qm mine
g -C "$T/old" remote add ops-template "$T/up.git"
before="$(cd "$T/old" && git status --porcelain; find . -path ./.git -prune -o -type f -print | sort)"
out="$(run_scan "$T/old" 2>&1)"; rc=$?
after="$(cd "$T/old" && git status --porcelain; find . -path ./.git -prune -o -type f -print | sort)"
[ "$rc" -eq 0 ] && ok "old layout: exit 0" || bad "old layout: rc=$rc: $out"
grep -q '^# mode: first-sync' <<<"$out" && ok "old layout: first-sync mode" || bad "old layout: mode line missing: $out"
grep -q 'NEWFILE.md' <<<"$out" && ok "old layout: reports upstream files" || bad "old layout: NEWFILE.md not reported"
[ "$before" = "$after" ] && ok "old layout: report-only, nothing written" || bad "old layout: the tree changed"
[ ! -e "$T/old/.claude-config/ops-upstream-ref" ] && ok "old layout: no marker written" || bad "old layout: marker created"
if grep -n -E '^[[:space:]]*(source|\.)[[:space:]]' "$SCAN_SRC" | grep -v -E '^\s*#' >/dev/null; then
  bad "self-contained: the scanner sources a file"
else ok "self-contained: the scanner sources no file"; fi

# --- 2. marker from before a rewrite: translated to its twin, delta mode ---
g clone -q "$T/up" "$T/copy"; g -C "$T/copy" reset -q --hard "$OLD_TIP"
g -C "$T/copy" remote add ops-template "$T/up.git"
mkdir -p "$T/copy/.claude-config"
FAKE_OLD="1111111111111111111111111111111111111111"
printf 'upstream=local/test\nlast_synced=%s\n' "$FAKE_OLD" > "$T/copy/.claude-config/ops-upstream-ref"
out="$(cd "$T/copy" && OPS_UPSTREAM=local/test OPS_REWRITE_MAP="$FAKE_OLD $OLD_TIP" bash "$SCAN_TMP" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "rewrite: exit 0" || bad "rewrite: rc=$rc: $out"
grep -q 'predates the 2026-10-19 history rewrite' <<<"$out" && ok "rewrite: twin translation announced" || bad "rewrite: no translation note: $out"
grep -q '^# mode: delta since last_synced' <<<"$out" && ok "rewrite: delta mode kept" || bad "rewrite: not delta: $out"
grep -q -E 'UPDATE +SKILLS/demo/SKILL.md' <<<"$out" && ok "rewrite: untouched local file classed UPDATE" || bad "rewrite: SKILL.md not UPDATE: $out"
grep -q "last_synced=$FAKE_OLD" "$T/copy/.claude-config/ops-upstream-ref" && ok "rewrite: marker left for the skill to update" || bad "rewrite: marker rewritten by the scan"

# --- 3. a sha that is neither known nor mapped: warn and fall back ---
printf 'upstream=local/test\nlast_synced=%s\n' "2222222222222222222222222222222222222222" > "$T/copy/.claude-config/ops-upstream-ref"
out="$(cd "$T/copy" && OPS_UPSTREAM=local/test bash "$SCAN_TMP" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'is not a known commit; falling back to first-sync' <<<"$out" && grep -q '^# mode: first-sync' <<<"$out" \
  && ok "unknown sha: warns and falls back to first-sync" || bad "unknown sha: rc=$rc: $out"

# --- 4. the embedded table maps a real pre-rewrite sha ---
grep -q 'a4b7f2ec8657aaa734007d56c09b1b5baa57b441 ce6bbbab6a1ca2478d39eb46f87744041cd1ef47' "$SCAN_SRC" \
  && ok "table: carries the 2026-10-19 pairs" || bad "table: a known pair is missing"

echo; echo "harness-update-scan-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && echo "ALL PASS"
exit $(( FAIL > 0 ))
