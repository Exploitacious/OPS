#!/usr/bin/env bash
# git-guard.sh — PreToolUse(Bash) hook: machine-enforces the doctrine's hard
# gates (operating-doctrine P3/P6) that used to be prose-only. Under the
# full-autonomy standing order (2026-07-06) no human sits between plan and
# merge, so the named bans must be mechanical:
#
#   BLOCKED (exit 2 — Claude gets the reason and must surface to operator):
#     git ... --no-verify / --no-gpg-sign      (commit-hook bypass ban, P6)
#     git push --force / -f / --force-with-lease (history overwrite, P3)
#     git ... filter-branch / filter-repo       (history rewrite, P3)
#     git branch -D / push --delete on a remote (deleting possibly-unmerged
#                                                work; -d lowercase is safe)
#     rm -r/-f targeting protected roots        (~/OPS, ~/linuxploitacious,
#                                                ~/.claude as WHOLE trees)
#
# NOT blocked: normal push/merge/commit (autonomy default), rebase of local
# unpushed work, rm inside scratch/tmp. Operator escape hatch for a
# deliberately-approved action: GIT_GUARD=off <command>  (or approve in chat
# and export for the one call). Read-only otherwise; exit 0 = allow.
set -uo pipefail

[ "${GIT_GUARD:-on}" = "off" ] && exit 0

CMD="$(python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if d.get("tool_name") != "Bash":
    sys.exit(0)
sys.stdout.write((d.get("tool_input") or {}).get("command") or "")
' 2>/dev/null)" || exit 0
[ -n "$CMD" ] || exit 0

deny() {
  {
    echo "git-guard: BLOCKED — $1"
    echo "This is a doctrine hard gate (P3/P6): it requires the operator's explicit,"
    echo "per-action approval. Surface the need + reason to the operator; on approval,"
    echo "re-run the single command prefixed with GIT_GUARD=off."
    echo "If the operator is not actively responding in this session, send a"
    echo "PushNotification NOW naming this blocker and the decision needed — a blocked"
    echo "autonomous run must never wait silently (foreman-charter § Full-autonomy)."
  } >&2
  exit 2
}

# git must sit at a command position (line start or after | ; & && ||, with
# optional env-var prefixes) — prose that merely MENTIONS a banned flag inside
# a quoted string must not trip the guard. For the git checks we also strip
# quoted spans first (real git flags are never quoted; commit messages and
# echo strings are) — the rm check below keeps the RAW string because rm
# targets legitimately appear quoted.
GITPOS='(^|[|;&][|&]?)[[:space:]]*([A-Z_]+=[^[:space:]]*[[:space:]]+)*(command[[:space:]]+)?git[[:space:]]'
CMD_RAW="$CMD"
CMD="$(printf '%s' "$CMD" | sed -e "s/'[^']*'//g" -e 's/"[^"]*"//g')"

if printf '%s' "$CMD" | grep -qE "${GITPOS}[^|;&]*(--no-verify|--no-gpg-sign)"; then
  deny "commit-hook bypass (--no-verify/--no-gpg-sign) is banned (P6 named ban)."
fi

if printf '%s' "$CMD" | grep -qE "${GITPOS}[^|;&]*push[^|;&]*(--force(-with-lease)?([[:space:]]|$|=)|[[:space:]]-f([[:space:]]|$))"; then
  deny "force push detected — history overwrite is operator-gated (P3)."
fi

if printf '%s' "$CMD" | grep -qE "${GITPOS}[^|;&]*(filter-branch|filter-repo)"; then
  deny "history rewrite (filter-branch/filter-repo) is operator-gated (P3)."
fi

if printf '%s' "$CMD" | grep -qE "${GITPOS}[^|;&]*push[^|;&]*(--delete|[[:space:]]:[^[:space:]])" \
   || printf '%s' "$CMD" | grep -qE "${GITPOS}[^|;&]*branch[^|;&]*[[:space:]]-D([[:space:]]|$)"; then
  deny "branch deletion (-D / push --delete) may destroy unmerged work — operator-gated (P3). Lowercase -d (merged-only) is allowed."
fi

if printf '%s' "$CMD_RAW" | grep -qE '(^|[|;&][[:space:]]*)rm[[:space:]]+(-[a-zA-Z]*[rf][a-zA-Z]*[[:space:]]+)+("?\$HOME"?|~|/home/[a-z]+)/?(OPS|linuxploitacious|\.claude)?("|/)?([[:space:]]|$)'; then
  deny "recursive/forced rm aimed at a protected root tree (OPS / linuxploitacious / .claude) — operator-gated."
fi

exit 0
