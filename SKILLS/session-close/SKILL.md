---
name: session-close
description: "Use when the Operator says \"close this session\", \"close this out for good\", \"shut this session down\", \"end this session permanently\", \"we're done with this session\", \"close out for the day\", or \"I'm done working\". Permanently closes a Claude Code session end to end: closeout synthesis (work committed, docs matching reality, memory captured, nothing hanging), then the WIP and work-tracking reconciliation gate (reconcile what the session did against your ticketing / time / board systems per CONTEXT/work-tracking.md: log time, advance the card, flag blockers, or draft the entry when no tool is wired), then deregister from the reboot-resume registry and tear down its tmux session. NOT for pausing (that is a closeout plus /compact via pre-compact-synthesis, no reconciliation) and NOT for moving work elsewhere (that is session-handoff). Close means documented, reconciled, archived, gone."
---

# Close a session, permanently and cleanly

Permanently end a finished session: document it, reconcile it, archive it, tear it down. Three endings exist in this harness; pick the right one first.

| Ending | Meaning | Skill |
|--------|---------|-------|
| Pause | Same session continues after a `/compact` | `pre-compact-synthesis` |
| Move | Work continues in another session, profile, or machine | `session-handoff` |
| Close | The session's purpose is done: document, archive, tear down | this skill |

Close is for a finished purpose, not a finished day. If real work is still in-flight, say so and offer handoff or compact instead. A close with open threads is a future archaeology dig.

The reconciliation gate in step 2 is the point of this skill. It is the operator's primary way of entering time and tracking WIP, so it runs on every close as a firm forcing function: skip an item only with a reason the operator gives, never silently. It runs identically on any profile; the reconciliation decides billable versus personal per item.

## Flow

### 1. Closeout synthesis (the four-artifact pass)

Run the full hygiene checklist from `pre-compact-synthesis`, everything except its final `/compact` (you are closing, so its "pause or close?" question is already answered).

- Git: every touched repo committed and pushed; working trees clean, or deliberately dirty with the operator's knowledge. Name what you leave.
- Docs match reality: README, CHANGELOG, and lessons files updated for what this session shipped, in the same pass, not "later".
- Memory: durable lessons, decisions, and feedback written to the memory pool, one fact per file, indexed. Then evict what this close terminates: per foreman-charter section "Eviction", fold a closing project's entries into `CONTEXT/projects/<project>-lessons.md` and delete them, index lines too, no stubs.
- Tasks: the session's task list is resolved, completed or re-homed with the operator's sign-off. Nothing silently abandoned.
- Leftovers: if a genuinely open thread survives all of the above, write a handoff baton (`session-handoff` WRITE). A clean close usually needs none.

### 2. WIP and work-tracking reconciliation (the gate)

Make the tickets, time, and boards reflect what this session did, before the session is gone. Read `CONTEXT/work-tracking.md` for the operator's time, ticketing, and board tools plus their fixed args. If that file is absent, still reconcile: draft the entry text and remind the operator to log it, per its "If nothing here is configured" block. Write nothing to an external system without their OK.

A. Assemble the work picture; do not ask the operator to remember it. The session's activity is on disk. Reconstruct it scoped to what THIS session touched, because a box can run concurrent sessions and crons that commit on their own and would attribute to the wrong item. See `mechanics.md` for the scoped work-picture command and the leftover-stamp backstop. Commits are candidates, not attributions: the highest-confidence signal is the uncommitted working tree plus the work-log narrative, so lead with those and use commits only to corroborate. Compute minutes from the transcript per the standard in `work-tracking.md`, never guess or round.

B. Resolve each touched work area to a candidate item. Consult the repo-to-item map named in `work-tracking.md` for a hint, then confirm it is the right OPEN item. A repo is not 1:1 with an item; phase-scoped work spawns new ones. Confirm, never auto-pick. Check what is already logged today so a day captured elsewhere is not double-logged.

C. Present the table and offer in one prose block; the operator can pick any combination. Show a compact reconciliation table, then let the operator pick what to apply:

```
This session: Xh wall / Yh git-active (t0 to now)
 repo/area          -> item / card                 logged today  proposed
 example-webapp     -> TCK-1042 Webapp work          0.0h         log 1.93h
 (board card 50%)                                                 advance card -> Active
```

Offer, per resolved item (the operator authorizes each): log time as one well-formatted entry via the configured tool; advance the board card as a separate write; update the personal task tracker; flag a blocker with a naming note instead of advancing; or skip with a reason the operator names. No tool configured for a surface means draft the text for the operator to paste.

D. No open item for the work? File one first. New labor without a tracked item is a process bug: open the item under the right board theme, then log against it. Never log orphaned labor. Never terminally close an item on the operator's behalf.

E. Execute, verify, learn, stamp.
- Execute only the writes the operator authorized.
- Read every time entry back before calling it logged; the write response echoes the request, not the stored result. The receipt quotes the stored number. The read-back and same-day fix path are in `work-tracking.md`.
- Learn-on-confirm: a new repo-to-item association the operator confirms gets appended to the map in `work-tracking.md`, tagged `(learned <date>)`.
- Stamp the outcome and clean up the session state (see `mechanics.md`); a later revive is a new work session and must not inherit this one's stamp.

Non-billable is still loggable: internal or overhead items take entries for tracking; personal work takes none by default. If the scan finds nothing to reconcile, say so in one line, then still run all of step E; skipping the cleanup false-flags this clean close as abandoned-unreconciled at the next boot.

### 3. One decision from the Operator

Ask in prose (two options):
- Archive (default): the registry row moves to the archive file. It stops returning on reboot but keeps its session-id, workdir, and profile; `archive-remote-claude.sh revive <Name>` brings it back with full history.
- Forget: deregister entirely, no archive row. The transcript still exists on disk (`claude --resume` finds it by id), but the harness stops tracking it.

### 4. Deliver the closeout receipt

Report BEFORE teardown; step 5 ends this session mid-breath and nothing printed after it arrives anywhere. The receipt names what was committed and pushed (repos plus short SHAs), what memory and lessons were written, what docs changed, the WIP and work-tracking outcome (hours logged with item numbers, cards advanced, tasks updated, or what was declined and why), any baton written, and the revive command if archived.

### 5. Last act: teardown (final tool call of the session)

Deregister and tear down the tmux session. The dead-pane hazard that can kill a sibling session, and the not-in-tmux case, are in `teardown.md`. This kills the session you are in, so make it the absolute last tool call, after the receipt is out.

## Notes

- Closing never deletes history. Registry rows are pointers; transcripts live under the profile's `projects/` dir untouched.
- A remote-controlled session disappears from the operator's claude.ai device list when its tmux dies. Expected, part of "gone".
- To close a DIFFERENT session by name (not the one you are in), skip steps 1 and 2; you cannot run another session's closeout or reconcile its work-tracking from here. Warn that its in-session state is whatever it is, then archive or forget its row. Prefer telling the operator to run the close from inside that session so its gate fires.
