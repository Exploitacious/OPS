#!/usr/bin/env bash
# memory-digest-test.sh: behavior tests for `memory-index --digest` and
# `--digest-fit`, the memory digest a SessionStart hook can print so that a copy
# which runs with Claude Code's native auto-memory off still loads its pools.
#
# Why pin it: a copy that registers a digest hook has nothing else loading a
# pool. A defect here either strips every session of its memory or floods every
# boot, and Claude Code shows the model only a 2,000-character preview of a hook
# output past 10,000 characters. Cases:
#   - the 9,000-character cap holds on oversized pools and on text outside the
#     BMP (counted in UTF-16 units, the way Claude Code counts), and the budget
#     line carries counts that match what was printed;
#   - the root pool's cross-project section appears from a project cwd, a
#     project subdirectory and a project worktree, and never from the OPS cwd or
#     an OPS worktree (no second copy of the root);
#   - a cwd with no pool gets the header and the routing rule and nothing is
#     created; an unreadable pool prints one notice line, never a partial block;
#   - the tiers: pinned entries (metadata.pinned: true) print first with their
#     descriptions however old, capped at 20 across both pools; then user, then
#     feedback entries; then the rest, this directory's pool first; newest
#     modified (else file mtime) first within a tier;
#   - the per-machine memory-host file keys the pool, and a bad one is refused
#     with a notice naming the file, never another key's pool;
#   - the digest writes nothing.
#
# Every path is under a temp dir (HOME, OPS_DIR, CLAUDE_CONFIG_DIR); live pools
# are never read.
#
# Usage: memory-digest-test.sh    (exit 0 all pass, 1 otherwise)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
IDX="$HERE/../memory-index"
[ -f "$IDX" ] || { echo "FAIL: $IDX missing"; exit 1; }
command -v git >/dev/null || { echo "FAIL: git required"; exit 1; }
command -v python3 >/dev/null || { echo "FAIL: python3 required"; exit 1; }

T="$(mktemp -d)"; trap 'chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1"; [ $# -gt 1 ] && printf '    %s\n' "$2"; }

echo "memory-digest-test:"
key() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }
gitq() { git -c user.email=t@example.invalid -c user.name=t -c init.defaultBranch=main "$@" >/dev/null 2>&1; }

# --- fixture: an OPS checkout, a project repo, their pools ---------------------
OPS="$T/ops"; PROJ="$T/billing"; CFG="$T/cfg"; HOST=testhost
mkdir -p "$T/home" "$CFG/projects" "$OPS/.claude-memory" "$PROJ/sub" "$T/scratch"
gitq init "$OPS"; gitq -C "$OPS" commit --allow-empty -m init
gitq init "$PROJ"; gitq -C "$PROJ" commit --allow-empty -m init
gitq -C "$OPS" worktree add --detach "$T/ops-wt"
gitq -C "$PROJ" worktree add --detach "$T/billing-wt"
[ -d "$T/ops-wt" ] && [ -d "$T/billing-wt" ] || { echo "FAIL: fixture worktrees not created"; exit 1; }
ROOTP="$OPS/.claude-memory/$HOST$(key "$OPS")"
PROJP="$OPS/.claude-memory/$HOST$(key "$PROJ")"
mkdir -p "$ROOTP" "$PROJP"

entry() {  # entry <pool> <stem> <type> <description yaml> [modified [pinned]]
  { printf -- '---\nname: %s\ndescription: %s\nmetadata:\n  type: %s\n' "$2" "$4" "$3"
    [ -n "${5:-}" ] && printf '  modified: %s\n' "$5"
    [ -n "${6:-}" ] && printf '  pinned: %s\n' "$6"
    printf -- '---\nbody text\n'; } > "$1/$2.md"
}
entry "$ROOTP" user-operator-profile user "Who the operator is" 2026-01-01T00:00:00Z
entry "$ROOTP" root-gotcha-zsh feedback "zsh expands a leading equals sign" 2026-10-20T10:00:00Z
entry "$ROOTP" root-ref-hosts reference "Where the hosts live" 2026-10-19T10:00:00Z
entry "$ROOTP" project-root-workstream project "Workstream state of the OPS copy, root only" 2026-10-21T10:00:00Z
printf -- '- index line\n' > "$ROOTP/MEMORY.md"
entry "$PROJP" proj-newest feedback "Newest project gotcha" 2026-10-21T09:00:00Z
entry "$PROJP" proj-older project "Older project anchor" 2026-10-01T09:00:00Z
cat > "$PROJP/proj-colon-quotes.md" <<'EOF'
---
name: proj-colon-quotes
description: "Has: a colon and \"double quotes\" inside"
metadata:
  type: feedback
  modified: 2026-10-10T00:00:00Z
---
EOF
printf -- '- index line\n' > "$PROJP/MEMORY.md"

# dig <cwd> [env assignments...]: the digest for a directory, stdout only.
dig() {
  local cwd="$1"; shift
  env -u CLAUDE_PROJECT_DIR -u MEMORY_INDEX_DIR -u MEMORY_DIGEST_ROOT_DIR -u MEMORY_DIGEST_HOST \
    HOME="$T/home" OPS_DIR="$OPS" CLAUDE_CONFIG_DIR="$CFG" MEMORY_DIGEST_HOST="$HOST" "$@" \
    python3 -I "$IDX" --digest --cwd "$cwd" --ops "$OPS" 2>"$T/home/err" </dev/null
}
# A directory's own size is not state (tmpfs grows it with every entry), so only files carry one.
snapshot() { (cd "$T" && find . -path ./home/err -prune -o \( -type f -printf 'f %m %s %p\n' -o -type d -printf 'd %m %p\n' -o -type l -printf 'l %p\n' \) | sort | md5sum); }
u16() { python3 -c 'import sys; print(len(sys.stdin.buffer.read().decode("utf-8").rstrip("\n").encode("utf-16-le")) // 2)'; }

BEFORE="$(snapshot)"

# --- 1. a project digest: header, own pool, root cross-project entries -------------
out="$(dig "$PROJ")"
if grep -q "^OPS memory digest" <<< "$out" && grep -q "Pool for this directory: .*$(key "$PROJ")" <<< "$out" \
   && grep -q "OPS root pool, cross-project entries (3 of 4" <<< "$out" \
   && grep -q "^- \[root\] root-gotcha-zsh: zsh expands" <<< "$out" \
   && ! grep -q "project-root-workstream" <<< "$out"; then
  ok "a project cwd: its pool, then the root pool's cross-project entries ([root] marked, project type left out)"
else bad "project digest shape" "$out"; fi
grep -q "$OPS/.claude-config/bin/memory-index <pool dir>" <<< "$out" && ok "the Write line names the indexer, under the OPS checkout, to run after a write" || bad "Write line lacks the indexer path" "$out"

# --- 2. the root section from a subdirectory and a worktree; none from the OPS cwd --
for d in "$PROJ/sub" "$T/billing-wt"; do
  out="$(dig "$d")"
  grep -q "OPS root pool, cross-project entries" <<< "$out" && grep -q "proj-newest" <<< "$out" \
    && ok "the project's pool and the root section also come from ${d#"$T"/}" || bad "digest from ${d#"$T"/}" "$out"
done
for d in "$OPS" "$T/ops-wt"; do
  out="$(dig "$d")"
  if grep -q "project-root-workstream" <<< "$out" && ! grep -q "OPS root pool, cross-project entries" <<< "$out" && ! grep -q '\[root\]' <<< "$out"; then
    ok "from the OPS cwd (${d#"$T"/}) the root pool is this directory's own: workstream entries print, no second copy"
  else bad "OPS cwd digest" "$out"; fi
done

# --- 3. no pool: the header and the routing rule, and nothing is created -------------
out="$(dig "$T/scratch")"
if grep -q "No memory pool for this directory" <<< "$out" && grep -q "do not create one" <<< "$out" \
   && grep -q "CONTEXT/projects/<project>-lessons.md" <<< "$out"; then
  ok "a cwd with no pool gets the header and the routing rule"
else bad "no-pool digest" "$out"; fi
[ "$(snapshot)" = "$BEFORE" ] && ok "the digest writes nothing and creates no pool" || bad "the digest changed the tree"

# --- 4. the tiers, the pin cap and the order within a tier --------------------------
TP="$OPS/.claude-memory/$HOST$(key "$T/tiers")"; mkdir -p "$TP" "$T/tiers"
entry "$TP" zz-plain-newest reference "Plain, newest" 2026-10-30T00:00:00Z
entry "$TP" zz-plain-old reference "Plain, old" 2026-09-01T00:00:00Z
entry "$TP" yy-feedback feedback "A feedback entry" 2026-09-15T00:00:00Z
entry "$TP" xx-user user "A user entry" 2026-09-10T00:00:00Z
entry "$TP" aa-ancient-pin reference "An old ruling, pinned" 2025-01-01T00:00:00Z true
out="$(dig "$T/tiers")"
order="$(grep -oE '^- (\[root\] )?[a-z-]+' <<< "$out" | sed 's/^- //; s/\[root\] //' | grep -E '^(zz|yy|xx|aa)-' | tr '\n' ' ')"
[ "$order" = "aa-ancient-pin xx-user yy-feedback zz-plain-newest zz-plain-old " ] \
  && ok "tiers: pinned (however old) first, then user, then feedback, then the rest newest first" || bad "tier order" "got: $order"
grep -q "^- aa-ancient-pin: An old ruling, pinned" <<< "$out" && ok "a pinned entry prints with its description" || bad "pinned entry lost its description" "$out"
i=0; while [ "$i" -lt 21 ]; do entry "$TP" "pin-$(printf '%02d' "$i")" feedback "Pinned ruling $i" "2026-10-01T00:00:$(printf '%02d' "$i")Z" true; i=$((i+1)); done
out="$(dig "$T/tiers")"
described="$(grep -cE '^- pin-[0-9]{2}: Pinned ruling' <<< "$out")"
[ "$described" -eq 21 ] && ok "a 21st pin is demoted, never dropped: all 21 still print with descriptions" || bad "pins described: $described" "$out"
warn="$("$IDX" --check "$TP" 2>&1 >/dev/null)"
grep -q 'WARN: 22 pinned entries' <<< "$warn" && ok "--check warns that more than 20 pins demote the oldest" || bad "no pin warning" "$warn"

# --- 5. the budget: oversized pools stay under the cap, the footer counts match -------
BP="$OPS/.claude-memory/$HOST$(key "$T/big")"; mkdir -p "$BP" "$T/big"
python3 - "$BP" <<'PY'
import sys
d = sys.argv[1]
for i in range(300):
    open(f"{d}/reference-entry-{i:03d}-{'x' * 60}.md", "w").write(
        "---\nname: reference-entry-%03d-%s\ndescription: %s\nmetadata:\n  type: reference\n  modified: 2026-10-%02dT00:00:00Z\n---\nbody\n"
        % (i, "x" * 60, ("An ordinary long description for entry %d. " % i) * 6, 1 + i % 28))
PY
out="$(dig "$T/big")"; n="$(u16 <<< "$out")"
[ "$n" -le 9000 ] && ok "an oversized pool (300 entries) stays at or under 9,000 UTF-16 units ($n)" || bad "oversized digest is $n units"
foot="$(grep -E '^Over the 9,000-character digest budget' <<< "$out")"
by="$(sed -n 's/.*this pool \([0-9]*\) by name only, \([0-9]*\) not shown.*/\1 \2/p' <<< "$foot")"
desc="$(grep -cE '^- reference-entry-' <<< "$out")"
nm="$(sed -n 's/^- by name only (this pool):\(.*\)/\1/p' <<< "$out" | tr ',' '\n' | grep -c 'reference-entry-')"
nm2="$(awk '/^- by name only \(this pool\):/{f=1} f' <<< "$out" | grep -oE 'reference-entry-[0-9]{3}' | sort -u | wc -l)"
total=$(( desc + ${by% *} + ${by#* } ))
[ -n "$foot" ] && [ "$total" -eq 300 ] && [ "${by% *}" -eq "$nm2" ] \
  && ok "the budget line counts match what printed: $desc described + ${by% *} by name + ${by#* } not shown = 300" \
  || bad "footer counts" "foot=$foot desc=$desc named=$nm2 by=$by"
grep -q "memory-index --find" <<< "$out" && ok "the budget line names --find for an entry that was not shown" || bad "no --find pointer in the footer"
SP="$OPS/.claude-memory/$HOST$(key "$T/astral")"; mkdir -p "$SP" "$T/astral"
python3 - "$SP" <<'PY'
import sys
d = sys.argv[1]
for i in range(200):
    open(f"{d}/reference-astral-{i:03d}.md", "w").write(
        "---\nname: reference-astral-%03d\ndescription: %s\nmetadata:\n  type: reference\n---\n" % (i, "\U0001F9ED" * 150))
PY
out="$(dig "$T/astral")"; n="$(u16 <<< "$out")"
[ "$n" -le 9000 ] && ok "text outside the BMP counts as two units: the cap holds ($n)" || bad "astral digest is $n units"

# --- 6. an unreadable pool: one notice line, never a partial block -------------------
if [ "$(id -u)" -eq 0 ]; then
  echo "SKIP: unreadable pool (running as root, so chmod 000 does not deny the read)"
else
  UP="$OPS/.claude-memory/$HOST$(key "$T/locked")"; mkdir -p "$UP" "$T/locked"; entry "$UP" locked-entry feedback "x"
  chmod 000 "$UP"; out="$(dig "$T/locked")"; chmod 755 "$UP"
  [ "$(wc -l <<< "$out")" -eq 1 ] && grep -q "^OPS memory digest failed" <<< "$out" \
    && ok "an unreadable pool prints one failure notice that names where the indexes are" || bad "unreadable pool output" "$out"
fi

# --- 7. the per-machine memory-host file keys the pool -------------------------------
KP="$OPS/.claude-memory/sharedbox$(key "$T/shared")"; mkdir -p "$KP" "$T/shared" "$T/home/.config/ops"
entry "$KP" shared-fact feedback "Lives under the shared key"
printf 'SharedBox\n' > "$T/home/.config/ops/memory-host"
out="$(dig "$T/shared" MEMORY_DIGEST_HOST=)"
grep -q "shared-fact" <<< "$out" && ok "the memory-host file keys the pool (and an ASCII uppercase key is folded)" || bad "memory-host file not honored" "$out"
printf 'two words\n' > "$T/home/.config/ops/memory-host"
out="$(dig "$T/shared" MEMORY_DIGEST_HOST=)"
if grep -q "^OPS memory digest failed" <<< "$out" && grep -q "memory-host" <<< "$out" && ! grep -q "shared-fact" <<< "$out"; then
  ok "a bad memory-host file prints a notice naming the file, never another key's pool"
else bad "bad memory-host file handling" "$out"; fi
rm -f "$T/home/.config/ops/memory-host"

# --- 8. --digest-fit: one row per pool, an error row for a missing one ----------------
rows="$(python3 -I "$IDX" --digest-fit "$BP" "$T/nope" 2>/dev/null)"; rc=$?
if [ "$rc" -eq 1 ] && grep -qE "^$BP	300	[0-9]+	[0-9]+	[0-9]+$" <<< "$rows" && grep -q "^$T/nope	error	" <<< "$rows"; then
  ok "--digest-fit: a measured row per pool, an error row and exit 1 for a pool it could not measure"
else bad "--digest-fit" "rc=$rc rows=$rows"; fi

# --- 9. the SessionStart hook: prints only when native auto-memory is off ----------
# The hook follows the owner's auto-memory setting and never changes it: with the
# native load on, Claude Code reads MEMORY.md itself and a digest would repeat it.
HOOK="$HERE/../../hooks/memory-digest.sh"
hk() {  # hk <settings json or -> [env assignments...] (payload on stdin)
  local s="$1"; shift
  rm -f "$CFG/settings.json"; [ "$s" = - ] || printf '%s' "$s" > "$CFG/settings.json"
  env -u CLAUDE_PROJECT_DIR -u MEMORY_INDEX_DIR -u MEMORY_DIGEST_ROOT_DIR -u MEMORY_DIGEST \
    -u CLAUDE_CODE_DISABLE_AUTO_MEMORY \
    HOME="$T/home" OPS_DIR="$OPS" CLAUDE_CONFIG_DIR="$CFG" MEMORY_DIGEST_HOST="$HOST" "$@" bash "$HOOK" 2>"$T/home/err"
}
if [ ! -x "$HOOK" ]; then bad "hooks/memory-digest.sh missing or not executable"
else
  HB="$(snapshot)"
  out="$(hk '{"autoMemoryEnabled": false}' CLAUDE_PROJECT_DIR="$PROJ" </dev/null)"; rc=$?
  if [ "$rc" -eq 0 ] && grep -q "^OPS memory digest" <<< "$out" && grep -q "proj-newest" <<< "$out" \
     && grep -q "root-gotcha-zsh" <<< "$out"; then
    ok "hook: autoMemoryEnabled false -> prints this project's digest with the root section"
  else bad "hook with native auto-memory off" "rc=$rc out=$out"; fi
  for s in '{"autoMemoryEnabled": true}' '{}' -; do
    out="$(hk "$s" CLAUDE_PROJECT_DIR="$PROJ" </dev/null)"; rc=$?
    [ "$rc" -eq 0 ] && [ -z "$out" ] && ok "hook: native auto-memory on (settings ${s:0:28}) -> silent" \
      || bad "hook printed with native auto-memory on (settings $s)" "rc=$rc out=$out"
  done
  out="$(hk '{}' CLAUDE_PROJECT_DIR="$PROJ" CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 </dev/null)"
  grep -q "proj-newest" <<< "$out" && ok "hook: CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 counts as off -> prints" \
    || bad "hook ignored CLAUDE_CODE_DISABLE_AUTO_MEMORY" "$out"
  out="$(hk '{"autoMemoryEnabled": false}' CLAUDE_PROJECT_DIR="$PROJ" MEMORY_DIGEST=0 </dev/null)"
  [ -z "$out" ] && ok "hook: MEMORY_DIGEST=0 -> silent even with auto-memory off" || bad "MEMORY_DIGEST=0 ignored" "$out"
  out="$(hk '{"autoMemoryEnabled": true}' CLAUDE_PROJECT_DIR="$PROJ" MEMORY_DIGEST=1 </dev/null)"
  grep -q "proj-newest" <<< "$out" && ok "hook: MEMORY_DIGEST=1 -> prints even with auto-memory on" || bad "MEMORY_DIGEST=1 ignored" "$out"
  out="$(printf '{"hook_event_name":"SessionStart","source":"compact","cwd":"%s"}' "$PROJ/sub" \
    | hk '{"autoMemoryEnabled": false}')"
  grep -q "proj-newest" <<< "$out" && ok "hook: no CLAUDE_PROJECT_DIR -> the payload cwd picks the pool" \
    || bad "hook did not use the payload cwd" "$out"
  rm -f "$CFG/settings.json"   # the fixture's own file, absent when HB was taken
  [ "$(snapshot)" = "$HB" ] && ok "hook: writes nothing and creates no pool" || bad "the hook changed the tree"
  # A broken indexer: one notice line, never a partial block. The hook resolves
  # the indexer beside itself, so these run from a copy of the hooks dir.
  FK="$T/fake/.claude-config"; mkdir -p "$FK/hooks" "$FK/bin"
  cp "$HOOK" "$HERE/../../hooks/hooklib.sh" "$FK/hooks/"
  printf '#!/usr/bin/env python3\nimport sys\nprint("partial line")\nsys.exit(3)\n' > "$FK/bin/memory-index"
  rm -f "$CFG/settings.json"; printf '{"autoMemoryEnabled": false}' > "$CFG/settings.json"
  out="$(env -u CLAUDE_PROJECT_DIR HOME="$T/home" OPS_DIR="$OPS" CLAUDE_CONFIG_DIR="$CFG" bash "$FK/hooks/memory-digest.sh" </dev/null)"
  if [ "$(printf '%s\n' "$out" | wc -l)" -eq 1 ] && grep -q "^OPS memory digest failed (the indexer exited 3)" <<< "$out" \
     && ! grep -q "partial line" <<< "$out"; then
    ok "hook: a failing indexer prints one notice line, never its partial output"
  else bad "hook with a failing indexer" "$out"; fi
  rm -f "$FK/bin/memory-index"
  out="$(env -u CLAUDE_PROJECT_DIR HOME="$T/home" OPS_DIR="$OPS" CLAUDE_CONFIG_DIR="$CFG" bash "$FK/hooks/memory-digest.sh" </dev/null)"; rc=$?
  [ "$rc" -eq 0 ] && grep -q "^OPS memory digest failed (indexer missing" <<< "$out" \
    && ok "hook: no indexer -> a notice naming it, exit 0" || bad "hook with no indexer" "rc=$rc out=$out"
  rm -rf "${T:?}/fake" "$CFG/settings.json"
fi

echo
echo "memory-digest-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
