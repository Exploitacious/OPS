# Cron prompt templates

Drop-in bodies for self-pacing cron prompts that Captain and Agents
arm at the start of each session. The templates encode the standing
Operator directions so the cron-fire'd turn doesn't drift.

Cron is session-scoped — it dies on compaction. It also
self-terminates independently of any session event: native
`CronCreate` recurring jobs auto-expire 7 days after creation,
compaction or no. Re-arm post-resume per
`personalities/COORDINATOR.md` § Compaction-aware continuity, AND
track the 7-day clock separately (see "Re-arm procedure" below) — a
session that runs quietly for a week without ever compacting still
loses its cron silently.

---

## Why these exist

Direct response to the 2026-05-12 drift incident: cron-cold-fire
caused Captain to run audits (Charlie's job), narrate status to
Operator (forbidden per `runtime/operator-directions/2026-05-12__no-status-narration.md`),
and re-ask known answers (forbidden per
`runtime/operator-directions/2026-05-12__decide-do-not-ask.md`).

The cron body MUST encode these directions; doctrine absorption
post-compact is fragile. The template makes the rules load-bearing
in the prompt itself, not just in re-read order.

---

## Agent self-pacing cron — body

Suggested cadence: off-minute, staggered. Example for Bravo:
`3,18,33,48 * * * *`.

```
SELF-PACING TICK ($AC_NAME). Stoic discipline.

1. Process inbox FIRST. find $AC_ROOT/runtime/inbox/$AC_NAME -mindepth 1 -type f | sort
   For each: ac-msg read; act if actionable; ac-msg archive. Do not idle with unread.

2. Bump pulse. ac-pulse --status <working|idle>. (Required even if no other action.)

3. Advance work:
   - If current_task is in_progress: continue. No status narration to Operator.
   - If current_task complete: set status=awaiting_review, send -shipped/-fixed msg to Coordinator
     (commit-SHA auto-included by ac-msg). Then poll inbox for next assignment.
   - If no assigned task: status=idle. Stop cleanly.

4. NEVER:
   - Render an AskUserQuestion-style interactive prompt (freezes session).
   - Send the Operator a status recap (forbidden per no-status-narration).
   - Re-ask the Coordinator a question whose answer is in
     runtime/decisions/ or runtime/operator-directions/.
   - Edit workflows / source code outside your scope tag.

5. If blocked on an irreversible-action gate: surface to Coordinator
   with framed options + recommendation. Do not act on the gate.

6. Surface to Operator ONLY when: irreversible action ahead,
   scope ambiguity unresolvable by decision/doctrine, OR Operator
   asks. Otherwise stay silent.

End of tick.
```

---

## Coordinator self-pacing cron — body

Suggested cadence: `17,42 * * * *`.

```
COORDINATOR TICK (Captain). Alignment is primary goal.

1. Re-anchor: ac-reorient (silent if no source change since last tick).
   If anything in runtime/operator-directions/ is unread or you cannot
   quote the direction authorizing in-flight work: STOP and re-read.

2. Process inbox FIRST. ac-msg list | head; for each: read + act + archive.
   Reply-class topics: file decision if architectural, route to agent if assignment.

3. Bump pulse. ac-pulse --status active.

4. Fleet check (silent — no narration to Operator unless decision needed):
   - Any agent pulse > 30 min stale? Run intervention ladder per
     runtime/operator-directions/2026-05-12__nudge-discipline.md.
   - Any agent idle AND no assignment? PUSH-AHEAD: assign next task NOW
     (don't wait for next tick) per no-status-narration direction.
   - Any task status=awaiting_review > 2h with no Operator review? Surface ONLY
     if Operator-visible decision required, otherwise leave.
   - Any drift-alert in runtime/improvements/<today>__*.md? Action or annotate.

5. Apply judgment-delegation aggressively. If you have a clear recommendation
   AND the action is reversible <24h AND no irreversible-gate fires: DECIDE.
   File the decision. Do not ask Operator. (Three Operator corrections on this
   2026-05-12 — the rule is load-bearing now.)

6. Surface to Operator ONLY when:
   - Irreversible action ahead (merge main, prod deploy, force-push, drop tables).
   - Genuinely novel scope ambiguity unresolvable by doctrine + decisions.
   - Operator asks for status.

7. Drift indicators to watch in self:
   - Action without trace (cannot quote authorizing source).
   - Re-asking known answers.
   - Agent-shadowing (running audits = Charlie's job, writing code = Bravo's).
   - Implementation-narration to Operator (cron IDs, mechanics, recaps).

End of tick.
```

---

## Operator-touchpoint discipline (the "no status narration" rule)

The cron tick should produce ZERO Operator-facing output by default.
Operator-facing output ONLY when:

| Trigger | Surface |
|---|---|
| Irreversible action ahead | Frame options + recommendation, wait for explicit approval. |
| Scope ambiguity unresolvable by doctrine | Frame options + recommendation, wait. |
| Operator explicitly asks for status | Tight rollup: tasks, agents, decisions, blockers. |
| Drift-alert that requires human call | Surface the alert + your remediation plan. |
| 5h-window / weekly capacity throttling | Surface % remaining + ETA to recovery. |

Everything else stays in the cron-fire'd turn and dies silently.

---

## Re-arm procedure (post-compact, AND on a rolling 7-day clock)

Two independent triggers require re-arming — don't treat this as a
compaction-only ritual:

- **Post-compact.** After SessionStart hook surfaces re-orient banner.
- **Pre-expiry.** Native `CronCreate` recurring jobs auto-expire 7
  days after creation regardless of compaction. Journal the job's
  creation timestamp at arm-time and re-issue BEFORE the 7-day mark
  — don't wait for the tick to simply stop firing and get
  discovered later as an unexplained outage.

Procedure (either trigger):

1. Captain: `CronCreate` with the Coordinator body above, cadence `17,42 * * * *`.
2. Bravo: `CronCreate` with Agent body, cadence `3,18,33,48 * * * *`.
3. Charlie: `CronCreate` with Agent body, cadence `8,23,38,53 * * * *`.

Journal the re-arm (new job ID + timestamp) every time — it's what
recovers the anchor post-compact AND what tells you when the next
7-day pre-expiry re-issue is due.

The cron prompt sentinel is `<<autonomous-loop>>` per ScheduleWakeup
docs — paste the literal sentinel + reference this template by path
so the runtime resolves the body at fire time.
