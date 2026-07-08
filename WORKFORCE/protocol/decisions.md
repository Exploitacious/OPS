# Protocol — Decision Records

Settled architectural or process calls live in
`runtime/decisions/`. Once a decision is filed, it stays settled
— agents do not relitigate. To change a decision, write a new
record that supersedes the old one.

Decision records are the principal mechanism that implements
operating-doctrine principle 2 ("document the why, not just the
what"). For deterministic-rule changes in a specific repo, prefer
the repo's own rules log (e.g.,
`ExampleOrg/sample-app/docs/extraction-rules-log.md`
for a normalizer pipeline). For cross-cutting architectural calls, file a decision
record here. They are not mutually exclusive — load-bearing
changes can land in both.

---

## When to file a decision

- The Operator settled an ambiguity. Capture what they decided.
- Two agents disagreed and one approach won. Capture which, why,
  and the trade-off.
- A non-obvious technical call was made (e.g., "we use direct
  vendor REST for the dashboard, not a bespoke MCP wrapper"). Capture so a
  future agent doesn't second-guess it.
- A workflow / process rule was changed (e.g., "no force-push to
  release branches"). Capture so agents respect it.
- A name was reclaimed from a stale agent. Capture the handoff.
- A Coordinator was reclaimed (5-min stale rule kicked in). Capture
  the handoff.

Things that do NOT need a decision record:

- Routine code choices (function names, file structure inside one
  repo). Use comments, commits, code review.
- Reversible config tweaks. Use the commit message.
- A test failure you fixed. Use the commit message + CHANGELOG.

The bar for a decision record is: "would a future agent get
confused or repeat this debate if they only read the code?" If
yes, file the record.

---

## File location and naming

`runtime/decisions/<YYYY-MM-DD>__<short-slug>.md`

- `YYYY-MM-DD` = date in UTC.
- `short-slug` = kebab-case, descriptive.
- Multiple decisions on the same day are fine; the slug
  disambiguates.

Examples:

- `2026-05-11__api-vs-db-boundary.md`
- `2026-05-11__phase2-shadow-validation-mode.md`
- `2026-05-11__mark-stale-Echo.md`
- `2026-05-12__coordinator-handoff-sigma-to-omega.md`

---

## Format

```markdown
---
id: 2026-05-11__phase2-shadow-validation-mode
date: 2026-05-11
author: Sigma
contributors:
  - Bravo
  - Operator
status: settled
supersedes: null
superseded_by: null
related_tasks:
  - 2026-05-11__phase2-scorer
related_repos:
  - N8nAutomations
tags:
  - n8n
  - scoring
  - shadow-mode
---

# Phase 2 scorer — shadow validation mode

## Decision

Shadow validation passes when v2 matches v1 on **clear-cut cases**
(severity > 8 or < 3) and diverges as expected on mid-band cases.
Day-10 cutover criteria: clear-cut match rate ≥ 95%, mid-band
divergence consistent with design intent (manual judgment).

## Context

Task `2026-05-11__phase2-scorer` required a definition of "shadow
validation passes" before cutover. Three options on the table
(documented in escalation msg
`2026-05-11T17-15-00Z__Bravo__escalation-phase2-shadow-mode`).

## Why this decision

Operator picked option B during conversational rollup at
2026-05-11T17:45Z. Rationale: a strict 5% match (option A) would
fail v2 on intentional improvements; pure spot-check (C) doesn't
generate a defensible "we shipped because X" record.

## Implications

- Scorer instrumentation must log `severity_band` per execution
  so the daily report can split clear-cut vs mid-band.
- Day-10 report includes both numbers + flagged divergences for
  Operator review.

## Anti-decision (what this does NOT settle)

This does not settle what to do if clear-cut match rate is in
85–95%. That's a follow-up call at day 10.
```

### Required frontmatter fields

| Field | Notes |
|---|---|
| `id` | Filename without `.md`. Must match the filename exactly. |
| `date` | ISO date (no time) in UTC. |
| `author` | Name of the agent / coordinator who filed it. `Operator` if filed by the human. |
| `contributors` | List of agents involved in the discussion. Include `Operator` if they weighed in. |
| `status` | `settled` (default) \| `proposed` (under discussion) \| `superseded` |
| `scope` | `project` (default — scoped to the active project) \| `cross-cutting` (affects fleet-wide doctrine, OPS structure, or all projects). See below. |
| `affects` | Optional list of areas the decision touches. Only required when `scope: cross-cutting`. Free-form kebab-case (e.g., `ops-doctrine`, `claude-memory`, `fleet-protocol`). |
| `supersedes` | id of decision this replaces, or `null` |
| `superseded_by` | id of decision that replaced this, or `null` |
| `related_tasks` | List of task ids. |
| `related_repos` | Repos this decision affects. |
| `tags` | Free-form. Lowercase kebab. |

### Scope field — why it exists

Decision records live under `FLEETPROJECTS/<project>/runtime/decisions/`. That's a per-project directory by design — when there was one project, the assumption that "the active project's runtime is where all decisions go" held cleanly.

With multiple projects on the same fleet, some decisions made inside a project are actually fleet-wide in effect (folder-structure changes, memory-sync doctrine, naming conventions, protocol updates, etc.). They live in the project's runtime procedurally but their authority is cross-cutting.

The `scope:` field disambiguates without restructuring:

- `scope: project` (default if omitted) — decision applies only to the active project. Closes with the project; rolls forward only if the Operator explicitly migrates it.
- `scope: cross-cutting` — decision applies fleet-wide. The `ac-close-project` flow MUST surface these as auto-promotion candidates (or, if the script doesn't yet, the Operator should manually relocate them to `protocol/lessons/` or another fleet-wide location before close).

Same field convention applies to `runtime/improvements/<date>__<slug>.md` and `runtime/operator-directions/<date>__<slug>.md`. Both file types can be project-scoped OR cross-cutting; tag them accordingly at file time.

Audit query: `grep -rE '^scope:[[:space:]]*cross-cutting' ~/OPS/WORKFORCE/FLEETPROJECTS/*/runtime/` finds all cross-cutting artifacts across all projects.

### Body structure (suggested, not enforced)

- **Decision** — one paragraph, what was settled.
- **Context** — what raised the question, where it was discussed.
- **Why this decision** — rationale, including the trade-off
  rejected.
- **Implications** — what changes downstream.
- **Anti-decision** — what this does NOT settle (prevents
  over-reading).

---

## Superseding

To change a settled decision:

1. File a new record. Set its `supersedes:` to the old record's id.
2. In the new record's body, briefly explain why the old one no
   longer applies.
3. Edit the old record's frontmatter: `status: superseded`,
   `superseded_by: <new-id>`.
4. Append to log: `event: supersede`, `target: <old-id>`,
   `new: <new-id>`.

Operator approves supersedes for anything affecting `personalities/`
or `protocol/`. For routine technical decisions, Coordinator or
the involved agents can supersede with a documented reason.

---

## Anti-patterns

- **Decision-creep.** Filing decisions for things that don't need
  them. The bar is "would a future agent get confused?" — not
  "did I think about this for more than 30 seconds?"
- **Stealth decisions.** Making a non-obvious technical call
  without filing. Forces future agents to reverse-engineer the
  rationale from code.
- **Editing settled decisions.** Don't. Supersede. The audit trail
  matters.
- **Vague decisions.** "We'll use option B." Without the why, the
  decision rots. Include context and rationale.
- **Operator-bypass.** Filing a decision that overrides a previous
  Operator decision without Operator approval. Wrong. The
  Operator's calls supersede agent calls.

---

## Quick reference

| You want to… | Do this |
|---|---|
| Capture an Operator call | File decision, `author: Sigma`, `contributors: [Operator]` |
| Settle an inter-agent disagreement | File decision, list both sides in body |
| Document a non-obvious technical choice | File decision, tag with relevant repo |
| Document a stale agent reclaim | File decision, `slug: reclaim-<name>` |
| Change a previous decision | New decision with `supersedes` set + edit old one |
| Park an unsettled debate for later | File decision with `status: proposed` |
