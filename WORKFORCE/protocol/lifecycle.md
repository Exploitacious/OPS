# Protocol — Lifecycle

How agents and the Coordinator join, leave, pause, resume, and
get marked stale. Read this alongside `personalities/AGENT.md`
and `personalities/COORDINATOR.md`.

**Compaction is not a lifecycle event.** Per operating-doctrine
principle 4, compaction preserves identity, tools, and memory. An
agent that goes through compaction stays the same agent — same
manifest entry, same pulse identity, same journal. Recovery is
self-bootstrap via the journal's post-compaction re-orientation
anchor, NOT a name reclaim or a fresh activation. If you find
yourself mid-recovery and uncertain whether you're "still the same
agent": yes, you are. Re-read your journal anchor.

Lifecycle events in this doc cover: activation (join), graceful
deactivation (leave), pause/resume (Operator-initiated), and stale
detection (peer-initiated when pulse age exceeds threshold). None
of those describe compaction.

---

## States

An agent's `status` field (in `manifest.d/<name>.json` and mirrored
in `pulse/<name>.json`) takes one of these values:

| Status | Meaning |
|---|---|
| `ready` | Activated, no current task. Will pick up next assignment. |
| `working` | Has a `current_task`, actively making progress. |
| `blocked` | Has a `current_task` but cannot proceed; see task's `blockers`. |
| `awaiting_review` | Has finished a task; awaiting Operator or Coordinator approval. |
| `paused` | Operator explicitly told the agent to pause. Will not pick up new work. |
| `idle` | Session ended gracefully. Manifest entry retained for audit. |
| `stale` | Pulse older than 30 minutes; assumed offline. |

Coordinator-only states:

| Status | Meaning |
|---|---|
| `active` | Coordinator is up and rolling up status. |
| `paused` | Operator told the Coordinator to pause routing. |
| `idle` | Coordinator ended gracefully. |
| `stale` | Coordinator pulse older than 5 minutes; another may reclaim. |

The Coordinator's stale threshold (5 min) is tighter than an
agent's (30 min) because routing is time-sensitive.

---

## Pulse format

`runtime/pulse/<name>.json`. Overwritten in place via tmp + rename.

```json
{
  "agent": "Bravo",
  "role": "agent",
  "host": "linux-wsl",
  "session_id": "kickoff-2026-05-11",
  "last_seen": "2026-05-11T15:30:11Z",
  "status": "working",
  "current_task": "2026-05-11__phase2-scorer",
  "current_repo": "N8nAutomations",
  "current_branch": "feat/phase2-scorer",
  "active_prs": [{"repo": "N8nAutomations", "number": 72, "status": "draft"}],
  "blocked_on": [],
  "notes": "shadowing v1 scorer for 10 days"
}
```

Update at:
- Session start (during activation).
- Before each major action (PR open, deploy, branch switch).
- Before session end (`status` to `idle` or `stale`).
- Whenever your `current_task` or `blocked_on` changes.

Update is atomic: write to `runtime/tmp/<name>.json`, then
`mv` over `runtime/pulse/<name>.json`.

---

## Activation (join)

See `personalities/AGENT.md` step list. Summary:

1. Read CONTEXT + protocol + name-pool.
2. Read manifest.d.
3. Pick unclaimed name.
4. Write manifest entry (tmp + rename).
5. Initialize pulse + journal + inbox.
6. Greet Coordinator (if any) + Operator.
7. Append `event: activate` to log.jsonl.

Coordinator activation has an extra step: atomic claim of
`_coordinator.json` with conflict check.

---

## Deactivation (graceful leave)

1. Process any remaining inbox messages.
2. If you have a `current_task` in progress:
   - Update the task: `status: in_progress` → `status: <appropriate>`.
     If you genuinely finished and the Operator hasn't reviewed yet,
     set `awaiting_review`. If you stopped mid-task, set `blocked`
     with blocker = "previous assignee (`<self>`) ended session;
     work remaining: <one-line>".
   - Append a journal entry summarizing what's done and what's
     remaining.
3. Update your pulse: `status: idle`.
4. Update your manifest: `status: idle`, `last_seen: <now>`.
5. Append to log:
   ```json
   {"ts":"<now>","actor":"<self>","event":"deactivate"}
   ```
6. Final response to Operator (if any): one-line goodbye + pointer
   to where work resumes.

You do NOT delete your manifest entry. The Operator or Coordinator
decides when to clear it.

---

## Pause (Operator-initiated)

The Operator types something like "pause Bravo" or "all agents
pause." Response:

1. Update your status to `paused` in pulse + manifest.
2. Stop new work. Finish atomic units (don't abandon a half-
   written file), then stop.
3. Append journal entry explaining what state you're in.
4. Append to log:
   ```json
   {"ts":"<now>","actor":"<self>","event":"pause","reason":"operator-request"}
   ```
5. Tell Operator: "Paused at `<state>`. Pulse held. Resume with
   'resume' or 'unpause'."

You do not poll while paused. You wait for the Operator's next
input.

---

## Resume (Operator-initiated)

The Operator says "resume Bravo" or "Bravo, resume." Response:

1. Read inbox sweep (process anything that landed during pause).
2. Read current pulse + task spec.
3. Update status: `working` (or `ready` if no current_task).
4. Append journal entry: "Resumed at `<UTC>`."
5. Append to log: `event: resume`.
6. Tell Operator: "Resumed. Continuing `<task>` from `<state>`."

---

## Mark stale (Coordinator or peer agent)

When another agent or the Coordinator notices `<name>`'s pulse is
older than 30 min (or 5 min for Coordinator):

1. Read their manifest. Confirm `last_seen` matches the pulse — if
   not, the pulse is the source of truth.
2. Write a decision record:
   `runtime/decisions/<date>__mark-stale-<name>.md` — one paragraph
   on what they were doing, why they're being marked stale, what
   happens to their work.
3. Update their manifest entry: `status: stale`.
4. If they had a `current_task` in_progress: change task `status`
   to `blocked` with blocker = "previous assignee (`<name>`) went
   stale at `<their-last-seen>`".
5. Append to log: `event: mark-stale`, `target: <name>`.
6. If Operator is around: mention in next rollup.

Name remains "claimed" until a fresh agent explicitly reclaims it
(see Reclaim).

---

## Reclaim a stale agent's name

A new session wants to claim `Echo` but the manifest shows a stale
`Echo`. Procedure:

1. Confirm `Echo`'s pulse is genuinely stale (`last_seen` > 30 min).
2. Write a decision record:
   `runtime/decisions/<date>__reclaim-<name>.md` with old session
   id, new session id, what work (if any) the old session left
   open.
3. Overwrite `manifest.d/Echo.json` (tmp + rename) with new entry.
4. Overwrite `pulse/Echo.json`.
5. Journal file: keep the old one. Append a separator and start
   fresh:
   ```markdown
   ---
   ## RECLAIMED 2026-05-11T16:00:00Z — new session
   ```
6. Inbox: any old messages addressed to Echo are processed by the
   new Echo as usual. The new Echo can choose to archive without
   action with a journal note.

---

## Operator emergencies (escalation paths)

If the Operator types something like:
- "stop everything" / "all stop" / "halt" → all active agents
  pause immediately (including the Coordinator). State preserved.
- "kill `<name>`" → that agent marks stale + deactivates.
- "clear all" → see `README.md` "How to clear EVERYTHING" section.
  Wipes manifest, pulse, inbox. Preserves audit (decisions,
  archive, log).

Agents respond to these without question. Operator authority is
absolute.

---

## Heartbeat enforcement

Pulse is the source of truth for liveness. If you go a long time
without writing to your pulse, you're treated as stale even if
you're actively typing in conversation. Update your pulse on every
major action and at least every 15 minutes of active work.

If you notice your own pulse is older than 15 min and you're still
working: update it immediately, then continue.

If you notice another agent's pulse is older than 30 min and they
appeared active in recent log entries (you saw them write a
message after their pulse last updated): they probably forgot to
update. Send a `priority: fyi` `topic: pulse-bump-request` message
to them. Don't mark them stale yet.

---

## Cross-machine sessions

Cross-machine = a fleet run continuing on a different host than it
started on. Fleet mechanics are Linux-only (`WORKFORCE/README.md`)
— a Windows host gets OPS context but does not run agents, so
the practical case is Linux-to-Linux. Implications:

- The entire per-project `runtime/` tree — `inbox/`, `pulse/`,
  `tmp/`, `journal/`, `manifest.d/`, `tasks/`, `decisions/`,
  `archive/`, `log.jsonl` — is `.gitignore`'d and machine-local.
  None of it syncs via `git pull`. Only the fleet system itself
  (`personalities/`, `protocol/`, `bin/`, `README.md`) is tracked
  and identical across hosts.
- An agent active on host A can't reach an agent active on host B
  in real-time, and `git pull` doesn't bridge them either — there
  is no shared manifest, task ledger, or inbox across hosts.
  Continuity across hosts rides OPS's actually-tracked surfaces
  (`CONTEXT/` docs, auto-memory), not the fleet runtime.
- Recommended pattern: one machine at a time for active fleet work.
  Don't spawn agents on a second host expecting them to see the
  first host's manifest or tasks — they won't be there.

If you must move a project to a new host mid-task: the agent on
host A goes to `status: idle` with a clean handoff written into its
journal AND promoted into `CONTEXT/projects/<project>-lessons.md`
or a memory entry (the only carriers that actually cross hosts). A
fresh agent on host B starts clean — it cannot reference host A's
task-spec file directly, since that file never left host A's disk.
