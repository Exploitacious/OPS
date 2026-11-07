#!/usr/bin/env bash
# lane-rules.sh: puts a short shell-rule block in front of agent lanes. It prints
# nothing for a foreman session.
#
# Registered twice in the Stage-1 settings.json (OPS never writes that file, so
# the owner of the Stage-1 settings adds the entries; DEPLOYMENT.md, "a new hook
# means registering it in the Stage 1 settings.json"):
#   SubagentStart  an in-process lane (Agent tool, workflow lane) is starting; the
#                  block goes in as hookSpecificOutput.additionalContext, the only
#                  channel Claude Code reads for this event.
#   SessionStart   a T3-delegated lane starts as a whole top-level session; the
#                  block goes out as plain stdout, like every other SessionStart
#                  hook. bin/lane-class decides: only a lane gets it, a foreman
#                  gets nothing. Also on resume and compact, where the hook's
#                  output is injected again.
#
# Why. Lanes repeat the same few shell stumbles: `sleep N; check` refused by the
# Bash tool, compound commands refused in an isolated worktree, `pkill -f` matching
# the lane's own shell (the kill takes the caller down, exit 144, and it can hit a
# sibling lane too), `bash` typed for the `Bash` tool, an `rm -rf` of an unset
# variable, and MCP tools called without being selected again after a compaction
# dropped their schemas. Each one is usually in a memory note already, and lanes
# never load memory: an in-process lane gets the core rules and nothing else, and a
# T3-delegated lane gets the foreman boot, which is the wrong content. A note did
# not stop a measured stumble; changing what fires does. This is context injected
# at lane start, not a command gate: nothing here refuses or rewrites a command.
#
# Agent definitions (agents/ops-worker.md and the other lane agents) may carry the
# same block in their bodies. The hook skips an agent whose installed definition
# already carries the whole block, so those lanes do not get it twice; any other
# agent type, including the built-ins, gets it from here. A stale deploy whose
# definition lacks the block still gets it from the hook.
#
# One source of truth: this file holds the text. `--block` prints the bare block
# (no envelope), which bin/tests/lane-rules-test.sh compares to any agent
# definition that carries it.
#
# Fails open: any error prints nothing and exits 0, always.

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

block() {
  cat <<'EOF'
Lane shell rules (each prevents a refusal or a self-kill seen in real lane sessions):
- Never "sleep N; check". Wait with ~/OPS/.claude-config/bin/await --timeout SEC -- <check>, a Monitor until-loop, or run_in_background.
- In an isolated worktree (a path under /.claude/worktrees/) run one simple command per call and use git -C <worktree>; no cd chains, compound commands, time, subshells or heredoc-fed bash. For several steps, Write a script and run bash <literal path>.
- Never pkill -f, pgrep -f or killall by pattern (self-kills; it also hits sibling lanes). Kill an exact PID you recorded, or use ~/OPS/.claude-config/bin/safe-pkill.
- The tool is Bash, capital B.
- After a compaction, load a deferred MCP tool with ToolSearch select:<exact name> before its first call; copy names, never type them.
- rm -rf of a variable path: print and check the path first, then use "${VAR:?}" or a literal path.
EOF
}

case "${1:-}" in
  --block) block; exit 0 ;;
esac

# --- the hook ----------------------------------------------------------------
PAYLOAD=""
if [[ ! -t 0 ]]; then PAYLOAD="$(cat 2>/dev/null || true)"; fi
[[ -r "$HOOK_DIR/hooklib.sh" ]] && . "$HOOK_DIR/hooklib.sh"
command -v hook_field >/dev/null 2>&1 || exit 0

field() { printf '%s' "$PAYLOAD" | hook_field "$1" 2>/dev/null || true; }
EVENT="$(field hook_event_name)"
BLOCK="$(block)"

# Does this agent type's definition already carry the block? (Deployed agents are
# the checkout's agents dir through a symlink, so the hook's own checkout is read
# too.)
carries_block() {
  local t f text
  t="$(printf '%s' "$1" | tr -cd 'A-Za-z0-9_.-')"
  [[ -n "$t" && "$t" = "$1" ]] || return 1
  for f in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/agents/$t.md" "$HOME/.claude/agents/$t.md" "$HOOK_DIR/../agents/$t.md"; do
    [[ -r "$f" ]] || continue
    # The first installed definition wins. A newer source copy must not hide a
    # stale installed agent, and a matching heading alone is not the whole block.
    text="$(cat "$f" 2>/dev/null)" || return 1
    [[ "$text" == *"$BLOCK"* ]]
    return $?
  done
  return 1
}

emit_envelope() {  # emit_envelope <event name>: the block as additionalContext JSON
  local py
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg ev "$1" --arg ctx "$BLOCK" '{hookSpecificOutput: {hookEventName: $ev, additionalContext: $ctx}}' 2>/dev/null && return 0
  fi
  py="$(hook_python 2>/dev/null)" || return 0
  "$py" -c 'import json, sys; print(json.dumps({"hookSpecificOutput": {"hookEventName": sys.argv[1], "additionalContext": sys.argv[2]}}))' "$1" "$BLOCK" 2>/dev/null
}

case "$EVENT" in
  SubagentStart)
    carries_block "$(field agent_type)" && exit 0
    emit_envelope SubagentStart
    ;;
  SessionStart|"")
    # The class comes from lane-class, which reads the payload on stdin. A
    # missing script degrades to foreman, which prints nothing.
    CLASS="$("$HOOK_DIR/../bin/lane-class" <<<"$PAYLOAD" 2>/dev/null || echo foreman)"
    case "$CLASS" in
      t3-lane|agent-lane) printf '%s\n' "$BLOCK" ;;
    esac
    ;;
esac
exit 0
