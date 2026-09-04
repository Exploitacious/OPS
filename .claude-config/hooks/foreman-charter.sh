#!/usr/bin/env bash
# foreman-charter.sh — RETIRED for Claude Code.
#
# The charter now rides the claude() launch shim's --append-system-prompt
# (.claude-config/deploy.sh): it lands in the CACHED system prompt whole and
# survives resume/compact verbatim, which a SessionStart hook's truncated stdout
# could not guarantee. So this hook is no longer registered on the Claude Code
# SessionStart matcher (remove the entry from your Stage-1 settings.json; see
# DEPLOYMENT.md "Hooks and the drift gate"). Leaving it registered would
# re-emit the whole charter through hook stdout AND duplicate what the system
# prompt already carries.
#
# Left in place as an adapter seam: a fork that drives a NON-Claude-Code agent
# (e.g. a Codex adapter) from the same charter can still register it on that
# agent's session start. A Claude-Code-only fork can delete it. If run, it
# still surfaces the single source of truth, CONTEXT/foreman-charter.md.

set -euo pipefail

CHARTER="${HOME}/OPS/CONTEXT/foreman-charter.md"

[ -r "$CHARTER" ] || exit 0

echo "============================================================"
echo " FOREMAN CHARTER — STANDING ORDERS, not background context"
echo " Read and comply every session. This overrides default instincts"
echo " to ration context or defer work (see 'Finish the job' below)."
echo "============================================================"
cat "$CHARTER"
echo "============================================================"

exit 0
