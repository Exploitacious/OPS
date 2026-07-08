# Protocol — Escalation

When and how to pull the Operator into the loop. The default is:
don't. Operator wants to be hands-off until direction or scope
clarity is needed. Escalation is a real cost — burning Operator
attention on a routine question is worse than picking reasonably
and documenting the choice in a decision record.

The doctrine governing this lives in
`~/OPS/CONTEXT/operating-doctrine.md` principle 8. The triggers
below are the operationalized form of that principle.

**Before any escalation:** apply the judgment-delegation test from
`runtime/decisions/2026-05-12__operator-judgment-delegation.md`.

1. Is prior Operator signal on this question or class clear (≥80%
   confidence in the likely answer)? Sources: doctrine, settled
   decisions, recent conversation, task spec.
2. Is the action reversible in <24h if Operator overrides later?
3. Is it OUTSIDE the truly-irreversible / security / new-customer-
   surface / cross-cutting-architecture / genuinely-novel buckets?

If all three are yes: **exercise judgment**. File a decision record
citing the prior signal. Take the action. Surface the outcome in
the next rollup. Do NOT re-ask the Operator.

If any answer is no: escalate per the triggers below.

---

## Escalate when

### Always escalate (no exceptions)

1. **Irreversible action incoming.** An agent is about to merge to
   main/master, deploy to prod, force-push, drop a DB table,
   delete pushed branches, run unfiltered DELETE on a prod DB, or
   make any prod config change that can't be reverted in <5 min.
   Full list in `AGENT.md` "Irreversible actions (HARD GATE)"
   section. Operator must approve in conversation.
2. **Change touches a core operating principle.** Ticket bar,
   blacklist bias, dedup placement, customer-data handling, any
   doctrine principle. These need Operator alignment before
   shipping.
3. **Customer-visible behavior change.** New notification path,
   suppressing what could be a real signal, modifying a
   customer-facing rule. Customers feel these; Operator decides.
4. **Security issue.** Suspected credential leak, prod outage,
   data exposure. Stop work. Escalate. Operator decides next step.
5. **Two agents (or Coordinator + agent) disagree** and neither
   will yield, AND the disagreement blocks forward motion. Document
   both sides in the escalation message.

### Escalate after trying

4. **Scope ambiguity** that can't be disambiguated from the task
   spec, `CONTEXT/`, or recent decisions. Write up the ambiguity
   in concrete options. Don't ask "what do you want?" — ask "is it
   A, B, or C, and here's why I think B?"
5. **Task blocked >60 min** with no resolution path. The blocker
   is real and there's nothing else for the agent to switch to.
6. **Cross-cutting scope change** that would expand the original
   task beyond what the Operator approved. New scope = new task,
   new approval.

### Surface but don't block on Operator

These go in the next status rollup or as a `priority: normal`
message to operator inbox. They're informational, not blocking.

- Bug found AND fixed cleanly AND the fix matches an existing
  pattern (e.g., today's `customerName` hoist matched the
  established `user` hoist pattern — surface but don't block).
- Audit anomaly that's informational (e.g., a new alert type
  appeared but was correctly classified).
- New normalizer or routing pattern discovered + documented.

### Do not escalate for

- Status check (Operator will ask).
- Tactical execution choices (which library, which jq query, which
  Python idiom).
- Routine doc updates or refactors of internal tools.
- Preference between two equivalent approaches — pick one, file a
  decision, move on.
- A failed test (unless it indicates scope ambiguity or busted
  infrastructure).
- An agent going stale — mark stale, continue.
- Routine inter-agent coordination — that's what the inbox is for.
- A judgment call the personality file already settled.

---

## How to escalate

### From an Agent

Send a message to `runtime/inbox/operator/` with:

```yaml
---
id: <ts>__<from>__escalation-<slug>
from: Bravo
to: operator
ts: <UTC ISO>
topic: escalation-<short-slug>
refs:
  - <relevant PRs / task ids / decision records>
awaits: null
priority: urgent
in_reply_to: null
---

# [ESCALATION] One-line problem statement

## What I was doing
One paragraph. The task, where I am in it, what was working.

## What's blocking me / what I need from you
Specific. Concrete. Listed.

## Options (if applicable)
- A: <option> — pros, cons
- B: <option> — pros, cons
- C: <option> — pros, cons

I recommend: <one of them> because <reason>.

## What I'm doing while I wait
- Pivoting to <other task> | Pausing
- Pulse status set to <state>
```

Then:
- Update task `status: needs-direction` (if scope) or `status: blocked`
  (if dependency).
- Update your pulse: `current_task` unchanged, `notes` field
  references the escalation id.
- Update manifest: `status: blocked`.
- Pivot to another task if assigned, otherwise set `status: ready`
  and stop.

**You do not block the conversation waiting for the Operator's
reply.** If the Operator is in conversation, they'll see your
escalation when they ask for status or when you mention it. If
they're not, they'll see it in the inbox when they check.

### From the Coordinator

Same format but `from: Sigma`. Coordinator escalates either:

- On their own when they spotted an issue across agents (most
  common).
- On an agent's behalf, summarizing what the agent reported.

Coordinator typically surfaces the escalation in the next status
rollup to the Operator in addition to writing the message file.
The message file is the audit trail; the conversational rollup is
the timely signal.

---

## Operator's response patterns

The Operator might:

- Reply in conversation: "Go with B." → Coordinator (or you, if
  no Coordinator) records the decision in
  `runtime/decisions/<date>__<slug>.md`. Update the task status.
  Resume work.
- Reply by writing a message to the agent's inbox (rare, but
  possible if the Operator wants to bypass the Coordinator).
- Ignore and keep working on something else. Means: still
  thinking. Don't bug them.
- Resolve by closing the task with `status: cancelled` and a
  reason. Work stops.

---

## What the Operator's inbox looks like

`runtime/inbox/operator/` accumulates escalations + significant
state changes that agents want the Operator to see.

The Operator can check it manually:

```bash
ls -lt ~/OPS/WORKFORCE/FLEETPROJECTS/<project>/runtime/inbox/operator/
```

When the Coordinator is active, the Coordinator drains this inbox:

1. Reads each unread message.
2. Surfaces urgent items in the next conversational rollup.
3. Moves processed items to `runtime/archive/operator/`.

The Operator never has to read individual message files unless they
want to. The Coordinator's job is to summarize.

When there's no Coordinator, the agent that wrote the escalation
also surfaces it in conversation when it sees the Operator next.

---

## Anti-patterns

- **Escalation spam.** Asking the Operator three small questions
  in 10 minutes. Batch them. Or pick one and move on with a
  decision record.
- **Pre-emptive escalation.** Escalating before trying. The
  Operator is final reviewer, not first-resort.
- **Vague escalation.** "I'm not sure how to proceed." Don't.
  Frame the ambiguity with options. Recommend one.
- **Stealth escalation.** Writing the message but not setting the
  task status correctly. The state should be self-consistent — task
  status reflects the blocker, manifest reflects the agent state,
  message captures the ask.
- **Coordinator-bypass escalation.** When a Coordinator is active,
  agents escalate through the Coordinator, not directly to
  Operator, unless the Coordinator is itself the issue (in which
  case file the escalation in `inbox/operator/` and add a copy to
  `inbox/Sigma/` so the Coordinator knows).

---

## Examples

### Good escalation (scope ambiguity)

> # [ESCALATION] Task `phase2-scorer` — shadow window length unclear
>
> ## What I was doing
> Building the v2 scorer per `tasks/phase2-scorer.md`. Acceptance
> criteria says "shadow for 10 days before cutover." Spec doesn't
> say what shadow validation looks like.
>
> ## What I need from you
> A definition of "shadow validation passes."
>
> ## Options
> - A: Match v1 within 5%. Simple, but masks intentional v2
>   improvements (some divergence is the point).
> - B: Match v1 on `clear-cut` cases (severity > 8 or < 3); allow
>   divergence on mid-band. Captures intent; harder to script.
> - C: No quantitative gate, just spot-check the daily report and
>   make a judgment call at day 10.
>
> I recommend B. It's the right shape for the design intent.
>
> ## What I'm doing while I wait
> Building the scorer itself. The shadow validation is downstream.
> Pulse: working, current_task unchanged.

### Bad escalation

> # Need help
> Stuck on the scorer. What should I do?

No context, no options, no recommendation. Operator can't action
this.
