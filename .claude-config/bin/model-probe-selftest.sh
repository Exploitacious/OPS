#!/usr/bin/env bash
# model-probe-selftest.sh: prove model-probe.sh is report-only and reports
# right: it probes each distinct pinned id once, reports ok / FAIL / UNSURE
# with the right exit code, never passes or echoes a value that is not a model
# id, and leaves the settings file and the rest of HOME byte-for-byte as found.
# Runs entirely against a MOCK claude binary under a throwaway HOME made by
# mktemp: no real API usage, no touch of the real ~/.claude.
#
# Exit 0 = every case behaves; 1 = defect.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/model-probe.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fails=0

# Mock claude: records the --model it was given; rejects ids listed in
# MOCK_REJECT, answers with a usage-limit error for ids in MOCK_QUOTA, honors
# MOCK_SLEEP.
MOCK="$WORK/mock-claude"
cat > "$MOCK" <<'MOCKEOF'
#!/usr/bin/env bash
model=""
while [ $# -gt 0 ]; do [ "$1" = "--model" ] && { model="$2"; shift; }; shift; done
printf '%s\n' "$model" >> "${MOCK_RECORD:?}"
[ -n "${MOCK_SLEEP:-}" ] && sleep "$MOCK_SLEEP"
case " ${MOCK_REJECT:-} " in *" $model "*) echo "API Error: model not found: $model"; exit 1;; esac
case " ${MOCK_QUOTA:-} " in *" $model "*) echo "API Error: usage limit reached"; exit 1;; esac
echo "ok"
MOCKEOF
chmod +x "$MOCK"

TH="$WORK/home"
SETTINGS="$TH/.claude/settings.json"
export MOCK_RECORD="$WORK/record.txt" OPS_MODEL_PROBE_BIN="$MOCK"

reset() {
  rm -rf "$TH" "$MOCK_RECORD"
  mkdir -p "$TH/.claude"
  cat > "$SETTINGS" <<'JSON'
{
  "env": {
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "claude-opus-5-5[1m]",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "claude-sonnet-5-5[1m]",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "claude-haiku-5-5",
    "CLAUDE_CODE_SUBAGENT_MODEL": "claude-sonnet-5-5[1m]"
  },
  "model": "claude-opus-5-5[1m]"
}
JSON
  unset MOCK_REJECT MOCK_QUOTA MOCK_SLEEP OPS_MODEL_PROBE_TIMEOUT 2>/dev/null || true
}

snapshot() { (cd "$TH" && find . -print0 | sort -z | xargs -0 sha256sum 2>/dev/null; find . | sort); }

probe() { # run model-probe.sh under the throwaway HOME; sets OUT and RC
  OUT="$(cd "$WORK" && env HOME="$TH" bash "$SCRIPT" "$@" 2>&1)"; RC=$?
}

chk() { # $1=label $2=condition-result (0=pass)
  if [ "$2" -eq 0 ]; then printf '  PASS  %s\n' "$1"
  else printf '  FAIL  %s\n' "$1"; printf '%s\n' "$OUT" | sed 's/^/        | /'; fails=$((fails + 1)); fi
}

echo "model-probe-selftest:"

# 1. --list: no API call, every distinct id listed with its keys, exit 0.
reset
probe --list
chk "--list exits 0"                     "$([ "$RC" = 0 ]; echo $?)"
chk "--list makes no CLI call"           "$([ ! -e "$MOCK_RECORD" ]; echo $?)"
chk "--list groups keys per id"          "$(printf '%s' "$OUT" | grep -qF 'pinned  claude-sonnet-5-5[1m]  (ANTHROPIC_DEFAULT_SONNET_MODEL, CLAUDE_CODE_SUBAGENT_MODEL)'; echo $?)"
chk "--list puts the session pin first"  "$(printf '%s' "$OUT" | grep 'pinned' | head -1 | grep -qF 'claude-opus-5-5[1m]  (model, ANTHROPIC_DEFAULT_OPUS_MODEL)'; echo $?)"

# 2. All answer: exit 0, each distinct id probed exactly once, nothing written.
reset
before="$(snapshot)"
probe
after="$(snapshot)"
chk "all ids answer -> exit 0"           "$([ "$RC" = 0 ]; echo $?)"
chk "three distinct ids, one probe each" "$([ "$(sort "$MOCK_RECORD" | uniq | wc -l)" = 3 ] && [ "$(wc -l < "$MOCK_RECORD")" = 3 ]; echo $?)"
chk "HOME byte-identical after a probe"  "$([ "$before" = "$after" ]; echo $?)"

# 3. A rejected id: FAIL line, exit 1, settings untouched (no pin rewrite).
reset
before="$(snapshot)"
MOCK_REJECT="claude-opus-5-5[1m]" probe
after="$(snapshot)"
chk "rejected id -> exit 1"              "$([ "$RC" = 1 ]; echo $?)"
chk "rejected id -> FAIL line"           "$(printf '%s' "$OUT" | grep -qF 'FAIL    claude-opus-5-5[1m]'; echo $?)"
chk "rejected id -> HOME byte-identical" "$([ "$before" = "$after" ]; echo $?)"
chk "pin still the original value"       "$([ "$(jq -r .model "$SETTINGS")" = 'claude-opus-5-5[1m]' ]; echo $?)"

# 4. Quota-shaped refusal and timeout are UNSURE, not FAIL.
reset
MOCK_QUOTA="claude-haiku-5-5" probe
chk "usage-limit refusal -> UNSURE"      "$(printf '%s' "$OUT" | grep -qF 'UNSURE  claude-haiku-5-5'; echo $?)"
chk "usage-limit refusal -> exit 1"      "$([ "$RC" = 1 ]; echo $?)"
reset
MOCK_SLEEP=3 OPS_MODEL_PROBE_TIMEOUT=1 probe
chk "timeout -> UNSURE"                  "$(printf '%s' "$OUT" | grep -q 'UNSURE.*rc=124'; echo $?)"

# 5. A value that is not a model id is never passed to the CLI or echoed.
reset
jq '.env.ANTHROPIC_DEFAULT_HAIKU_MODEL = "not a model id; secret-like value 1234"' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
probe
chk "non-id value never reaches the CLI" "$(! grep -q 'secret-like' "$MOCK_RECORD"; echo $?)"
chk "non-id value never echoed"          "$(! printf '%s' "$OUT" | grep -q 'secret-like'; echo $?)"
chk "non-id value -> SKIP and exit 1"    "$(printf '%s' "$OUT" | grep -q 'SKIP' && [ "$RC" = 1 ]; echo $?)"

# 6. Environment errors exit 2: no claude CLI, no settings file.
reset
OUT="$(cd "$WORK" && env HOME="$TH" PATH="/usr/bin:/bin" OPS_MODEL_PROBE_BIN="$WORK/absent" bash "$SCRIPT" 2>&1)"; RC=$?
chk "missing claude CLI -> exit 2"       "$([ "$RC" = 2 ]; echo $?)"
reset
rm -f "$SETTINGS"
probe
chk "missing settings -> exit 2"         "$([ "$RC" = 2 ]; echo $?)"

# 7. The old pin-writing interface is gone.
reset
probe --force opus48
chk "--force is rejected (exit 2)"       "$([ "$RC" = 2 ]; echo $?)"

if [ "$fails" -eq 0 ]; then
  echo "model-probe-selftest: all cases pass"
  exit 0
fi
echo "model-probe-selftest: $fails case(s) failed"
exit 1
