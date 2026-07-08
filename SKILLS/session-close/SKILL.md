---
name: session-close
description: Permanently close a Claude Code session, end to end — full closeout synthesis (work committed, docs matching reality, memory captured, nothing hanging), then remove it from the reboot-resume registry and tear down its tmux session. Use when the Operator says "close this session", "close this out for good", "shut this session down", "end this session permanently", "we're done with this session". NOT for pausing (that's a closeout + /compact via pre-compact-synthesis) and NOT for moving work elsewhere (that's session-handoff). Close means: documented, archived, gone.
---

# Close a session — permanently, cleanly

Three session endings exist in this harness. Pick the right one before running
anything:

| Ending | Meaning | Skill |
|--------|---------|-------|
| **Pause** | Same session continues after a `/compact` | `pre-compact-synthesis` |
| **Move** | Work continues in a different session/profile/machine | `session-handoff` |
| **Close** | The session's purpose is DONE. Document, archive, tear down | this skill |

Close is for a finished purpose, not a finished day. If real work is still
in-flight, say so and offer handoff or compact instead — a close with open
threads is a future archaeology dig.

## Flow

### 1. Closeout synthesis (the four-artifact pass)

Run the full hygiene checklist from `pre-compact-synthesis` — everything except
its final `/compact`:

- **Git**: every touched repo committed and pushed; working trees clean or
  deliberately dirty with the Operator's knowledge. Name what you're leaving.
- **Docs match reality**: README / CHANGELOG / lessons files updated for what
  this session actually shipped, in the same pass — not "later".
- **Memory**: durable lessons, decisions, and feedback from this session are
  written to the memory pool (one fact per file, indexed).
- **Tasks**: the session's task list is resolved — completed, or explicitly
  re-homed with the Operator's sign-off. Nothing silently abandoned.
- **Leftovers**: if a genuinely open thread survives all of the above, write a
  handoff baton (`session-handoff` WRITE) so the thread has a home that isn't
  this dying session. A clean close usually needs none.

### 2. One decision from the Operator

Ask (AskUserQuestion, two options):

- **Archive** (recommended default) — the session's registry row moves to the
  archive file. It stops returning on reboot, but keeps its session-id,
  workdir, and profile; `archive-remote-claude.sh revive <Name>` brings it
  back later with full conversation history.
- **Forget** — deregister entirely. Off the boot list with no archive row. The
  transcript still exists on disk (nothing here deletes conversation history;
  `claude --resume` can always find it by id), but the harness stops tracking
  it.

### 3. Deliver the closeout receipt

Report BEFORE the teardown, because step 4 ends this session mid-breath —
nothing you print after it arrives anywhere. The receipt names: what was
committed/pushed (repos + short SHAs), what memory/lessons were written, what
docs changed, any baton written, and the revive command if archived.

### 4. Last act: teardown (final tool call of the session)

**In tmux** (`$TMUX` set) — one command does both registry and tmux:

```bash
# Archive (default): parks the registry row, then kills this tmux session by its
# RAW name. The chained kill matters: the registry stores the NORMALIZED name
# (Title-Case-Hyphen), and rc_archive kills that — a hand-made session with
# different casing (e.g. "harness") survives it, because tmux names are
# case-sensitive. The second kill targets the actual live name; it no-ops if
# rc_archive's kill already landed.
~/OPS/.claude-config/remote-sessions/archive-remote-claude.sh archive "$(tmux display-message -p '#S')"; tmux kill-session -t "$(tmux display-message -p '#S')" 2>/dev/null
```

```bash
# Forget variant: deregister, then kill this tmux session.
source ~/OPS/.claude-config/remote-sessions/lib-remote-claude.sh && \
  rc_deregister "$(rc_normalize_name "$(tmux display-message -p '#S')")" && \
  tmux kill-session -t "$(tmux display-message -p '#S')"
```

This kills the session you are running in — that is the point. Make it the
absolute last tool call; the receipt (step 3) already went out.

- `ERR_GUARANTEED`: the name is in `RC_GUARANTEED_NAMES` — the boot script
  deliberately re-seeds it and archiving would orphan its history. Do NOT
  force it; report to the Operator that guaranteed sessions are closed by
  first removing the name from `RC_GUARANTEED_NAMES` in
  `lib-remote-claude.sh`.
- The auto-register hook respects the archive: reopening a tmux session with
  an archived name will NOT silently re-register it. Revive is always an
  explicit act.

**Not in tmux**: there is no registry row and no tmux to tear down (only
tmux-hosted sessions are boot-registered). Run steps 1-3, then tell the
Operator the close is complete and this terminal can simply be exited.

## Notes

- Closing never deletes history. Registry rows are pointers; transcripts live
  under the profile's `projects/` dir untouched.
- A closed session that was remote-controlled disappears from the Operator's
  claude.ai device list when its tmux dies — expected, part of "gone".
- If the Operator asks to close a DIFFERENT session by name (not the one you
  are in), skip step 1 (you can't run another session's closeout) — warn that
  its in-session state is whatever it is, then archive/forget its row the same
  way. Prefer telling the Operator to run the close from inside that session.
