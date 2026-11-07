#!/usr/bin/env bash
# secrets-guard-test.sh: behavior tests for hooks/secrets-guard.sh, the pre scan
# that blocks a literal credential written into a memory pool or lessons file,
# and the post routing nudge.
#
# Why pin it: the pre scan used to copy the candidate content to a mktemp file
# with an unchecked printf. When the temp filesystem was full it scanned an
# empty file and allowed the write; a failed mktemp, a missing scanner, a
# missing JSON parser and a grep that could not run all passed the write the
# same way. The guard now pipes the content to the scanner (no temp file), and
# anything but a clean scan blocks. Cases:
#   - pre: a credential in a guarded path blocks (exit 2, the credential
#     message); clean content and an unguarded path pass; SECRETS_GUARD=off
#     passes;
#   - pre, temp space broken (TMPDIR a missing dir or an unwritable one, and
#     every file write failing with EFBIG, the disk-full case): the verdict is
#     the scan's, not the disk's;
#   - pre, a scanner that fails (exit 69, killed, stops reading early), is
#     missing, or whose grep cannot run blocks with a message that says the
#     content could not be scanned; a scanner exiting 0 passes and one exiting
#     1 shows its hits;
#   - pre, a payload the guard cannot read (no JSON parser, malformed JSON, no
#     file_path, a content field that cannot be extracted, an input read that
#     fails) blocks; post only notes it; empty content (a Write with nothing,
#     an Edit to an empty new_string) is no failure and passes;
#   - post: the memory-routing nudge still fires (exit 2, queue line written)
#     for a substantive type project entry; with no usable temp space it is
#     skipped, exit 0, with a stderr note, and never blocks;
#   - the guarded-path test runs before the content is read: an unguarded path
#     never reaches the scanner.
#
# Every path is under a temp dir (HOME, TMPDIR, the queue dir); no live pool or
# lessons file is read. HOOK_UNDER_TEST swaps the hook (the scanner is the one
# beside it, in ../bin/secrets-scan.sh).
#
# Usage: secrets-guard-test.sh    (exit 0 all pass, 1 otherwise)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
HOOK="${HOOK_UNDER_TEST:-$HERE/../../hooks/secrets-guard.sh}"
[ -f "$HOOK" ] || { echo "FAIL: $HOOK missing"; exit 1; }
command -v python3 >/dev/null || { echo "FAIL: python3 required (it builds the JSON payloads)"; exit 1; }

T="$(mktemp -d)"; trap 'chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1"; [ $# -gt 1 ] && printf '    %s\n' "$2"; }
echo "secrets-guard-test:"

H="$T/home"; mkdir -p "$H/OPS/CONTEXT/projects" "$H/OPS/.claude-memory/pool"
printf 'lessons for the exampleproj project\n' > "$H/OPS/CONTEXT/projects/exampleproj-lessons.md"
POOLFILE="$H/OPS/.claude-memory/pool/note.md"
QUEUE="$H/.claude-compact-cycle/memory-flush-queue"
# A fake literal credential, built from parts so this file never holds one.
CRED="gh""p_$(printf 'A%.0s' $(seq 1 30))"

payload() {  # payload <file_path> <content>
  python3 -I -c 'import json,sys; print(json.dumps({"tool_name":"Write","tool_input":{"file_path":sys.argv[1],"content":sys.argv[2]}}))' "$1" "$2"
}
# call <mode> <file_path> <content> [env assignments...]: sets RC, ERR (stderr)
call() {
  local mode="$1" path="$2" content="$3" p; shift 3
  p="$(payload "$path" "$content")"
  ERR="$(printf '%s' "$p" | env HOME="$H" "$@" bash "$HOOK" "$mode" 2>&1 >/dev/null)"; RC=$?
}
# raw <mode> <json> [env assignments...]: the hook on a literal payload
raw() {
  local mode="$1" json="$2"; shift 2
  ERR="$(printf '%s' "$json" | env HOME="$H" "$@" bash "$HOOK" "$mode" 2>&1 >/dev/null)"; RC=$?
}

# 1. pre: the baseline behavior
call pre "$POOLFILE" "the key is $CRED, remember it"
[ "$RC" = 2 ] && grep -q 'BLOCKED write to .*literal-credential' <<< "$ERR" && grep -q 'github-token' <<< "$ERR" \
  && ok "pre: a credential written to a memory pool is blocked (exit 2) with the pattern named" || bad "pre credential" "rc=$RC $ERR"
call pre "$POOLFILE" "the key lives in the SOPS vault under cloud/github, never here"
[ "$RC" = 0 ] && [ -z "$ERR" ] && ok "pre: clean content passes silently" || bad "pre clean" "rc=$RC $ERR"
call pre "$T/elsewhere/code.py" "token = '$CRED'"
[ "$RC" = 0 ] && ok "pre: an unguarded path is untouched, whatever it holds" || bad "pre unguarded" "rc=$RC $ERR"
call pre "$H/OPS/CONTEXT/projects/exampleproj-lessons.md" "see $CRED"
[ "$RC" = 2 ] && ok "pre: a lessons file is guarded too" || bad "pre lessons file" "rc=$RC $ERR"
call pre "$POOLFILE" "the key is $CRED" SECRETS_GUARD=off
[ "$RC" = 0 ] && ok "pre: SECRETS_GUARD=off is the operator's escape hatch" || bad "SECRETS_GUARD=off" "rc=$RC"
raw pre "$(python3 -I -c 'import json,sys; print(json.dumps({"tool_name":"Edit","tool_input":{"file_path":sys.argv[1],"old_string":"a","new_string":"b "+sys.argv[2]}}))' "$POOLFILE" "$CRED")"
[ "$RC" = 2 ] && grep -q 'literal-credential' <<< "$ERR" && ok "pre: an Edit's new_string is scanned" || bad "pre Edit new_string" "rc=$RC $ERR"

# 2. pre with broken temp space: the verdict is the scan's, never the disk's
MISSING="$T/no/such/tmp"
call pre "$POOLFILE" "the key is $CRED" TMPDIR="$MISSING"
[ "$RC" = 2 ] && grep -q 'literal-credential' <<< "$ERR" && ok "pre, TMPDIR a missing dir (mktemp would fail): a credential is still blocked" || bad "credential passed with TMPDIR missing" "rc=$RC $ERR"
call pre "$POOLFILE" "a pointer to the vault, no secret" TMPDIR="$MISSING"
[ "$RC" = 0 ] && ok "pre, TMPDIR a missing dir: clean content passes (the scan needs no temp file)" || bad "clean content blocked with TMPDIR missing" "rc=$RC $ERR"
mkdir -p "$T/ro"; chmod 555 "$T/ro"
call pre "$POOLFILE" "the key is $CRED" TMPDIR="$T/ro"
[ "$RC" = 2 ] && ok "pre, TMPDIR unwritable: a credential is still blocked" || bad "credential passed with TMPDIR unwritable" "rc=$RC $ERR"
# A temp WRITE that fails (the disk-full case: mktemp succeeds, the printf into
# the file does not). RLIMIT_FSIZE 0 with SIGXFSZ ignored makes every write to a
# regular file fail with EFBIG, on any box and without mounting anything; pipes
# are not regular files, so a scan that uses one is unaffected.
write_fail() {  # write_fail <mode> <path> <content>: sets RC, ERR like call, under a zero file-size limit
  local p; p="$(payload "$2" "$3")"
  ERR="$( ulimit -f 0; trap '' XFSZ; printf '%s' "$p" | env HOME="$H" TMPDIR="$T" bash "$HOOK" "$1" 2>&1 >/dev/null )"; RC=$?
}
write_fail pre "$POOLFILE" "the key is $CRED"
[ "$RC" = 2 ] && grep -q 'literal-credential' <<< "$ERR" \
  && ok "pre, every file write failing (EFBIG): the credential is blocked, not scanned as an empty file" || bad "credential passed with failing writes" "rc=$RC $ERR"
write_fail pre "$POOLFILE" "a pointer to the vault, no secret"
[ "$RC" = 0 ] && ok "pre, every file write failing: clean content still passes" || bad "clean content blocked with failing writes" "rc=$RC $ERR"

# 3. pre with a scanner that fails: block, saying the content could not be scanned
M="$T/mirror/.claude-config"; mkdir -p "$M/hooks" "$M/bin"
cp "$(dirname "$HOOK")/secrets-guard.sh" "$(dirname "$HOOK")/hooklib.sh" "$M/hooks/"
MH="$M/hooks/secrets-guard.sh"
stub() { printf '#!/usr/bin/env bash\n%s\n' "$1" > "$M/bin/secrets-scan.sh"; chmod 755 "$M/bin/secrets-scan.sh"; }
HOOK_REAL="$HOOK"; HOOK="$MH"
stub 'cat >/dev/null; exit 0'
call pre "$POOLFILE" "anything"; [ "$RC" = 0 ] && ok "pre, scanner exit 0: the write passes" || bad "stub clean" "rc=$RC $ERR"
stub 'cat >/dev/null; exit 69'
call pre "$POOLFILE" "anything"
[ "$RC" = 2 ] && grep -q 'could not be scanned' <<< "$ERR" && grep -q 'status 69' <<< "$ERR" \
  && ok "pre, scanner exit 69: blocked, and the message says it could not be scanned" || bad "scanner failure passed" "rc=$RC $ERR"
stub 'kill -9 $$'
call pre "$POOLFILE" "anything"
[ "$RC" = 2 ] && grep -q 'could not be scanned' <<< "$ERR" && ok "pre, scanner killed: blocked" || bad "killed scanner passed" "rc=$RC $ERR"
stub 'echo "stdin:1: github-token"; cat >/dev/null; exit 1'
call pre "$POOLFILE" "anything"
[ "$RC" = 2 ] && grep -q 'literal-credential' <<< "$ERR" && grep -q 'stdin:1: github-token' <<< "$ERR" \
  && ok "pre, scanner exit 1 with hits: the credential message shows the hits" || bad "scanner hits" "rc=$RC $ERR"
stub 'exit 0'   # never reads stdin: the writer gets SIGPIPE, which must not pass as a clean scan
BIGPAYLOAD="$(python3 -I -c 'import json,sys; print(json.dumps({"tool_input":{"file_path":sys.argv[1],"content":"x" * 400000}}))' "$POOLFILE")"
raw pre "$BIGPAYLOAD"
[ "$RC" = 2 ] && grep -q 'could not be scanned' <<< "$ERR" && ok "pre, scanner that stops reading early: blocked, not passed" || bad "short read passed" "rc=$RC $ERR"
rm -f "$M/bin/secrets-scan.sh"
call pre "$POOLFILE" "anything"
[ "$RC" = 2 ] && grep -q 'scanner missing' <<< "$ERR" && ok "pre, scanner missing (none beside the hook, none under ~/OPS): blocked" || bad "missing scanner" "rc=$RC $ERR"
call post "$POOLFILE" "anything"
[ "$RC" = 0 ] && ok "post, scanner missing: noted, never blocks" || bad "post with missing scanner" "rc=$RC $ERR"
# the guarded-path test comes first: an unguarded path never reaches the scanner
stub 'echo REACHED > "'"$T"'/scanner-reached"; cat >/dev/null; exit 0'
call pre "$T/elsewhere/code.py" "anything"
[ "$RC" = 0 ] && [ ! -e "$T/scanner-reached" ] && ok "an unguarded path never reaches the scanner" || bad "unguarded path scanned" "rc=$RC"
HOOK="$HOOK_REAL"

# The real scanner when grep cannot run (a grep that exits 2 first on PATH): the
# scanner exits 2, never 0, and the guard blocks.
mkdir -p "$T/badgrep"; printf '#!/bin/sh\nexit 2\n' > "$T/badgrep/grep"; chmod +x "$T/badgrep/grep"
call pre "$POOLFILE" "a pointer to the vault, no secret" PATH="$T/badgrep:$PATH"
[ "$RC" = 2 ] && grep -q 'could not be scanned' <<< "$ERR" && grep -q 'status 2' <<< "$ERR" \
  && ok "pre, the scanner's grep fails: blocked as unscanned (scanner exit 2)" || bad "grep failure passed" "rc=$RC $ERR"

# Directory scans back verify-ops as well as the hook. A failed walk must not
# turn a partial list (or no list) into a successful scan of the whole directory.
SCAN="$(dirname "$HOOK_REAL")/../bin/secrets-scan.sh"
SCANDIR="$T/scan-tree"; mkdir -p "$SCANDIR"
printf 'a clean note\n' > "$SCANDIR/clean.md"
BADFIND="$T/badfind"; mkdir -p "$BADFIND"
printf '#!/bin/sh\nprintf "%%s\\0" "$1/clean.md"\nexit 1\n' > "$BADFIND/find"
chmod +x "$BADFIND/find"
ERR="$(PATH="$BADFIND:$PATH" bash "$SCAN" "$SCANDIR" 2>&1)"; RC=$?
[ "$RC" = 2 ] && grep -q 'directory walk failed' <<< "$ERR" \
  && ok "scanner: a failed directory walk exits 2, even after some files were listed" || bad "failed walk reported clean" "rc=$RC $ERR"
ERR="$(bash "$SCAN" "$T/missing-note.md" 2>&1)"; RC=$?
[ "$RC" = 2 ] && grep -q 'cannot read' <<< "$ERR" \
  && ok "scanner: a missing explicit input is unscanned, never clean" || bad "missing input reported clean" "rc=$RC $ERR"
if [ "$(id -u)" -ne 0 ]; then
  chmod 000 "$SCANDIR/clean.md"
  ERR="$(bash "$SCAN" "$SCANDIR/clean.md" 2>&1)"; RC=$?
  chmod 600 "$SCANDIR/clean.md"
  [ "$RC" = 2 ] && grep -q 'cannot read' <<< "$ERR" \
    && ok "scanner: an unreadable file is a scan error, not a credential hit" || bad "unreadable file misreported" "rc=$RC $ERR"
fi
# Preserve path framing and severity when a walk fails after finding a secret.
ODDFILE="$SCANDIR/line"$'\n'"break.md"
printf '%s\n' "$CRED" > "$ODDFILE"
ERR="$(bash "$SCAN" "$SCANDIR" 2>&1)"; RC=$?
[ "$RC" = 1 ] && grep -q 'github-token' <<< "$ERR" \
  && ok "scanner: newline in a file name still reaches the credential scan" || bad "newline file was skipped" "rc=$RC $ERR"
printf '%s\n' "$CRED" > "$SCANDIR/clean.md"
ERR="$(PATH="$BADFIND:$PATH" bash "$SCAN" "$SCANDIR" 2>&1)"; RC=$?
[ "$RC" = 1 ] && grep -q 'github-token' <<< "$ERR" && grep -q 'directory walk failed' <<< "$ERR" \
  && ok "scanner: a hit wins over a walk error, and both are reported" || bad "walk error hid a hit" "rc=$RC $ERR"

# 4. pre, a payload the guard cannot read: block (post notes it and passes)
mkdir -p "$T/nojson"
for u in bash cat dirname basename; do ln -s "$(command -v "$u")" "$T/nojson/$u"; done
raw pre "$(payload "$POOLFILE" "anything")" PATH="$T/nojson"
[ "$RC" = 2 ] && grep -q 'could not be scanned' <<< "$ERR" && ok "pre, no JSON parser (no jq, no python): blocked" || bad "no parser passed" "rc=$RC $ERR"
raw post "$(payload "$POOLFILE" "anything")" PATH="$T/nojson"
[ "$RC" = 0 ] && ok "post, no JSON parser: noted, never blocks" || bad "post with no parser" "rc=$RC $ERR"
raw pre '{"tool_name":"Write","tool_input":{"file_path":'
[ "$RC" = 2 ] && grep -q 'no file_path' <<< "$ERR" && ok "pre, malformed JSON: blocked" || bad "malformed JSON passed" "rc=$RC $ERR"
raw pre '{"tool_name":"Write","tool_input":{"content":"anything"}}'
[ "$RC" = 2 ] && ok "pre, a payload with no file_path: blocked" || bad "no file_path passed" "rc=$RC $ERR"
# A parser that reads file_path but fails on the content (a guarded path, so the
# content matters): pre blocks, post notes it and passes.
mkdir -p "$T/halfjson"
for u in bash cat dirname basename; do ln -s "$(command -v "$u")" "$T/halfjson/$u"; done
printf '#!/bin/bash\nfor a in "$@"; do [ "$a" = tool_input.file_path ] && { cat >/dev/null; printf "%%s" "$STUB_FP"; exit 0; }; done\nexit 5\n' \
  > "$T/halfjson/jq"; chmod +x "$T/halfjson/jq"
raw pre "$(payload "$POOLFILE" "the key is $CRED")" PATH="$T/halfjson" STUB_FP="$POOLFILE"
[ "$RC" = 2 ] && grep -q 'content could not be extracted' <<< "$ERR" \
  && ok "pre, the content field cannot be extracted on a guarded path: blocked" || bad "content extraction failure passed" "rc=$RC $ERR"
raw post "$(payload "$POOLFILE" "anything")" PATH="$T/halfjson" STUB_FP="$POOLFILE"
[ "$RC" = 0 ] && ok "post, the content field cannot be extracted: noted, never blocks" || bad "post blocked on extraction failure" "rc=$RC $ERR"
# The hook input itself cannot be read (the read fails: a cat that exits 1 is
# first on PATH; a closed stdin is no test, because bash reuses fd 0 for the
# next file it opens).
mkdir -p "$T/badcat"; printf '#!/bin/sh\nexit 1\n' > "$T/badcat/cat"; chmod +x "$T/badcat/cat"
raw pre "$(payload "$POOLFILE" "the key is $CRED")" PATH="$T/badcat:$PATH"
[ "$RC" = 2 ] && grep -q 'could not be read' <<< "$ERR" && ok "pre, the hook input cannot be read: blocked" || bad "unreadable input passed" "rc=$RC $ERR"
raw post "$(payload "$POOLFILE" "anything")" PATH="$T/badcat:$PATH"
[ "$RC" = 0 ] && ok "post, the hook input cannot be read: never blocks" || bad "post blocked on unreadable input" "rc=$RC $ERR"
# Empty content is not an extraction failure: an empty Write or Edit passes.
call pre "$POOLFILE" ""
[ "$RC" = 0 ] && ok "pre, an empty Write content passes" || bad "empty Write blocked" "rc=$RC $ERR"
raw pre "$(python3 -I -c 'import json,sys; print(json.dumps({"tool_name":"Edit","tool_input":{"file_path":sys.argv[1],"old_string":"x","new_string":""}}))' "$POOLFILE")"
[ "$RC" = 0 ] && ok "pre, an Edit with an empty new_string passes" || bad "empty Edit blocked" "rc=$RC $ERR"

# 5. post: the routing nudge stays, and never blocks on a temp-space failure
BIGBODY="$(python3 -I -c 'print("Notes about the exampleproj project and what we found. " * 12)')"
ENTRY="$(printf -- '---\nname: exampleproj-thing\ndescription: x\nmetadata:\n  type: project\n---\n%s' "$BIGBODY")"
call post "$POOLFILE" "$ENTRY"
if [ "$RC" = 2 ] && grep -q 'memory-routing nudge' <<< "$ERR" && grep -q 'exampleproj' <<< "$ERR" \
   && [ -s "$QUEUE" ] && grep -q 'project:exampleproj' "$QUEUE"; then
  ok "post: a substantive type project entry still gets the routing nudge (exit 2) and a queue line"
else bad "post nudge" "rc=$RC $ERR queue=$(cat "$QUEUE" 2>&1)"; fi
rm -f "$QUEUE"
call post "$POOLFILE" "$ENTRY" TMPDIR="$MISSING"
if [ "$RC" = 0 ] && grep -q 'cannot make a temp file' <<< "$ERR" && [ ! -e "$QUEUE" ]; then
  ok "post, no usable temp space: the nudge is skipped with a note, exit 0 (advice never blocks)"
else bad "post with broken TMPDIR" "rc=$RC $ERR"; fi
write_fail post "$POOLFILE" "$ENTRY"
if [ "$RC" = 0 ] && grep -q 'cannot write the temp file' <<< "$ERR" && [ ! -e "$QUEUE" ]; then
  ok "post, the temp write failing (EFBIG): the nudge is skipped with a note, exit 0"
else bad "post with failing writes" "rc=$RC $ERR"; fi
call post "$POOLFILE" "$(printf -- '---\nname: n\ndescription: x\nmetadata:\n  type: feedback\n---\n%s' "$BIGBODY")"
[ "$RC" = 0 ] && ok "post: a feedback entry gets no nudge" || bad "post feedback" "rc=$RC $ERR"
call post "$POOLFILE" "short project note"
[ "$RC" = 0 ] && ok "post: a short entry gets no nudge" || bad "post short" "rc=$RC $ERR"
call post "$POOLFILE" "the key is $CRED"
[ "$RC" = 0 ] && ok "post never blocks a credential: that is the pre scan's job" || bad "post blocked" "rc=$RC $ERR"

echo
echo "secrets-guard-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
