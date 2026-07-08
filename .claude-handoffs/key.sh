#!/usr/bin/env bash
# key.sh — the single source of truth for the handoff PROJECT KEY.
#
# Emits a stable, filesystem-safe key for the current project so the WRITE
# (session-handoff skill), the READ (same skill), and the notifier
# (handoff-check.sh) all agree on the baton filename and never drift.
#
# Key = git repo toplevel if inside a repo, else the current working dir;
# slashes → dashes, leading dashes stripped. handoff-check.sh inlines this
# same logic as a fallback so a missing/non-exec helper degrades gracefully
# rather than crashing the hook — keep the two in sync if you change it.

set -uo pipefail

root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
printf '%s\n' "$root" | sed 's|/|-|g; s|^-*||'
