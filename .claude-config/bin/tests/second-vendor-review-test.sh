#!/usr/bin/env bash
# second-vendor-review-test.sh: the optional second-vendor reviewer hand-off.
#
# What must hold, because its output decides whether expensive-miss code ships:
#   - unconfigured (OPS_REVIEWER_CMD unset) it exits 3 and names the fallback,
#     before touching git: it is optional, never a silent no-op
#   - the packet carries the preamble, the digest, the diff stat and the diff,
#     with lock files and --exclude paths left out
#   - the reviewer command reads the packet on stdin, runs outside the repo
#     (an empty scratch dir), and its stdout lands in the result file
#   - a reviewer that fails, times out or prints nothing is exit 5 and a
#     result file that says NO REVIEW, never a review
#   - with no timeout command on PATH it exits 3 and never calls the reviewer
#     (unbounded, a hung reviewer blocked forever and a slow one was written up
#     as a review); gtimeout alone (Homebrew coreutils) enforces the cap
#   - a packet over --max-kb is exit 4; a bad base or an empty diff is exit 6
#   - --dry-run writes the packet and calls nothing
#   - packet/result files are private, default paths never collide, command
#     credentials stay out of metadata, and a digest read failure stops review
# Every repo and the reviewer itself are fixtures in this test's temp dir.
# Verdict chains intentionally count a failed condition or reporting function
# through bad(); they are not assignments that need if/else semantics.
# shellcheck disable=SC2015
set -uo pipefail
TOOL="$(cd "$(dirname "$0")/.." && pwd)/second-vendor-review"
T="$(mktemp -d "${TMPDIR:-/tmp}/svr-test.XXXXXX")"; trap 'rm -rf "$T"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null TMPDIR="$T/tmp"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
mkdir -p "$TMPDIR"
PASS=0; FAIL=0
# A host with no timeout command (stock macOS) gets a stand-in that runs the
# command unbounded (the tool passes -k 30 S), so the cases that do not test
# the cap still run there; the cases that need a real cap skip.
HOST_TO="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null)" || HOST_TO=""
if [ -z "$HOST_TO" ]; then
  mkdir -p "$T/shim"; printf '#!/bin/sh\nshift 3; exec "$@"\n' > "$T/shim/timeout"; chmod +x "$T/shim/timeout"
  export PATH="$T/shim:$PATH"
fi
ok()  { PASS=$((PASS+1)); echo "PASS: $*"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

R="$T/repo"; git init -q -b main "$R"
printf 'def add(a, b):\n    return a + b\n' > "$R/calc.py"; git -C "$R" add -A; git -C "$R" commit -q -m base
printf 'def add(a, b):\n    return a - b\n' > "$R/calc.py"
printf '{"lock": 1}\n' > "$R/package-lock.json"; mkdir -p "$R/fixtures"; printf 'BIGFIXTURE\n' > "$R/fixtures/data.txt"
git -C "$R" add -A; git -C "$R" commit -q -m change
printf 'Changes add(); decided: keep the name. Tests: none yet.\n' > "$T/digest.md"
cat > "$T/reviewer" <<STUB
#!/usr/bin/env bash
cat > "$T/seen-packet"; pwd > "$T/seen-cwd"
echo "1. calc.py:2 subtracts instead of adding."
STUB
chmod +x "$T/reviewer"

out="$(cd "$R" && env -u OPS_REVIEWER_CMD "$TOOL" --base HEAD~1 --digest "$T/digest.md" 2>&1)"; rc=$?
[ "$rc" = 3 ] && grep -q 'optional' <<<"$out" && grep -q 'Opus 5.5 refutation lane' <<<"$out" \
  && ok "unconfigured: exit 3, names the fallback" || bad "unconfigured: rc=$rc: $out"

out="$(cd "$R" && OPS_REVIEWER_CMD="$T/reviewer" "$TOOL" --base HEAD~1 --digest "$T/digest.md" --exclude fixtures --out "$T/res.md" 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -q 'subtracts instead of adding' "$T/res.md" && grep -q '^- status: ok$' "$T/res.md" \
  && ok "reviewed: exit 0, stdout in the result file" || bad "reviewed: rc=$rc: $out"
grep -q 'Changes add(); decided: keep the name' "$T/seen-packet" && grep -q 'return a - b' "$T/seen-packet" \
  && grep -q 'Review only: change nothing' "$T/seen-packet" && ok "packet: preamble, digest and diff reach the reviewer" \
  || bad "packet: $(head -c 400 "$T/seen-packet")"
! grep -q 'package-lock.json\|BIGFIXTURE' "$T/seen-packet" && ok "packet: lock file and --exclude path left out" \
  || bad "packet: carries an excluded path"
[ "$(cat "$T/seen-cwd")" != "$R" ] && case "$(cat "$T/seen-cwd")" in "$TMPDIR"/second-vendor-review.*) true ;; *) false ;; esac \
  && ok "reviewer ran in a scratch dir, not the repo" || bad "reviewer cwd: $(cat "$T/seen-cwd")"
grep -q "^- head: $(git -C "$R" rev-parse HEAD)$" "$T/res.md" && ok "result header names the head" || bad "header: $(head -8 "$T/res.md")"

# Shell commands often begin with a credential assignment. Recording even the
# first word leaks that credential into the durable review result.
out="$(cd "$R" && OPS_REVIEWER_CMD="SVR_TEST_SECRET=header-test-canary $T/reviewer" "$TOOL" --base HEAD~1 --digest "$T/digest.md" --out "$T/secret.md" 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -q 'subtracts instead of adding' "$T/secret.md" && ! grep -q 'header-test-canary' "$T/secret.md" \
  && ok "review header never records a credential assignment from the command" || bad "command metadata: rc=$rc (result must omit the command credential)"

# A public existing result must be replaced with private files, even under the
# usual umask. The packet has the whole diff and the Operator's digest in it.
printf 'old result\n' > "$T/private.md"; printf 'old packet\n' > "$T/private.md.packet.md"
chmod 644 "$T/private.md" "$T/private.md.packet.md"
out="$(umask 022; cd "$R" && OPS_REVIEWER_CMD="$T/reviewer" "$TOOL" --base HEAD~1 --digest "$T/digest.md" --out "$T/private.md" 2>&1)"; rc=$?
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }
[ "$rc" = 0 ] && [ "$(file_mode "$T/private.md")" = 600 ] && [ "$(file_mode "$T/private.md.packet.md")" = 600 ] \
  && ok "packet and result are private, including when replacing public files" || bad "output permissions: rc=$rc: $out"

# Pin the timestamp to reproduce simultaneous default invocations reliably.
mkdir -p "$T/stamp"
printf '#!/bin/sh\nprintf "20261019T000000Z\\n"\n' > "$T/stamp/date"; chmod +x "$T/stamp/date"
packets=()
for run in 1 2; do
  out="$(cd "$R" && PATH="$T/stamp:$PATH" "$TOOL" --base HEAD~1 --digest "$T/digest.md" --dry-run 2>&1)"; rc=$?
  packets+=("${out##*: }")
  [ "$rc" = 0 ] || bad "default packet $run: rc=$rc: $out"
done
[ "${packets[0]}" != "${packets[1]}" ] && [ -s "${packets[0]}" ] && [ -s "${packets[1]}" ] \
  && ok "default packet paths differ even with the same repo and timestamp" || bad "default packet paths collide or were not written"

# The digest can become unreadable after the initial file check. A later
# successful printf must not hide cat's error and send an incomplete packet.
mkdir -p "$T/failcat"; REAL_CAT="$(command -v cat)"
cat > "$T/failcat/cat" <<STUB
#!/bin/sh
if [ "\${1:-}" = "\$SVR_BROKEN_DIGEST" ]; then echo 'simulated digest read failure' >&2; exit 1; fi
exec "$REAL_CAT" "\$@"
STUB
chmod +x "$T/failcat/cat"; rm -f "$T/seen-packet"
out="$(cd "$R" && PATH="$T/failcat:$PATH" SVR_BROKEN_DIGEST="$T/digest.md" OPS_REVIEWER_CMD="$T/reviewer" "$TOOL" --base HEAD~1 --digest "$T/digest.md" --out "$T/digest-failed.md" 2>&1)"; rc=$?
[ "$rc" = 2 ] && grep -q 'cannot read the digest' <<< "$out" && [ ! -e "$T/seen-packet" ] && [ ! -e "$T/digest-failed.md" ] \
  && ok "digest read failure: no reviewer is run and no review is reported" || bad "digest read failure: rc=$rc: $out"

printf '#!/usr/bin/env bash\ncat >/dev/null; echo "partial" ; echo boom >&2; exit 7\n' > "$T/failing"; chmod +x "$T/failing"
out="$(cd "$R" && OPS_REVIEWER_CMD="$T/failing" "$TOOL" --base HEAD~1 --digest "$T/digest.md" --out "$T/fail.md" 2>&1)"; rc=$?
[ "$rc" = 5 ] && grep -q 'NO REVIEW: reviewer exited 7' "$T/fail.md" && ! grep -q '^partial$' "$T/fail.md" \
  && ok "failing reviewer: exit 5, NO REVIEW, its partial output not passed off as a review" || bad "failing reviewer: rc=$rc: $out"
printf '#!/usr/bin/env bash\ncat >/dev/null\n' > "$T/silent"; chmod +x "$T/silent"
out="$(cd "$R" && OPS_REVIEWER_CMD="$T/silent" "$TOOL" --base HEAD~1 --digest "$T/digest.md" --out "$T/silent.md" 2>&1)"; rc=$?
[ "$rc" = 5 ] && grep -q 'NO REVIEW: reviewer printed nothing' "$T/silent.md" && ok "silent reviewer: exit 5" || bad "silent reviewer: rc=$rc: $out"
if [ -n "$HOST_TO" ]; then
  printf '#!/usr/bin/env bash\ncat >/dev/null; sleep 30\n' > "$T/slow"; chmod +x "$T/slow"
  out="$(cd "$R" && OPS_REVIEWER_CMD="$T/slow" "$TOOL" --base HEAD~1 --digest "$T/digest.md" --timeout 1 --out "$T/slow.md" 2>&1)"; rc=$?
  [ "$rc" = 5 ] && grep -q 'timed out after 1s' "$T/slow.md" && ok "slow reviewer: exit 5 on the timeout" || bad "slow reviewer: rc=$rc: $out"
else
  echo "SKIP: slow reviewer timeout (no timeout command)"
fi

# A PATH with everything the tool and the stub reviewer run, but no timeout
# command. Before the fix the cap was skipped in silence there: this reviewer
# ran its full 5 s and was written up as a review (status ok, exit 0).
mkdir -p "$T/noto"
for tool in bash env git cat sed wc mktemp date dirname basename mkdir rm mv tail head sleep; do
  p="$(command -v "$tool")" && ln -s "$p" "$T/noto/$tool"
done
printf '#!/usr/bin/env bash\ncat >/dev/null; : > "%s/late-ran"; sleep 5; echo "late review"\n' "$T" > "$T/late"; chmod +x "$T/late"
start=$SECONDS
out="$(cd "$R" && PATH="$T/noto" OPS_REVIEWER_CMD="$T/late" "$TOOL" --base HEAD~1 --digest "$T/digest.md" --timeout 1 --out "$T/noto.md" 2>&1)"; rc=$?
[ "$rc" = 3 ] && grep -q 'no timeout command' <<<"$out" && grep -q 'Opus 5.5 refutation lane' <<<"$out" \
  && [ ! -e "$T/late-ran" ] && [ ! -e "$T/noto.md" ] \
  && ok "no timeout command: exit 3, the reviewer is never run unbounded" \
  || bad "no timeout command: rc=$rc after $((SECONDS - start)) s, reviewer ran: $([ -e "$T/late-ran" ] && echo yes || echo no): $out"
rm -f "$T/late-ran"
out="$(cd "$R" && PATH="$T/noto" OPS_REVIEWER_CMD="$T/late" "$TOOL" --base HEAD~1 --digest "$T/digest.md" --dry-run --out "$T/noto-dry.md" 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ -s "$T/noto-dry.md.packet.md" ] && [ ! -e "$T/late-ran" ] \
  && ok "no timeout command: --dry-run still writes the packet" || bad "no timeout command, dry run: rc=$rc: $out"
if [ -n "$HOST_TO" ]; then
  mkdir -p "$T/gto"; cp -P "$T/noto"/* "$T/gto/"
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$HOST_TO" > "$T/gto/gtimeout"; chmod +x "$T/gto/gtimeout"
  start=$SECONDS
  out="$(cd "$R" && PATH="$T/gto" OPS_REVIEWER_CMD="$T/late" "$TOOL" --base HEAD~1 --digest "$T/digest.md" --timeout 1 --out "$T/gto.md" 2>&1)"; rc=$?
  [ "$rc" = 5 ] && grep -q 'timed out after 1s' "$T/gto.md" && ! grep -q 'late review' "$T/gto.md" \
    && ok "gtimeout alone (Homebrew coreutils) enforces --timeout: exit 5" \
    || bad "gtimeout alone: rc=$rc after $((SECONDS - start)) s: $out"
else
  echo "SKIP: gtimeout enforces the cap (no timeout command)"
fi

head -c 300000 /dev/urandom | base64 > "$R/big.txt"; git -C "$R" add big.txt; git -C "$R" commit -q -m big
out="$(cd "$R" && OPS_REVIEWER_CMD="$T/reviewer" "$TOOL" --base HEAD~2 --digest "$T/digest.md" --out "$T/big.md" 2>&1)"; rc=$?
[ "$rc" = 4 ] && [ ! -e "$T/big.md" ] && ok "oversized packet: exit 4, reviewer not called" || bad "oversized: rc=$rc: $out"
out="$(cd "$R" && OPS_REVIEWER_CMD="$T/reviewer" "$TOOL" --base no-such-ref --digest "$T/digest.md" 2>&1)"; rc=$?
[ "$rc" = 6 ] && ok "bad base: exit 6" || bad "bad base: rc=$rc: $out"
out="$(cd "$R" && OPS_REVIEWER_CMD="$T/reviewer" "$TOOL" --base HEAD --digest "$T/digest.md" 2>&1)"; rc=$?
[ "$rc" = 6 ] && grep -q 'no reviewable changes' <<<"$out" && ok "empty diff: exit 6, never an empty review" || bad "empty diff: rc=$rc: $out"

rm -f "$T/seen-packet"
out="$(cd "$R" && env -u OPS_REVIEWER_CMD "$TOOL" --base HEAD~2 --digest "$T/digest.md" --exclude big.txt --dry-run --out "$T/dry.md" 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ -s "$T/dry.md.packet.md" ] && [ ! -e "$T/dry.md" ] && [ ! -e "$T/seen-packet" ] \
  && ok "dry run: packet written, nothing called, needs no OPS_REVIEWER_CMD" || bad "dry run: rc=$rc: $out"

echo "second-vendor-review-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
