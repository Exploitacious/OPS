#!/usr/bin/env bash
# grabit-test.sh: grabit's serve mode touches only its own serve path.
#
# What must hold, because a box that serves T3 Code (or anything else) over the
# tailnet lost that endpoint, its phone app included, when `grabit --serve-off`
# ran `tailscale serve reset`, which wipes every serve handler on the box:
#   - --serve and --serve-off never invoke `tailscale serve reset`, and no code
#     line of grabit names it
#   - --serve serves under grabit's own path, never the root, so it cannot
#     replace another handler at "/", and prints URLs under that path
#   - --serve-off removes only that path, and removes the staging directory
#   - a refused --serve-off says so (WARN) instead of printing success
#   - the default push still Taildrops the named file to the named device
# `tailscale` and `sudo` are recording stubs on PATH; nothing reaches a real
# tailnet. GRABIT_UNDER_TEST points the suite at another copy (to show it fail
# on the old one).
# grabit clears an environment-selected directory with rm -rf. Keep mutations
# inside the sandbox, and let the rm stub reach only this suite's staging dir.
# Verdict chains intentionally count a failed condition through bad().
# shellcheck disable=SC2015
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/../sandbox-guard.sh" && sandbox_guard || exit 97
set -uo pipefail
TOOL="${GRABIT_UNDER_TEST:-$(cd "$(dirname "$0")/.." && pwd)/grabit}"
T="$(mktemp -d "${TMPDIR:-/tmp}/grabit-test.XXXXXX")" || exit 1
trap '/bin/rm -rf -- "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $*"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

mkdir -p "$T/bin" "$T/home"
printf 'keep\n' > "$T/home/sibling.txt"
LOG="$T/tailscale.log"
# tailscale stub: one line per call, the arguments joined by single spaces.
cat > "$T/bin/tailscale" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GRABIT_TEST_LOG"
case "$1 ${2:-}" in
  "status --json") printf '{"Self":{"DNSName":"box.example.invalid."}}\n' ;;
  "status "*)      printf '192.0.2.10  laptop  user@  linux  active; direct\n' ;;
  "serve "*)
    [ -z "${GRABIT_TEST_SERVE_FAIL:-}" ] || exit 1
    shift
    mount=/; target=
    for arg in "$@"; do
      case "$arg" in
        --set-path=*) mount="${arg#--set-path=}" ;;
        --*) ;;
        *) target="$arg" ;;
      esac
    done
    if [ "$target" = off ]; then
      [ "$(cat "$GRABIT_TEST_MOUNT" 2>/dev/null)" = "$mount" ] || exit 1
      : > "$GRABIT_TEST_MOUNT"
    else
      # Tailscale adds a trailing slash to directory mounts, but looks up the
      # exact mount on removal. A recording-only stub missed that mismatch.
      [ ! -d "$target" ] || mount="${mount%/}/"
      printf '%s\n' "$mount" > "$GRABIT_TEST_MOUNT"
    fi
    ;;
esac
exit 0
SH
# sudo stub: run the command as is (the stub tailscale records it).
printf '#!/usr/bin/env bash\nexec "$@"\n' > "$T/bin/sudo"
cat > "$T/bin/rm" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GRABIT_TEST_REMOVE_LOG"
if [ "$#" -ne 2 ] || [ "$1" != -rf ] || [ "$2" != "$GRABIT_TEST_STAGE" ]; then
  printf 'grabit-test: refused removal outside the staging fixture: %s\n' "$*" >&2
  exit 1
fi
exec /bin/rm -rf -- "$GRABIT_TEST_STAGE"
SH
chmod +x "$T/bin/tailscale" "$T/bin/sudo" "$T/bin/rm"
export PATH="$T/bin:$PATH" HOME="$T/home" GRABIT_TEST_LOG="$LOG"
export GRABIT_SERVE_DIR="$T/home/serve"
export GRABIT_TEST_STAGE="$GRABIT_SERVE_DIR" GRABIT_TEST_REMOVE_LOG="$T/remove.log"
export GRABIT_TEST_MOUNT="$T/mount"
unset SSH_CONNECTION GRABIT_TEST_SERVE_FAIL

no_reset() {  # $1 label: no recorded call was a serve reset
  if grep -qE '(^| )serve( .*)? reset( |$)' "$LOG" 2>/dev/null; then
    bad "$1: tailscale serve reset was invoked: $(grep -E 'serve.*reset' "$LOG")"
  else
    ok "$1: no tailscale serve reset"
  fi
}

# --- static: no code line of grabit invokes serve reset -----------------------
if grep -vE '^[[:space:]]*#' "$TOOL" | grep -qE 'serve[[:space:]]+reset'; then
  bad "static: a code line of grabit names 'serve reset': $(grep -nvE '^[[:space:]]*#' "$TOOL" | grep -E 'serve[[:space:]]+reset')"
else
  ok "static: no code line of grabit names 'serve reset'"
fi

# --- --serve: own path, never the root ----------------------------------------
printf 'report\n' > "$T/report.txt"
: > "$LOG"
out="$(bash "$TOOL" --serve "$T/report.txt" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "serve: exit 0" || bad "serve: exit $rc: $out"
grep -qxF "serve --bg --https=443 --set-path=/grabit/ $GRABIT_SERVE_DIR" "$LOG" \
  && ok "serve: serves the staging dir under /grabit/ on 443" \
  || bad "serve: expected 'serve --bg --https=443 --set-path=/grabit/ <dir>', got: $(grep '^serve' "$LOG")"
grep -E '^serve' "$LOG" | grep -vq -- '--set-path=/grabit/' \
  && bad "serve: a serve call without grabit's directory mount: $(grep '^serve' "$LOG")" \
  || ok "serve: every serve call names grabit's path"
printf '%s\n' "$out" | grep -qF 'https://box.example.invalid/grabit/report.txt' \
  && ok "serve: prints the URL under /grabit" || bad "serve: URL not under /grabit: $out"
[ -f "$GRABIT_SERVE_DIR/report.txt" ] && ok "serve: staged only the named file" || bad "serve: file not staged"
[ "$(cat "$GRABIT_TEST_MOUNT")" = /grabit/ ] \
  && ok "serve: the directory mount ends in a slash" || bad "serve: unexpected directory mount"
no_reset "serve"

# --- --serve-off: removes only grabit's path ----------------------------------
: > "$LOG"
out="$(bash "$TOOL" --serve-off 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "serve-off: exit 0" || bad "serve-off: exit $rc: $out"
grep -qxF "serve --https=443 --set-path=/grabit/ off" "$LOG" \
  && ok "serve-off: turns off /grabit/ only" \
  || bad "serve-off: expected 'serve --https=443 --set-path=/grabit/ off', got: $(cat "$LOG")"
[ "$(grep -c '^serve' "$LOG")" -eq 1 ] && ok "serve-off: exactly one serve call" \
  || bad "serve-off: unexpected serve calls: $(grep '^serve' "$LOG")"
[ ! -e "$GRABIT_SERVE_DIR" ] && ok "serve-off: staging dir removed" || bad "serve-off: staging dir left behind"
[ ! -s "$GRABIT_TEST_MOUNT" ] && ok "serve-off: the directory mount was removed" \
  || bad "serve-off: the directory mount is still configured"
no_reset "serve-off"

# --- --serve-off refused: a warning, never a success line ----------------------
: > "$LOG"
out="$(GRABIT_TEST_SERVE_FAIL=1 bash "$TOOL" --serve-off 2>&1)"; rc=$?
printf '%s\n' "$out" | grep -q 'WARN' && ok "serve-off refused: prints WARN" || bad "serve-off refused: no WARN: $out"
printf '%s\n' "$out" | grep -q 'removed\.' && bad "serve-off refused: printed success: $out" || ok "serve-off refused: no success line"
no_reset "serve-off refused"

# --- push still works -----------------------------------------------------------
: > "$LOG"
out="$(bash "$TOOL" --to laptop "$T/report.txt" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && grep -qxF "file cp $T/report.txt laptop:" "$LOG" \
  && ok "push: Taildrops the named file to the named device" || bad "push: rc=$rc log=$(cat "$LOG") out=$out"
no_reset "push"

[ "$(grep -cxF -- "-rf $GRABIT_TEST_STAGE" "$GRABIT_TEST_REMOVE_LOG")" -eq 3 ] \
  && [ "$(wc -l < "$GRABIT_TEST_REMOVE_LOG")" -eq 3 ] \
  && ok "cleanup: only the three staging-directory removals were attempted" \
  || bad "cleanup: unexpected removals: $(cat "$GRABIT_TEST_REMOVE_LOG")"
[ "$(cat "$T/home/sibling.txt" 2>/dev/null)" = keep ] \
  && ok "cleanup: the sibling file survived" || bad "cleanup: the sibling file changed or disappeared"

echo; echo "grabit-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
