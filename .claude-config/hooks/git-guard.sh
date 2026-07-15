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
#     bare tmux kill-server / pkill tmux        (kills every session on the
#                                                box, the Operator's included)
#
# NOT blocked: normal push/merge/commit (autonomy default), rebase of local
# unpushed work, rm inside scratch/tmp. Operator escape hatch for a
# deliberately-approved action: GIT_GUARD=off <command>  (or approve in chat
# and export for the one call). Read-only otherwise; exit 0 = allow.
set -uo pipefail

[ "${GIT_GUARD:-on}" = "off" ] && exit 0

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HOOK_DIR/hooklib.sh"

RAW_INPUT="$(cat)"
if ! TOOL="$(printf '%s' "$RAW_INPUT" | hook_field tool_name)"; then
  # No JSON parser (jq/python) available — cannot inspect the command. Fail
  # CLOSED: these are doctrine hard gates (P3/P6) that must NEVER silently
  # disable. On Windows the old `python3 -c` resolved to 127 and `|| exit 0`
  # turned every gate off — that is the exact bug this replaces.
  echo "git-guard: no JSON parser (jq/python) available — cannot verify command; BLOCKING." >&2
  echo "Install jq (a harness dependency), or prefix one approved command with GIT_GUARD=off." >&2
  exit 2
fi
[ "$TOOL" = "Bash" ] || exit 0
CMD="$(printf '%s' "$RAW_INPUT" | hook_field tool_input.command)"
[ -n "$CMD" ] || exit 0

# The documented escape hatch is an inline prefix on the approved command
# (`GIT_GUARD=off <command>`). Hooks run in their OWN process and never
# inherit inline assignments from the tool command, so the env check above
# can only fire if the whole Claude session exports it — honor the prefix
# by inspecting the command string itself. Anchored at the very start of
# the command ONLY, so an approval can't hide mid-pipeline or in a quoted
# string.
case "$CMD" in
  "GIT_GUARD=off "*) exit 0 ;;
esac

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

# Protected-root rm: the home prefix may be $HOME, ~, a Linux /home/<user>, or
# a Git Bash /<drive>/Users/<user> form — Windows sessions must not slip past
# a pattern that only knows /home.
if printf '%s' "$CMD_RAW" | grep -qE '(^|[|;&][[:space:]]*)rm[[:space:]]+(-[a-zA-Z]*[rf][a-zA-Z]*[[:space:]]+)+("?\$HOME"?|~|/home/[a-z]+|/[a-zA-Z]/[Uu]sers/[^/]+)/?(OPS|linuxploitacious|\.claude)?("|/)?([[:space:]]|$)'; then
  deny "recursive/forced rm aimed at a protected root tree (OPS / linuxploitacious / .claude) — operator-gated."
fi

# tmux server protection: a bare `tmux kill-server` — or pkill/killall aimed
# at tmux — takes down EVERY tmux session on the box, including the one the
# Operator's own Claude runs in. Test cleanups must target their sandbox
# server EXPLICITLY on the same command line (`tmux -S <socket> kill-server` /
# `tmux -L <name> kill-server`); an env var set in an earlier Bash call does
# NOT persist and silently retargets the default socket. Explicit -S/-L forms
# pass; the bare form and tmux-wide pkill/killall are blocked.
if printf '%s' "$CMD" | grep -qE '(^|[|;&][[:space:]]*)tmux[[:space:]]+((-f|-c)[[:space:]]+[^[:space:]]+[[:space:]]+)*kill-server' \
   && ! printf '%s' "$CMD" | grep -qE '(^|[|;&][[:space:]]*)tmux[[:space:]]+[^|;&]*-(S|L)[[:space:]]*[^[:space:]]+[^|;&]*kill-server'; then
  deny "bare 'tmux kill-server' kills EVERY session on the box. Target your sandbox explicitly: tmux -S <socket> kill-server."
fi
if printf '%s' "$CMD_RAW" | grep -qE '(^|[|;&][[:space:]]*)(pkill|killall)[[:space:]][^|;&]*tmux'; then
  deny "pkill/killall tmux kills every session on the box — kill your own server via tmux -S <socket> kill-server."
fi

exit 0
