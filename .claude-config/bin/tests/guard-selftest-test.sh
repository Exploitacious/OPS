#!/usr/bin/env bash
# guard-selftest-test.sh: hooks/guard-selftest.sh fails when a guard does.
#
# guard-selftest.sh is the canary run after the hooks are deployed (deploy.ps1
# acts on its exit code), so what must hold:
#   - against the real guards it passes: exit 0, no FAIL line
#   - when a guard reaches the wrong verdict, every FAIL line it prints is
#     counted: exit 1, and the summary names as many guards as there are FAIL
#     lines. Its rtk probes once read their JSON through a pipe, which ran the
#     probe in a subshell: the FAIL line printed, the count was lost, and the
#     selftest still exited 0 with ALL GUARDS ENFORCE (2026-10-19).
# The wrong verdict is a fixture: guard-selftest.sh runs from a copy of hooks/
# whose git-guard.sh calls the real one and inverts its verdict for each
# command in GST_FLIP. One command per probe site that read through the pipe:
# a blocked rtk form, an allowed rtk form, and the plain project push (a few
# heredoc probes send that command too; they are counted either way).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HOOKS="$(cd "$HERE/../../hooks" && pwd)"
BIN="$(cd "$HERE/.." && pwd)"
if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: guard-selftest-test (jq not installed; guard-selftest's rtk probes build their JSON with it)"
  exit 0
fi
T="$(mktemp -d "${TMPDIR:-/tmp}/guard-selftest-test.XXXXXX")"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $*"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

mkdir -p "$T/cfg/hooks" "$T/tmp"
for f in "$HOOKS"/*; do ln -s "$f" "$T/cfg/hooks/"; done
ln -s "$BIN" "$T/cfg/bin"
rm "$T/cfg/hooks/git-guard.sh"
cat > "$T/cfg/hooks/git-guard.sh" <<'STUB'
#!/usr/bin/env bash
# The real git-guard.sh, with its verdict inverted for each command in GST_FLIP.
IFS= read -r -d '' json
printf '%s' "$json" | "$GST_REAL" "$@"; rc=${PIPESTATUS[1]}
while IFS= read -r c; do
  [ -n "$c" ] && [[ "$json" == *"\"command\":\"$c\"}"* ]] || continue
  [ "$rc" = 0 ] && exit 2 || exit 0
done <<< "${GST_FLIP:-}"
exit "$rc"
STUB
chmod +x "$T/cfg/hooks/git-guard.sh"
export GST_REAL="$HOOKS/git-guard.sh" TMPDIR="$T/tmp"
run() { GST_FLIP="$1" bash "$T/cfg/hooks/guard-selftest.sh" > "$T/out" 2>&1; echo $?; }

rc="$(run "")"; nfail="$(grep -c '^  FAIL' "$T/out")"
[ "$rc" = 0 ] && [ "$nfail" = 0 ] && [ "$(tail -n 1 "$T/out")" = "guard-selftest: ALL GUARDS ENFORCE" ] \
  && ok "the fixture alone changes nothing: exit 0, no FAIL line" \
  || bad "fixture with nothing inverted: rc=$rc, $nfail FAIL line(s): $(grep '^  FAIL' "$T/out" | head -5; tail -n 1 "$T/out")"

rc="$(run $'rtk git push --force origin main\nrtk git status\ngit push origin main')"
nfail="$(grep -c '^  FAIL' "$T/out")"
[ "$rc" = 1 ] && [ "$nfail" -gt 0 ] && grep -q "^guard-selftest: $nfail guard(s) NOT enforcing" "$T/out" \
  && ok "every FAIL line is counted: exit 1, $nfail guard(s) named" \
  || bad "wrong verdicts: rc=$rc, $nfail FAIL line(s), last line: $(tail -n 1 "$T/out")"
for label in "git-guard blocks behind rtk: rtk git push --force origin main" \
             "git-guard allows behind rtk: rtk git status" \
             "git-guard allows a plain push from a project repo (fixture check)"; do
  grep -qF "  FAIL  $label (exit" "$T/out" && ok "reported: $label" || bad "no FAIL line for: $label"
done

echo "guard-selftest-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
