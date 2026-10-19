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
#   - a packet over --max-kb is exit 4; a bad base or an empty diff is exit 6
#   - --dry-run writes the packet and calls nothing
# Every repo and the reviewer itself are fixtures in this test's temp dir.
set -uo pipefail
TOOL="$(cd "$(dirname "$0")/.." && pwd)/second-vendor-review"
T="$(mktemp -d "${TMPDIR:-/tmp}/svr-test.XXXXXX")"; trap 'rm -rf "$T"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null TMPDIR="$T/tmp"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
mkdir -p "$TMPDIR"
PASS=0; FAIL=0
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

printf '#!/usr/bin/env bash\ncat >/dev/null; echo "partial" ; echo boom >&2; exit 7\n' > "$T/failing"; chmod +x "$T/failing"
out="$(cd "$R" && OPS_REVIEWER_CMD="$T/failing" "$TOOL" --base HEAD~1 --digest "$T/digest.md" --out "$T/fail.md" 2>&1)"; rc=$?
[ "$rc" = 5 ] && grep -q 'NO REVIEW: reviewer exited 7' "$T/fail.md" && ! grep -q '^partial$' "$T/fail.md" \
  && ok "failing reviewer: exit 5, NO REVIEW, its partial output not passed off as a review" || bad "failing reviewer: rc=$rc: $out"
printf '#!/usr/bin/env bash\ncat >/dev/null\n' > "$T/silent"; chmod +x "$T/silent"
out="$(cd "$R" && OPS_REVIEWER_CMD="$T/silent" "$TOOL" --base HEAD~1 --digest "$T/digest.md" --out "$T/silent.md" 2>&1)"; rc=$?
[ "$rc" = 5 ] && grep -q 'NO REVIEW: reviewer printed nothing' "$T/silent.md" && ok "silent reviewer: exit 5" || bad "silent reviewer: rc=$rc: $out"
printf '#!/usr/bin/env bash\ncat >/dev/null; sleep 30\n' > "$T/slow"; chmod +x "$T/slow"
out="$(cd "$R" && OPS_REVIEWER_CMD="$T/slow" "$TOOL" --base HEAD~1 --digest "$T/digest.md" --timeout 1 --out "$T/slow.md" 2>&1)"; rc=$?
[ "$rc" = 5 ] && grep -q 'timed out after 1s' "$T/slow.md" && ok "slow reviewer: exit 5 on the timeout" || bad "slow reviewer: rc=$rc: $out"

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
