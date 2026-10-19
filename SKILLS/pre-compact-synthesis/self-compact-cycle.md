# Self-compact cycle, the automated exit

Read at the exit when the host provides a compactor, and for the manual `/compact` instruction. A compactor is a deterministic script (no model inside) that asks the host to run bare `/compact` on this thread, verifies completion, sends your resume baton as the next user message, then exits. You do the judgment (synthesis plus baton); it does the choreography.

OPS ships no compactor that verifies completion. A script that types `/compact` into a terminal pane (the older tmux approach) cannot tell a finished compaction from a failed one, and a baton sent after a failed compact resumes work on a thread whose history was never summarized. Verified completion needs the host's own record of that compact request, which only some hosts expose. A terminal, a multiplexer pane, or a plain CLI session has no such record to verify against, so those sessions always take the manual exit from the skill body: print the readiness summary and the operator fires `/compact`. Never arm a compactor you have not confirmed works on this host.

## The arming order is absolute

The automation removes the operator's keystrokes; it must NEVER remove the synthesis. A compact that loses knowledge is a failed compact no matter how cleanly the cycle ran. Before arming a compactor, ALL of the following must be true, in order:

1. The four artifacts are green: git committed and pushed (the OPS copy only through `origin-private-check`, which the git-guard hook enforces) or explicitly deferred by the operator; memory written AND flushed per hygiene step 2; task list true; durable anchor updated with a RESUME PROTOCOL block.
2. Closeout hygiene passed, including docs-reflect-reality: every repo touched this session has its CHANGELOG line and no doc claim made false. "I'll fix the docs post-compact" is the exact failure this gate kills; post-compact-you will not know what is missing.
3. Knowledge-capture completeness check. Ask: did this session produce knowledge faster than it was filed? Long autonomous runs, multi-hour builds, and incident investigations usually do. If yes, run `transcript-mine` with `{since: <last-closeout stamp>}` (stamp: `~/.local/state/ops/last-closeout`) and file what it stages BEFORE arming. Short conversational sessions skip this; call it consciously and say which way in the readiness summary.
4. The readiness summary is printed. Anything unresolved (uncommitted work you lack authorization to push, an ASK OPERATOR item, a failing gate) means DO NOT ARM; surface it and wait.

Only then arm.

## The baton

Write the resume baton to `~/.claude-compact-cycle/resume-<Key>.txt`, where `<Key>` comes from the shared helper: `. ~/OPS/.claude-config/hooks/hooklib.sh; KEY="$(work_session_key)"`. Content: a RESUME PROTOCOL block (format in the skill body) plus one line of continuation framing. The compactor sends this file verbatim as the post-compact session's next user message, so keep it under about 30 lines, NEXT ACTION imperative, zero session-boundary vocabulary, and state what is DECIDED, PROPOSED, and OPEN. Detailed preservation belongs in the anchor, because a host's native compaction takes a thread, not a preservation prompt.

OPS's context-watch hook has no interlock for a compactor (OPS ships none), so a host compactor that needs the nags silenced while it waits must provide that itself.

## What any compactor must do

- Send exactly `/compact`, with no attachments. Hosts that recognize the command call their native compaction; `/compact <text>` is ordinary chat there.
- Treat a compact as done only on the host's completion record for that request, then an idle provider. An API acknowledgement, a normal completed reply, or an old auto-compaction proves nothing: a provider that is not authenticated "completes" a `/compact` with an error message.
- Send the baton only after that proof. On failure or timeout, retain the baton and read the status and the log. A timeout can mean compaction is still running, so do not blindly retry or restart the provider.
- A thread with nothing to compact is a finished no-op, and the baton still goes out, because you ended your turn to wait for it.

After arming, END YOUR TURN immediately. Do not poll from the target thread, because the worker is waiting for that turn to finish. One closing line says the cycle is armed and how to abort, because the operator may be watching.

## Manual exit on a Claude Code terminal

`/compact <instruction>` takes a preservation instruction. Give the operator this text so a manual compact keeps the same detail an automated one would:

> Be sure to preserve: (1) any difficulties or problems that came up, and how they were handled or resolved; (2) any possibilities, options, or approaches that were raised, tried, or set aside, and why; (3) anything that was asked for, decided, agreed, ruled out, or established as a preference, constraint, or boundary, stated exactly; (4) exactly where things stand now; (5) anything still open, unresolved, promised, or expected to happen next; (6) specific details that would be hard to reconstruct: names, numbers, dates, exact wording, links or references, kept exactly. Weight the two voices differently: keep what the user said, asked for, shared, or established carefully and close to their own words; your own explanations and reasoning can be condensed much further.

Never append this text to a request on a host that sends it as chat.

## Failure behavior

On compaction error or timeout a compactor NEVER sends the resume; the session stays paused with all synthesis safely on disk, and its status file plus the matching log capture why. The baton is consumed (renamed `*.sent-<ts>`) only on success.

## Run-dir layout

`~/.claude-compact-cycle/` holds the cycle's state, keyed by `<Key>`:

- `work-log-<KEY>`: mechanical segments (from the hook) plus your narrative lines; session-close reads the whole file.
- `resume-<Key>.txt`: the baton the compactor sends; renamed `resume-<Key>.txt.sent-<ts>` on success.
- `memory-flush-queue`: write-time nudges, one line per flagged memory file; drained in hygiene step 2.
- `<Key>.status`: the compactor's exit status and reason on failure.

## Reference sources

- PreCompact hook spec: Claude Code docs at `code.claude.com/docs/en/hooks.md`. Read only if the hook misbehaves.
