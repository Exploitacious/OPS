# Self-compact cycle, the automated exit

Read at the exit when the session runs in tmux. `~/OPS/.claude-config/bin/compact-cycle.sh` is a deterministic bash compactor (no Claude inside) that types `/compact` into your pane, waits for compaction to complete, types your resume baton as the next message, then exits, and the compactor's own tmux session self-destructs. You do the judgment (synthesis plus baton); it does the choreography.

This is the DEFAULT exit for every activation in tmux. Wrap-up phrases ("get ready to compact", "do the thing", "wrap up"), the `[context-watch]` nag, explicit asks ("self-compact", "run the full cycle"), and autonomous breaks all end here. Two-phase autonomy: the go is the switch. "Get ready to compact" means run the whole cycle, not prepare and wait for a typed `/compact`. Manual exit is the exception: only when the operator explicitly claimed the `/compact` ("I'll compact myself", "manual", "hold off") or an ASK OPERATOR item is still open (never compact over an unanswered question).

Requires tmux (`[ -n "$TMUX" ]`). Not in tmux, use the manual flow.

## The arming order is absolute

The automation removes the operator's keystrokes; it must NEVER remove the synthesis. A compact that loses knowledge is a failed compact no matter how cleanly the cycle ran. Before spawning the compactor, ALL of the following must be true, in order:

1. The four artifacts are green: git committed and pushed or explicitly deferred by the operator; memory written AND flushed per hygiene step 2; task list true; durable anchor updated with a RESUME PROTOCOL block.
2. Closeout hygiene passed, including docs-reflect-reality: every repo touched this session has its CHANGELOG line and no doc claim made false. "I'll fix the docs post-compact" is the exact failure this gate kills; post-compact-you will not know what is missing.
3. Knowledge-capture completeness check. Ask: did this session produce knowledge faster than it was filed? Long autonomous runs, multi-hour builds, and incident investigations usually do. If yes, run `transcript-mine` with `{since: <last-closeout stamp>}` (stamp: `~/.local/state/ops/last-closeout`) and file what it stages BEFORE arming. Short conversational sessions skip this; call it consciously and say which way in the readiness summary.
4. The readiness summary is printed. Anything unresolved (uncommitted work you lack authorization to push, an ASK OPERATOR item, a failing gate) means DO NOT ARM; surface it and wait.

Only then spawn.

## Procedure

1. Write the resume baton to `~/.claude-compact-cycle/resume-<Key>.txt`, where `<Key>` is the tmux session name sanitized to `[A-Za-z0-9-]`. Let the shared helper derive it: `. ~/OPS/.claude-config/hooks/hooklib.sh; KEY="$(work_session_key)"`. Content: a RESUME PROTOCOL block (format in the body) plus one line of continuation framing. The compactor types this file verbatim as the post-compact session's next user message, so keep it under about 30 lines, NEXT ACTION imperative, zero session-boundary vocabulary. The baton also serves as the context-watch interlock: while it exists and is under 30 minutes old, the hook stays silent.
2. Spawn the compactor (its own detached tmux session, `Compactor-<Key>`). Pass the target session name:

   ```bash
   ~/OPS/.claude-config/bin/compact-cycle.sh --target "$(tmux display-message -p '#S')"
   ```

   It prints `OK compactor spawned...` and returns immediately.
3. End your turn immediately. One short closing line, then stop, no further tool calls. The compactor waits for your pane to go idle (that is why the turn must end), fires `/compact`, watches for completion, types the baton, and dies. Extra tool calls do not break it; idle detection just waits, but each one delays the cycle.

Because the operator may be watching, your closing line must SAY the cycle is armed and how to abort: `tmux kill-session -t '=Compactor-<Key>'` (the lock cleans up on signal).

## Failure behavior

On compaction error or timeout the compactor NEVER types the resume; the session stays paused with all synthesis safely on disk, and `~/.claude-compact-cycle/<Key>.status` plus the matching log capture why. The baton is consumed (renamed `*.sent-<ts>`) only on success. Fleet panes get the same engine via `ac-compact-peer`, which delegates with `--no-resume`; fleet agents re-wake on their `/loop` cron instead of a typed resume.

## Run-dir layout

`~/.claude-compact-cycle/` holds the cycle's state, keyed by `<Key>`:

- `work-log-<KEY>` : mechanical segments (from the hook) plus your narrative lines; session-close reads the whole file.
- `resume-<Key>.txt` : the baton the compactor types; renamed `resume-<Key>.txt.sent-<ts>` on success.
- `memory-flush-queue` : write-time nudges, one line per flagged memory file; drained in hygiene step 2.
- `<Key>.status` : the compactor's exit status and reason on failure.

## Reference sources

- Fleet `ac-pre-compact`: `~/OPS/WORKFORCE/bin/ac-pre-compact`. Read only to debug fleet dispatch.
- PreCompact hook spec: Claude Code docs at `code.claude.com/docs/en/hooks.md`. Read only if the hook misbehaves.
