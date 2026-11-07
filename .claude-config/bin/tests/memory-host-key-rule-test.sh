#!/usr/bin/env bash
# memory-host-key-rule-test.sh: one case table, three readers, identical verdicts.
#
# The memory-host file (~/.config/ops/memory-host) names the host key every pool
# reader uses, so a successor box can share its predecessor's pools. Three readers
# each hold their own copy of the rule, because none of them can import another's
# code:
#   memory-init       bin/memory-init, run with --dry-run
#   memory-index      bin/memory-index --digest (the memory digest)
#   memory-init.ps1   the PowerShell twin (SKIPs when pwsh is not on the PATH)
# If two of them disagree about one file, one machine reads one pool set and
# another reads a different one, or one refuses what another accepts. A probe of
# the first versions of the readers found 11 of 47 inputs where they disagreed
# (Python took a BOM, NBSP, NEL and trailing \x1f; PowerShell took the Kelvin sign
# through lowercase-before-check; the bash readers took a key padded past their
# 256-byte read), so every case below is run through all three and each must
# return the table's verdict.
#
# THE RULE (the same text sits in each reader):
#   Absent (nothing there, ~/.config/ops is a file, HOME unset or empty) means
#   no override and the reader's usual key. Any other failure to look at or read
#   the file (no permission on it or an ancestor, a directory, a dangling symlink,
#   a non-regular file) is a refusal. The file is ASCII bytes only, at most 65
#   bytes: one key [A-Za-z0-9][A-Za-z0-9._-]{0,62}, then optionally one LF or one
#   CRLF, nothing else. Uppercase ASCII is lowercased after the check.
#
# Verdicts: ok:<key>, refuse, absent. Every path is under a temp dir. The guard
# below refuses any run outside bin/sandbox-run. To run the ps1 cases, bind pwsh
# in: sandbox-run ... --ro-bind <the directory that holds pwsh> and its install tree.
#
# Usage: memory-host-key-rule-test.sh    (exit 0 all pass, 1 otherwise)
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/../sandbox-guard.sh" && sandbox_guard || exit 97
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
INIT="$HERE/../memory-init"
INDEX="$HERE/../memory-index"
INITPS="$HERE/../memory-init.ps1"
for f in "$INIT" "$INDEX"; do [ -f "$f" ] || { echo "FAIL: $f missing"; exit 1; }; done
command -v python3 >/dev/null || { echo "FAIL: python3 required"; exit 1; }
PWSH="$(command -v pwsh 2>/dev/null || true)"; [ -f "$INITPS" ] || PWSH=""

T="$(mktemp -d)"; trap 'chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"' EXIT
pass=0; fail=0; skipped_ps=0
echo "memory-host-key-rule-test:"

plain_host() {  # the key the hostname alone gives, memory-init's own rule mirrored
  local raw mid
  raw="$(hostname 2>/dev/null | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
  case "$raw" in
    ''|workspace|localhost|localhost.localdomain|ubuntu|debian|kali|raspberrypi)
      mid=""
      [ -r /etc/machine-id ] && mid="$(cat /etc/machine-id 2>/dev/null)"
      [ -z "$mid" ] && [ -r /var/lib/dbus/machine-id ] && mid="$(cat /var/lib/dbus/machine-id 2>/dev/null)"
      mid="$(printf '%s' "$mid" | tr -d '[:space:]')"
      printf 'm-%s' "${mid:0:12}" ;;
    *) printf '%s' "$raw" ;;
  esac
}
PLAIN="$(plain_host)"; [ -n "$PLAIN" ] && [ "$PLAIN" != "m-" ] || { echo "FAIL: no hostname or machine-id key on this box"; exit 1; }
WINHOST=winbox   # COMPUTERNAME for the ps1 reader's no-override key

# Fixture shared by every case: an OPS checkout, one project directory, a config dir.
CW="$T/ops"; PROJ="$T/proj"; CFG="$T/cfg"
mkdir -p "$CW/.claude-memory" "$PROJ" "$CFG/projects"
git -c init.defaultBranch=main init -q "$CW" >/dev/null 2>&1
CK="$(printf '%s' "$PROJ" | sed 's/[^A-Za-z0-9]/-/g')"     # Claude's key for the project directory

# --- the three readers: each prints ok:<key>, refuse or absent ---------------------
# $H is the case's HOME. $1 (optional) is "nohome" to run with HOME unset or "emptyhome".
r_init() {
  local out rc
  out="$(env HOME="$H" OPS_DIR="$CW" CLAUDE_CONFIG_DIR="$CFG" timeout 20 bash "$INIT" --dry-run 2>&1 </dev/null)"; rc=$?
  if grep -q "^\[memory-init\] host key '.*' from " <<< "$out"; then
    printf 'ok:%s' "$(sed -n "s/^\[memory-init\] host key '\(.*\)' from .*/\1/p" <<< "$out" | head -1)"
  elif [ "$rc" = 0 ] && [ "$(sed -n 's/^\[memory-init\] host: *//p' <<< "$out" | head -1)" = "$PLAIN" ]; then printf 'absent'
  else printf 'refuse'; fi
}
r_index() {
  local out first
  case "${1:-}" in
    nohome)    out="$(env -u HOME CLAUDE_CONFIG_DIR="$CFG" OPS_DIR="$CW" timeout 20 python3 -I "$INDEX" --digest --cwd "$PROJ" --ops "$CW" 2>/dev/null </dev/null)" ;;
    emptyhome) out="$(env HOME= CLAUDE_CONFIG_DIR="$CFG" OPS_DIR="$CW" timeout 20 python3 -I "$INDEX" --digest --cwd "$PROJ" --ops "$CW" 2>/dev/null </dev/null)" ;;
    *)         out="$(env -u MEMORY_DIGEST_HOST HOME="$H" CLAUDE_CONFIG_DIR="$CFG" OPS_DIR="$CW" timeout 20 python3 -I "$INDEX" --digest --cwd "$PROJ" --ops "$CW" 2>/dev/null </dev/null)" ;;
  esac
  first="$(grep -m1 '^OPS memory digest failed' <<< "$out")"
  if [ -n "$first" ]; then printf 'refuse'; return; fi
  local key; key="$(sed -n "s|.*$CW/.claude-memory/\(.*\)$CK).*|\1|p" <<< "$out" | head -1)"
  if [ -z "$key" ]; then printf 'refuse'; elif [ "$key" = "$PLAIN" ]; then printf 'absent'; else printf 'ok:%s' "$key"; fi
}
r_ps1() {
  local out rc
  out="$(env HOME="$H" USERPROFILE="$H" COMPUTERNAME="$WINHOST" OPS_DIR="$CW" CLAUDE_CONFIG_DIR="$CFG" timeout 60 "$PWSH" -NoProfile -NonInteractive -File "$INITPS" -DryRun 2>&1 </dev/null)"; rc=$?
  if grep -q "^\[memory-init\] host key '.*' from " <<< "$out"; then
    printf 'ok:%s' "$(sed -n "s/^\[memory-init\] host key '\(.*\)' from .*/\1/p" <<< "$out" | head -1)"
  elif [ "$rc" = 0 ] && [ "$(sed -n 's/^\[memory-init\] host: *//p' <<< "$out" | head -1)" = "$WINHOST" ]; then printf 'absent'
  else printf 'refuse'; fi
}

# run_case <label> <expected> [reader to skip...]: all readers, one verdict each.
run_case() {
  local label="$1" want="$2"; shift 2
  local skip=" $* " got_i got_x got_p="-" bad=0
  got_i="$(r_init)"; got_x="$(r_index)"
  [[ "$skip" == *" init "* ]] && got_i="$want"
  [[ "$skip" == *" ps1 "* ]] && got_p="$want"
  if [ -n "$PWSH" ] && [[ "$skip" != *" ps1 "* ]]; then got_p="$(r_ps1)"; elif [ -z "$PWSH" ]; then skipped_ps=$((skipped_ps+1)); got_p="$want"; fi
  [ "$got_i" = "$want" ] && [ "$got_x" = "$want" ] && [ "$got_p" = "$want" ] || bad=1
  if [ "$bad" = 0 ]; then pass=$((pass+1)); echo "PASS: $label -> $want"
  else
    fail=$((fail+1)); echo "FAIL: $label: want $want; memory-init=$got_i memory-index=$got_x ps1=$got_p"
  fi
}

new_home() { H="$T/h$RANDOM$RANDOM"; mkdir -p "$H/.config/ops"; MH="$H/.config/ops/memory-host"; }
# content_case <label> <expected> <printf-format of the file's bytes>
content_case() { new_home; printf -- "$3" > "$MH"; run_case "$1" "$2"; }

K63="$(printf 'a%.0s' $(seq 1 63))"; K64="${K63}a"; K65="${K64}a"
PAD300="$(printf ' %.0s' $(seq 1 300))"

# --- accepted -------------------------------------------------------------------
content_case "plain key, no newline"                  ok:sharedbox 'sharedbox'
content_case "key and LF"                             ok:sharedbox 'sharedbox\n'
content_case "key and CRLF"                           ok:sharedbox 'sharedbox\r\n'
content_case "uppercase is lowercased"                ok:sharedbox 'SharedBox\n'
content_case "dot, underscore and hyphen inside"      ok:ex.ample_1-b 'ex.ample_1-b\n'
content_case "two dots inside (a..b is not a path)"   ok:a..b 'a..b\n'
content_case "one character"                          ok:a 'a'
content_case "leading digit"                          ok:3example '3example\n'
content_case "63 characters and LF"                   ok:$K63 "$K63\\n"
content_case "63 characters and CRLF (65 bytes)"      ok:$K63 "$K63\\r\\n"

# --- refused: emptiness and layout ------------------------------------------------
content_case "empty file"                             refuse ''
content_case "LF only"                                refuse '\n'
content_case "CRLF only"                              refuse '\r\n'
content_case "a space only"                           refuse ' '
content_case "leading space"                          refuse ' sharedbox\n'
content_case "trailing space"                         refuse 'sharedbox \n'
content_case "leading tab"                            refuse '\tsharedbox\n'
content_case "trailing tab"                           refuse 'sharedbox\t\n'
content_case "tab inside"                             refuse 'ex\tample\n'
content_case "space inside"                           refuse 'ex ample\n'
content_case "two LFs"                                refuse 'sharedbox\n\n'
content_case "LF then CRLF"                           refuse 'sharedbox\n\r\n'
content_case "CR alone at the end"                    refuse 'sharedbox\r'
content_case "CR CR LF"                               refuse 'sharedbox\r\r\n'
content_case "two lines"                              refuse 'one\ntwo\n'
content_case "two lines, CRLF"                        refuse 'one\r\ntwo\r\n'
content_case "vertical tab"                           refuse 'sharedbox\v\n'
content_case "form feed"                              refuse 'sharedbox\f\n'

# --- refused: size ------------------------------------------------------------------
content_case "64 characters (key too long)"           refuse "$K64\\n"
content_case "65 characters, no newline"              refuse "$K65"
content_case "63 characters + CRLF + LF (66 bytes)"   refuse "$K63\\r\\n\\n"
content_case "valid key padded past 256 bytes"        refuse "sharedbox$PAD300\\n"
new_home; { printf 'sharedbox\n'; head -c 300 /dev/zero; } > "$MH"; run_case "valid key, newline, then 300 NULs" refuse

# --- refused: bytes that are not the key set -----------------------------------------
content_case "key with a slash"                       refuse 'a/b\n'
content_case "a parent path"                          refuse '../x\n'
content_case "just two dots"                          refuse '..\n'
content_case "leading dot"                            refuse '.hidden\n'
content_case "leading hyphen"                         refuse '-x\n'
content_case "leading underscore"                     refuse '_x\n'
content_case "backslash"                              refuse 'a\\b\n'
content_case "semicolon"                              refuse 'a;b\n'
content_case "dollar sign"                            refuse 'a$b\n'
content_case "backtick"                               refuse 'a`b\n'
content_case "DEL (0x7f)"                             refuse 'a\x7fb\n'
content_case "ESC (0x1b)"                             refuse 'a\x1bb\n'
content_case "NUL inside"                             refuse 'ab\0cd\n'
content_case "NUL only"                               refuse '\0'
content_case "NUL after the key"                      refuse 'sharedbox\0'

# --- refused: Unicode and encodings no reader may accept ---------------------------------
content_case "UTF-8 BOM before a key"                 refuse '\xef\xbb\xbfsharedbox\n'
content_case "UTF-8 BOM only"                         refuse '\xef\xbb\xbf'
content_case "UTF-16LE with BOM"                      refuse '\xff\xfee\000x\000a\000m\000p\000l\000e\000\n\000'
content_case "UTF-16BE with BOM"                      refuse '\xfe\xff\000e\000x\000a\000m\000p\000l\000e\000\n'
content_case "NBSP before the key"                    refuse '\xc2\xa0sharedbox\n'
content_case "NBSP after the key"                     refuse 'sharedbox\xc2\xa0\n'
content_case "NEL (U+0085) before the key"            refuse '\xc2\x85sharedbox\n'
content_case "NEL (U+0085) after the key"             refuse 'sharedbox\xc2\x85\n'
content_case "0x1c after the key"                     refuse 'sharedbox\x1c\n'
content_case "0x1f after the key"                     refuse 'sharedbox\x1f\n'
content_case "0x1c before the key"                    refuse '\x1csharedbox\n'
content_case "0x1f before the key"                    refuse '\x1fsharedbox\n'
content_case "Kelvin sign alone (lowercases to k)"    refuse '\xe2\x84\xaa\n'
content_case "Kelvin sign inside a key"               refuse 'exa\xe2\x84\xaa\n'
content_case "Kelvin sign then letters"               refuse '\xe2\x84\xaaabc\n'
content_case "a lone 0xff byte"                       refuse '\xff\n'
content_case "Latin-1 e acute (0xe9)"                 refuse 'caf\xe9\n'
content_case "UTF-8 e acute"                          refuse 'caf\xc3\xa9\n'
content_case "dotless i (lowercases oddly)"           refuse 'ad\xc4\xb0\n'

# --- file system states ---------------------------------------------------------------------
new_home; mkdir "$MH";                                         run_case "a directory in its place" refuse
new_home; ln -s "$H/nowhere" "$MH";                            run_case "a dangling symlink" refuse
new_home; printf 'ViaLink\n' > "$H/real"; ln -s "$H/real" "$MH"; run_case "a symlink to a good file is followed" ok:vialink
new_home; ln -s "$H/real" "$MH"; printf ' bad \n' > "$H/real";    run_case "a symlink to a bad file is refused" refuse
new_home; rm -rf "$H/.config/ops"; printf 'x' > "$H/.config/ops"; run_case "~/.config/ops is a regular file (ENOTDIR): absent" absent
new_home; rm -rf "$H/.config"; printf 'x' > "$H/.config";      run_case "~/.config is a regular file (ENOTDIR): absent" absent
new_home; rm -rf "$H/.config";                                 run_case "no ~/.config at all: absent" absent
new_home;                                                      run_case "~/.config/ops exists, no file: absent" absent
new_home; mkfifo "$MH";                                        run_case "a FIFO in its place (not a regular file)" refuse ps1
if [ "$(id -u)" != 0 ]; then
  new_home; printf 'secret\n' > "$MH"; chmod 000 "$MH";        run_case "the file itself unreadable (mode 000)" refuse; chmod 600 "$MH"
  new_home; printf 'secret\n' > "$MH"; chmod 000 "$H/.config/ops"; run_case "~/.config/ops not searchable (EACCES)" refuse; chmod 755 "$H/.config/ops"
  new_home; printf 'secret\n' > "$MH"; chmod 000 "$H/.config";        run_case "~/.config not searchable (EACCES)" refuse; chmod 755 "$H/.config"
else
  echo "SKIP: permission cases (running as root, where mode 000 does not stop a read)"
fi

# --- HOME unset or empty: no override, and nothing fails ----------------------------------------
# memory-init and the ps1 twin need HOME or USERPROFILE for everything else they do (unchanged), so only the
# reader that ran without it before is asked; it must give the usual key, not "unavailable".
new_home; printf 'sharedbox\n' > "$MH"
gx="$(r_index nohome)"
[ "$gx" = absent ] && { pass=$((pass+1)); echo "PASS: HOME unset: memory-index uses the usual key"; } \
  || { fail=$((fail+1)); echo "FAIL: HOME unset: memory-index=$gx (want absent)"; }
gx="$(r_index emptyhome)"
[ "$gx" = absent ] && { pass=$((pass+1)); echo "PASS: HOME empty: memory-index uses the usual key"; } \
  || { fail=$((fail+1)); echo "FAIL: HOME empty: memory-index=$gx (want absent)"; }

[ -z "$PWSH" ] && echo "SKIP: memory-init.ps1 column ($skipped_ps cases; pwsh is not on the PATH here)"
echo
echo "memory-host-key-rule-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
