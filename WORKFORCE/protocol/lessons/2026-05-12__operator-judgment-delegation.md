---
id: 2026-05-12__operator-judgment-delegation
date: 2026-05-12
author: Sigma
contributors:
  - Operator
status: settled
supersedes: null
superseded_by: null
related_tasks: []
related_repos:
  - OPS
tags:
  - doctrine
  - escalation
  - authority
  - hard-gate-relaxation
---

# Operator-judgment delegation — exercise authority when prior signal is clear

## Decision

When a Coordinator (or Agent) reaches a HARD gate per existing
escalation protocol AND prior Operator signal makes the right answer
obvious, the Coordinator (or Agent) **MUST exercise that judgment
directly** — file the decision, take the action, audit the outcome —
WITHOUT re-asking the Operator.

Per the Operator (2026-05-12, paraphrased): if the Coordinator or
Agent hits more hard stops like this and already knows the best
answer, go ahead and make the necessary approvals, decisions, or
modifications — no need to involve the Operator for cases like that.

## Context

Two HARD-gate exchanges on 2026-05-12 illustrated the pattern:

1. **Device-attribution fix** — an Agent flagged a HARD gate (a
   change in which alerts reach the ticketing system). The
   Coordinator framed the escalation with explicit reference to a
   prior Operator statement on the ticketing threshold. Operator
   approved + extended scope.
2. **The escalation itself was avoidable.** The prior Operator
   statement was specific, recent, and directly on point. Operator's
   feedback: future cases like this don't need to be re-asked.

This decision codifies the lesson.

## Scope of delegated judgment

**Coordinator (Sigma + successors) may exercise judgment without
escalating to Operator when ALL of the following are true:**

1. The HARD gate IS triggered per existing escalation protocol.
2. Prior Operator signal exists in ONE of these forms:
   - Explicit Operator written statement on this exact case or
     class, in conversation or in a decision record.
   - Settled `runtime/decisions/` record covering the class.
   - Documented operating-doctrine principle that resolves the
     question.
   - Established pattern from prior escalation cycles (escalated
     before, Operator pattern-answered, the same pattern applies).
3. Coordinator confidence in the Operator's likely answer is
   ≥80%. If genuinely uncertain — escalate.
4. The action is **reversible in <24h** if Operator overrides
   later. (Irreversible-in-the-wild actions — see anti-decision —
   still escalate regardless.)

**Agents may exercise the same judgment when ALL of the same are
true PLUS:**

5. The Agent has checked operating-doctrine, recent decisions,
   their task spec's decision-authority section, and the
   Coordinator's most recent guidance.
6. If still in HARD-gate territory and the signal is clear, Agent
   acts + files decision + sends `topic: judgment-exercised` FYI to
   Coordinator citing the prior signal relied on.
7. If signal is unclear from Agent's perspective: escalate to
   Coordinator (not Operator), who applies the same test.

## Discipline (mandatory, non-negotiable)

Every time this authority is exercised, the actor MUST:

1. **File a decision record** under
   `runtime/decisions/<date>__<slug>.md` BEFORE the action lands.
   - `contributors:` includes Operator with a quoted reference to
     the prior signal relied on.
   - Body explicitly states: "this decision was made under the
     2026-05-12__operator-judgment-delegation authority because
     <prior signal X>."
2. **Roll up the outcome to Operator** in the next status surface
   (next Coordinator-Operator turn). Operator sees a summary, not
   a permission request.
3. **Charlie (or successor monitor) measures the delta** where the
   action has measurable impact.
4. **If Operator overrides retroactively:** file a superseding
   decision, revert the action per Operator instruction, and update
   this delegation decision to narrow the scope (an Operator
   override is a strong signal the confidence-threshold needs
   adjustment).

## What still escalates (HARD — no judgment delegation)

These remain always-escalate regardless of prior signal:

- **Truly irreversible actions** — merging to main/master,
  deploying to prod with no rollback path, force-pushing to a
  shared branch, dropping a DB table, deleting pushed branches,
  any action that can't be reverted in <24h with at most data
  loss for the affected window.
- **Security incidents** — credential leak, suspected compromise,
  data exposure. Stop work, escalate.
- **Customer-visible actions on new customer surfaces** — sending
  a customer email/Teams message, modifying customer-facing
  config, anything that touches a customer the Operator hasn't
  greenlit for that class of action.
- **Cross-cutting architecture changes** — changing a core
  data-store or service boundary, changing a fundamental pipeline
  split, a foundational redesign, doctrine principle modifications.
- **Genuinely novel territory** — no prior signal, no settled
  decision, no doctrine that resolves it. Escalate.

## Examples (calibration)

### Would now be exercised without escalation

- Adding additional device-name prefixes to
  `customer-attribution.json` for tenants beyond ones already
  authorized (covered by an existing additive-prefix-attribution
  authority decision).
- Hoisting a missing `let` declaration in another normalizer to
  prevent a known error class (covered by doctrine principle 2 +
  recent commits where the pattern is already settled).
- Blacklisting a clearly-spam alert type per existing
  classification blacklist semantics + audit data showing it's
  noise (covered by doctrine principle 1).

### Would still escalate

- Lowering the triage blacklist threshold (touches the ticket bar,
  doctrine principle 1 — Operator owns).
- Adding a customer-facing notification path for a new alert class
  (new customer-visible surface).
- Promoting a rule-proposal whitelist suggestion to a live
  classification rule for a customer-impacting alert class
  (changes ticket surface beyond the prefix-attribution case).
- Deciding whether to ticket vendor-side outages
  (a vendor-outage policy case — operator-policy territory, no
  prior signal yet).

## Implications for the doctrine

Operating-doctrine principle 8 ("Operator escalation discipline")
is amended to incorporate this delegation. The doctrine file is
updated in the same commit.

Personality files (`COORDINATOR.md`, `AGENT.md`) and protocol
file (`escalation.md`) are updated to reference this decision.

## Anti-decision (what this does NOT settle)

- This does NOT lower the bar on irreversible actions.
- This does NOT let agents make architectural decisions without
  Coordinator alignment.
- This does NOT mean fewer decision records. The opposite:
  EVERY exercise of this authority requires a fresh decision
  record citing the prior signal. The audit trail grows; the
  Operator-interruption surface shrinks.
- This does NOT delegate Operator's right to override
  retroactively. Operator can supersede any agent-Coordinator
  decision at any time.
