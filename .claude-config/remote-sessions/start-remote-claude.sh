#!/usr/bin/env bash
# Auto-start remote-controlled Claude Code sessions in tmux on boot.
# Driven by crontab: @reboot $HOME/OPS/.claude-config/remote-sessions/start-remote-claude.sh >> ~/.claude-boot-sessions.log 2>&1
# Recreates every session in the registry (~/.claude-remote-sessions.tsv), resuming each one's
# conversation if a transcript exists. Shares logic with new-remote-claude.sh via lib-remote-claude.sh.
set -u
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
source "$SCRIPT_DIR/lib-remote-claude.sh"

# Wait for outbound network before launching (Remote Control must reach claude.ai).
# Browser UA so Cloudflare doesn't 403 the check; fall back to a DNS check.
for _ in $(seq 1 30); do
  curl -fsS --max-time 4 -A "Mozilla/5.0" -o /dev/null https://claude.ai && break
  getent hosts claude.ai >/dev/null 2>&1 && break
  sleep 2
done

# Guaranteed sessions — always present and self-healing. If a guaranteed name is missing from the
# registry (never created, deregistered, or registry lost), register it with a fresh stable id so the
# loop below creates it; if already registered, its id + workdir are preserved so it resumes intact.
GUARANTEED_WORKDIR="$DEFAULT_WORKDIR"
for gname in "${RC_GUARANTEED_NAMES[@]}"; do
  if [ -z "$(rc_lookup "$gname")" ]; then
    rc_register "$gname" "$GUARANTEED_WORKDIR" "$(rc_new_uuid)"
    echo "$(date -Is) seeded guaranteed session $gname ($GUARANTEED_WORKDIR)"
  fi
done

# After guaranteeing the above there is always a registry; guard defensively anyway.
[ -f "$REGISTRY" ] || { echo "$(date -Is) no registry after seeding — nothing to start"; exit 0; }

# Recreate every registered session (resume if it has a transcript, else create).
while IFS=$'\t' read -r name workdir sid; do
  [ -z "${name:-}" ] && continue
  case "$name" in \#*) continue ;; esac
  [ -z "${workdir:-}" ] && workdir="$DEFAULT_WORKDIR"
  [ -z "${sid:-}" ] && sid="$(rc_new_uuid)"
  rc_launch "$name" "$workdir" "$sid"
done < "$REGISTRY"
