#!/usr/bin/env bash
# Invoke only the real trust-seeding function and its caller under a temporary
# HOME. Do not run deploy: it also initializes memory and installs host wiring.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/../sandbox-guard.sh" && sandbox_guard || exit 97
DEPLOY="$(cd "$(dirname "$0")/../.." && pwd)/deploy.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/deploy-trust.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"
CLAUDE_HOME="$HOME/.claude"
mkdir -p "$CLAUDE_HOME"
msg_ok() { :; }
msg_warn() { :; }
msg_bad() { :; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
eval "$(awk '/^seed_trust\(\) \{/ {p=1} p {print} p && /^}/ {exit}' "$DEPLOY")"
TRUST="$HOME/.claude.json"
printf '{"projects": {"keep": {"history": [1]}}, "mcpServers": {"keep": {}}}\n' > "$TRUST"
chmod 600 "$TRUST"
seed_trust "$TRUST" >/dev/null
python3 - "$TRUST" "$HOME" <<'PY'
import json, os, stat, sys
d = json.load(open(sys.argv[1]))
assert d['projects']['keep']['history'] == [1]
assert d['mcpServers'] == {'keep': {}}
assert d['projects'][sys.argv[2]]['hasTrustDialogAccepted'] is True
assert stat.S_IMODE(os.stat(sys.argv[1]).st_mode) == 0o600
PY
cp "$TRUST" "$WORK/before"
seed_trust "$TRUST" >/dev/null
cmp -s "$TRUST" "$WORK/before" || fail 'repeat trust seed rewrote existing state'
printf '{"projects": {"recoverable": true},\n' > "$TRUST"
cp "$TRUST" "$WORK/before"
if seed_trust "$TRUST" >/dev/null 2>&1; then fail 'corrupt config reported success'; fi
cmp -s "$TRUST" "$WORK/before" || fail 'corrupt but recoverable config was replaced'
rm "$TRUST"
(umask 000; seed_trust "$TRUST" >/dev/null)
[[ "$(stat -c %a "$TRUST")" == 600 ]] || fail 'new app state is world-readable'
rm "$TRUST"
printf 'user data\n' > "$WORK/external"
ln -s "$WORK/external" "$TRUST"
if seed_trust "$TRUST" >/dev/null 2>&1; then fail 'symlinked app state reported success'; fi
[[ -L "$TRUST" ]] && [[ "$(cat "$WORK/external")" == 'user data' ]] || fail 'symlinked app state was changed'
rm "$TRUST"
DEPLOY_FAILED=''
# This executes the actual default-path assignment and error handling, rather
# than asserting a spelling of an assignment independently of its behavior.
eval "$(awk '/^jf=/ {p=1} p && /^# --- T3 Code/ {exit} p {print}' "$DEPLOY")"
[[ -f "$TRUST" && ! -e "$CLAUDE_HOME/.claude.json" ]] || fail 'trust caller wrote to the wrong config file'
printf 'broken\n' > "$TRUST"
DEPLOY_FAILED=''
eval "$(awk '/^jf=/ {p=1} p && /^# --- T3 Code/ {exit} p {print}' "$DEPLOY")" 2>/dev/null
[[ "$DEPLOY_FAILED" == *trust-anchor* ]] || fail 'caller swallowed trust-seeding failure'
[[ -z "$(find "$HOME" -name '*.trust.*' -print -quit)" ]] || fail 'trust update left a temporary file'
printf 'PASS: trust merge, idempotency, corrupt-state preservation, permissions, symlinks and default path\n'
