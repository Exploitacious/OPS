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
# And the delta itself must be complete and installable:
#   3. An upstream rename reaches the copy (NEW new path, REMOVED old path);
#      git's default rename detection used to drop both.
#   4. --apply-safe sets each file's mode from the upstream tree entry, so a
#      template script lands executable and a dropped exec bit is cleared.
#   5. A marker whose last line has no trailing newline still yields delta mode.
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

# --- 5. rename + exec bits: a delta that git sees as a rename ---
# Base: a 40-line script (so the edited move still scores as a rename), a
# plain file that becomes executable upstream, and a script that stops being one.
g init -q "$T/up2"; mkdir -p "$T/up2/tools" "$T/up2/bin"
seq 1 40 | sed 's/^/echo line /' > "$T/up2/tools/old-name.sh"; chmod +x "$T/up2/tools/old-name.sh"
echo 'echo v1' > "$T/up2/bin/runme"; chmod -x "$T/up2/bin/runme"
echo 'echo v1' > "$T/up2/bin/wasexec"; chmod +x "$T/up2/bin/wasexec"
g -C "$T/up2" add -A; g -C "$T/up2" commit -qm base; BASE2="$(git -C "$T/up2" rev-parse HEAD)"
mkdir -p "$T/up2/lib"; g -C "$T/up2" mv tools/old-name.sh lib/new-name.sh
echo 'echo extra' >> "$T/up2/lib/new-name.sh"
echo 'echo v2' > "$T/up2/bin/runme"; chmod +x "$T/up2/bin/runme"
echo 'echo v2' > "$T/up2/bin/wasexec"; chmod -x "$T/up2/bin/wasexec"
echo 'echo tool' > "$T/up2/bin/newtool"; chmod +x "$T/up2/bin/newtool"
g -C "$T/up2" add -A; g -C "$T/up2" commit -qm move
g clone -q --bare "$T/up2" "$T/up2.git"
git -C "$T/up2" -c diff.renames=true diff --name-status "$BASE2..HEAD" | grep -q '^R' \
  && ok "rename fixture: git reports the move as a rename" || bad "rename fixture: no R line, the case is not exercised"

g clone -q "$T/up2" "$T/copy2"; g -C "$T/copy2" reset -q --hard "$BASE2"
g -C "$T/copy2" remote add ops-template "$T/up2.git"
mkdir -p "$T/copy2/.claude-config"
printf 'upstream=local/test\nlast_synced=%s\n' "$BASE2" > "$T/copy2/.claude-config/ops-upstream-ref"
out="$(cd "$T/copy2" && OPS_UPSTREAM=local/test bash "$SCAN_TMP" --apply-safe 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "rename: --apply-safe exit 0" || bad "rename: rc=$rc: $out"
grep -q -E '^NEW +lib/new-name.sh$' <<<"$out" && ok "rename: new path classed NEW" || bad "rename: lib/new-name.sh not NEW: $out"
grep -q -E '^REMOVED +tools/old-name.sh$' <<<"$out" && ok "rename: old path classed REMOVED" || bad "rename: tools/old-name.sh not REMOVED: $out"
[ -f "$T/copy2/lib/new-name.sh" ] && ok "rename: new path written" || bad "rename: lib/new-name.sh missing after --apply-safe"
[ -f "$T/copy2/tools/old-name.sh" ] && ok "rename: old path kept (never auto-deleted)" || bad "rename: tools/old-name.sh deleted"

# --- 6. exec bits come from the upstream tree entry ---
grep -q -E '^NEW +bin/newtool$' <<<"$out" && [ -x "$T/copy2/bin/newtool" ] \
  && ok "mode: NEW 100755 file lands executable" || bad "mode: bin/newtool not NEW+executable: $(ls -l "$T/copy2/bin/newtool" 2>&1)"
[ -x "$T/copy2/lib/new-name.sh" ] && ok "mode: renamed 100755 file lands executable" || bad "mode: lib/new-name.sh not executable"
grep -q -E '^UPDATE +bin/runme$' <<<"$out" && [ -x "$T/copy2/bin/runme" ] \
  && ok "mode: UPDATE to 100755 gains the exec bit" || bad "mode: bin/runme not UPDATE+executable: $(ls -l "$T/copy2/bin/runme" 2>&1)"
grep -q -E '^UPDATE +bin/wasexec$' <<<"$out" && [ ! -x "$T/copy2/bin/wasexec" ] && grep -q 'echo v2' "$T/copy2/bin/wasexec" \
  && ok "mode: UPDATE to 100644 drops the exec bit" || bad "mode: bin/wasexec not UPDATE+non-exec: $(ls -l "$T/copy2/bin/wasexec" 2>&1)"

# --- 7. marker with no trailing newline on its last line ---
g clone -q "$T/up2" "$T/copy3"; g -C "$T/copy3" reset -q --hard "$BASE2"
g -C "$T/copy3" remote add ops-template "$T/up2.git"
mkdir -p "$T/copy3/.claude-config"
printf 'upstream=local/test\nlast_synced=%s' "$BASE2" > "$T/copy3/.claude-config/ops-upstream-ref"
out="$(cd "$T/copy3" && OPS_UPSTREAM=local/test bash "$SCAN_TMP" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && grep -q "^# mode: delta since last_synced ${BASE2:0:12}" <<<"$out" \
  && ok "marker: last line without newline still read (delta mode)" || bad "marker: no-newline last_synced dropped: rc=$rc: $out"

echo; echo "harness-update-scan-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && echo "ALL PASS"
exit $(( FAIL > 0 ))
