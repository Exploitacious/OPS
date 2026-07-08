---
id: 2026-05-12__alignment-hardening
date: 2026-05-12
author: Captain (formerly Sigma)
contributors:
  - Operator
status: settled
supersedes:
  - (Sigma Greek-letter coordinator naming, per prior name-pool.md)
superseded_by: null
related_tasks: []
related_repos:
  - OPS
tags:
  - doctrine
  - alignment
  - compaction
  - naming
  - stoic-discipline
  - vessel-hardening
---

# Alignment-hardening batch — SessionStart hook, doctrine
principles 11+12, leadership-title naming, project subdir

## Decision

A bundle of structural changes to the multi-agent system,
authorized by Operator 2026-05-12 across the same session:

1. **SessionStart hook** in `~/.claude/settings.json` runs
   `bin/ac-reorient` on every session start including post-
   compaction resume. Mechanical guarantee that the resumed
   instance re-anchors before responding.
2. **Operator-directions vault** at
   `runtime/operator-directions/<date>__<topic>.md` — verbatim
   Operator quotes + interpretation + standing implications.
   Read FIRST post-compact, before pulse check.
3. **Captain standing-orders** at
   `personalities/captain-standing-orders.md` — cumulative
   "what does the Operator expect right now." Read second
   post-compact.
4. **Operating-doctrine Principle 11 — Stoic discipline.**
   Operate as emotionless stoic military officer. Drop drift
   behaviors (laziness, impatience, ego, panic, anxiety,
   shortcuts). Personality intact; drift behaviors out.
5. **Operating-doctrine Principle 12 — Alignment primacy.**
   Coordinator-Operator alignment outranks every other
   operational concern. Every action traces back to a quoted
   Operator direction, doctrine principle, or settled decision.
6. **Operating-doctrine Principle 10 updates:**
   - Folder structure: `WORKFORCE/<project>/` per project (allows
     multiple Coordinators across projects). Current:
     `WORKFORCE/n8n-pipeline/`. Legacy `AGENTS/` symlink for
     back-compat.
   - Naming: Coordinator = leadership title (Captain, Marshal,
     Commander, Chief, …); Agent = NATO phonetic + scope tag.
     Supersedes Greek-letter Coordinator convention.
7. **Sigma renamed to Captain.** Manifest, pulse, journal,
   inbox all migrated. Sigma manifest marked `renamed_to_Captain`
   as audit history; do not reclaim.
8. **RESUME ANCHOR format** standardized at top of journal
   files (9 numbered fields). Single source of truth for
   post-compact bootstrap.

## Driving incident

2026-05-12: the Coordinator compacted, woke on a `/loop` fire that
scheduled an hourly monitoring audit, and executed the audit itself
rather than routing it to the monitor Agent whose task spec owns it.
The Operator caught it ("are you running the monitors yourself now?
why?") and surfaced the root cause: post-compact context handoff
omitted enough re-anchor signal that the Coordinator executed cold.

Specific drift behaviors observed:
- Action without trace (running audits with no Operator direction
  authorizing it; the monitor Agent's task spec already owned
  audits).
- Implementation-narration in rollups (cron IDs, internal
  mechanics) instead of outcomes.
- Failure to bump pulse on checkpoints (the Coordinator's pulse was
  hours stale at the time of the catch).

## Why this decision

The Operator's direction (2026-05-12): further harden the alignment
between the Coordinator and the Operator. That link is the most
critical in the entire chain and must stay in the forefront as the
primary goal — all other tasks and work are secondary to it, because
if alignment is lost, the goals and tasks drift and likely land
incomplete or unsatisfactory.

This is a structural fix, not a behavioral exhortation. Layers:

- **Layer 1 (mechanical):** SessionStart hook → ac-reorient runs
  before first response, surfaces re-read order + state. No
  reliance on remembering.
- **Layer 2 (durable record):** operator-directions vault
  captures verbatim Operator quotes. Standing-orders distill
  cumulative expectations. Both survive compaction.
- **Layer 3 (doctrine):** Principles 11 + 12 codify stoic
  discipline + alignment primacy as fleet-wide rules.
- **Layer 4 (visual):** Leadership-title naming makes Coordinator
  visually distinct from Agents in logs. Reduces at-a-glance
  confusion.
- **Layer 5 (continuous):** RESUME ANCHOR at top of journal,
  bumped on every checkpoint. Pulse notes carry identity
  reminder. Alignment self-test every 5 turns or every rollup.

## Implementation

Shipped this commit:

- `bin/ac-reorient` (executable shell script)
- `~/.claude/settings.json` SessionStart hook block
- `runtime/operator-directions/2026-05-12__autonomy-and-alignment.md`
- `personalities/captain-standing-orders.md`
- `personalities/name-pool.md` rewritten
- `~/OPS/CONTEXT/operating-doctrine.md` Principle 10 updated,
  11 + 12 added
- `personalities/COORDINATOR.md` updated
- `personalities/AGENT.md` updated
- `runtime/manifest.d/Captain.json` (new), Sigma.json marked
  `renamed_to_Captain`, `_coordinator.json` points to Captain
- `runtime/pulse/Captain.json` (new), Sigma.json marked
- `runtime/journal/Captain.md` (new, with strict RESUME ANCHOR
  at top)
- `runtime/inbox/Captain/` (new dir)
- This decision record.

Bravo + Charlie notified via `ac-msg` with `topic: structural-change`.

## Anti-decision

This decision does NOT:

- Change AGENT.md or task scopes for Bravo or Charlie. They
  continue their existing work.
- Promote any rule proposal or change any AI Triage prompt.
- Modify the irreversible-action gate list. Those still escalate
  regardless of prior signal.
- Replace operator-directions vault content; the vault accretes,
  it does not edit-in-place.

## Hard-gate handling

Operator authorized this batch explicitly 2026-05-12 across two
exchanges:

1. "Sounds great please ship this!" (re: ac-reorient script,
   doctrine additions, naming, decision record).
2. "Please ship everything you've got on your plate that we're
   in alignment on" (re: full structural batch).

Judgment-delegation territory under
`runtime/decisions/2026-05-12__operator-judgment-delegation.md`
+ this decision's own Principle-12 framing.

## Expected impact

- Future post-compact resumes deterministically run ac-reorient
  before first response. No more cold-start drift.
- Coordinator's daily work stays traceable to Operator direction
  via the vault.
- Stoic-discipline language in doctrine gives every Agent + the
  Coordinator explicit anti-drift handles.
- Visual distinction (Captain vs Bravo/Charlie/Delta) makes
  audit-log scanning faster.
- Project subdir structure allows future multi-project workforce
  expansion without clobbering.

Charlie measures: zero compact-resume audit-shadow incidents.
Operator measures: subjective alignment confidence across
sessions.
