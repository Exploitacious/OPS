#!/usr/bin/env bash
# foreman-charter.sh — SessionStart hook.
# Injects the Foreman Charter into every Claude Code session so the
# foreman operating posture is read in automatically — no "promotion"
# needed. Single source of truth is CONTEXT/foreman-charter.md; this
# hook just surfaces it. Registered first in settings.json SessionStart
# so it lands before the fleet re-orient.
#
# Why a hook and not just CLAUDE.md prose: SessionStart hook stdout is
# injected as context every launch, including resumes and post-compact,
# where the model may not re-read CONTEXT/ on its own. Loud > buried.

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
