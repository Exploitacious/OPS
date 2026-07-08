---
id: 2026-05-13__ac-spawn-paste-buffer-bug
date: 2026-05-13
filed_by: Captain
status: deferred
scope: cross-cutting
affects:
  - ac-spawn
  - fleet-bootstrap
operator_review: deferred
deferred_reason: |
  Surfaced + filed during memory-sync build session. Operator was
  looped in on the bug but did not authorize a fix this session.
  Workaround (manual second Enter) is documented. Auto-promotes
  to protocol/lessons/ via scope-aware close-out so the next
  session picks it up if Operator decides to ship the fix.
tags:
  - bug
  - tmux
  - spawn-reliability
---

# ac-spawn — paste-buffer fails to submit brief on first Enter

## Symptom

Observed 2026-05-13 spawning Bravo[memory] for the memory-sync task. `ac-spawn` reported success (`[ac-spawn] launched window: ClaudeAgents:Bravo-memory`), tmux window was created, claude CLI started cleanly. But after 4+ minutes, `tmux capture-pane` showed:

- claude CLI prompt rendered (`❯` visible)
- input box EMPTY
- `4m 22s total · 0s api` — session active but no API calls made
- log.jsonl shows the spawn event but NO subsequent `activate` event from Bravo

The brief had been pasted into the input box (claude shows it as `[Pasted text #1 +1 lines]`) but `send-keys Enter` triggered the **paste-preview confirmation**, not a submit. Bravo's CLI was sitting waiting for a SECOND Enter to actually submit.

Manual recovery: send Enter once more. Bravo immediately started synthesizing and proceeded with activation.

## Root cause

Claude Code v2.1.140 input behavior: when text is pasted via tmux paste-buffer, it appears as a `[Pasted text #N +M lines]` preview pill. Pressing Enter at this point **expands the preview** (shows the full text inline). A SECOND Enter is needed to actually submit.

`ac-spawn` lines 158-162:

```bash
tmux load-buffer -b "$BUFFER_NAME" "$BRIEF_PATH"
tmux paste-buffer -b "$BUFFER_NAME" -t "$TARGET"
sleep 1
tmux send-keys -t "$TARGET" Enter
tmux delete-buffer -b "$BUFFER_NAME" 2>/dev/null || true
```

Single Enter triggers the preview confirmation. Brief never submits. Spawned agent sits indefinitely with no API calls, never activates, never sends hard-rules-acked, never picks up its task. The Coordinator sees the spawn event in the log but no activation event — looks like a silent stall.

## Severity

**HIGH for fleet-bootstrap reliability.** Every Path A spawn this session would have silently stalled without manual intervention. Operator-visible failure mode: "the spawned agent never does anything." Coordinator-visible: log shows spawn but no activate; manifest shows the old `idle` status from the previous registration; no inbox traffic.

Detection: silent — no error from ac-spawn (it exits 0 after the paste step). Coordinator has to manually check tmux state to notice.

## Proposed fix

Replace single Enter with double Enter, with a short sleep between:

```bash
tmux paste-buffer -b "$BUFFER_NAME" -t "$TARGET"
sleep 1
tmux send-keys -t "$TARGET" Enter  # confirm preview pill
sleep 0.5
tmux send-keys -t "$TARGET" Enter  # actually submit
tmux delete-buffer -b "$BUFFER_NAME" 2>/dev/null || true
```

Alternative (more robust): use `claude --append-system-prompt` or `claude --prompt-file` if available in the CLI, bypassing the paste-buffer dance entirely. Verify claude v2.1.140 flags.

## Verification plan

After fix:
1. Spawn a test agent via `ac-spawn --scope <test> --task <test-task>`.
2. Within 30s, `tmux capture-pane` should show "Synthesizing…" or post-activation behavior, NOT an empty prompt + pasted-text-preview pill.
3. Within ~60-90s, `runtime/log.jsonl` should show an `activate` event from the new agent.
4. Within ~2 min, manifest should show new agent's `bound_root` stamped to AC_ROOT.

Negative test: confirm the fix doesn't double-submit anything on a fresh empty prompt (the second Enter on an already-submitted query should be a no-op).

## Anti-decision

- Doesn't fix the broader "spawn might silently fail in other ways" class — only the paste-buffer-preview issue.
- Doesn't add a post-spawn liveness check to ac-spawn itself (worth a separate IDEA — verify activation by polling log.jsonl for the new agent's activate event before exiting).
- Doesn't address Claude Code's UX choice to require Enter twice on paste. That's an upstream design call.

## Workaround until fixed

Coordinator manually delivers second Enter via `tmux send-keys -t ClaudeAgents:<window> Enter` after spawning. This was the recovery used for Bravo[memory] today.
