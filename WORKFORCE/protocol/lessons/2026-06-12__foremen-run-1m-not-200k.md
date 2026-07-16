---
id: 2026-06-12__foremen-run-1m-not-200k
date: 2026-06-12
author: Captain
contributors:
  - Operator
status: settled
scope: cross-cutting
affects:
  - fleet-protocol
  - ops-doctrine
supersedes: null
superseded_by: null
related_tasks:
  - alpha-api
  - bravo-dashboard
  - charlie-audit
  - delta-research
related_repos: []
tags:
  - fleet
  - models
  - context
---

# Foremen run the 1M-context tier — the assumed 200k main-session pin does not exist

## Decision

The four lane foremen (Alpha/Bravo/Charlie/Delta) run main sessions on the
1M-context model tier. The wave playbook's assumption that pinning the
model alias yields a 200k main session ("only Captain is 1M") was WRONG
and is corrected by this record.

## Context

The wave's spawn plan assumed `--model <alias>` yields a 200k main
session. Empirical check 2026-06-12: both the short alias and the full
model id render a 1M context meter on a fresh session. The verified 200k
tier exists only for Agent-tool SUBAGENTS (the subagent alias table is
about subagent model resolution and remains accurate). There is no 200k
main-session variant to pin.

**Generic mechanic:** main-session `--model` aliases and subagent
`model:` aliases resolve through different tables. Never assume a pin
implies a context size — verify empirically against the context meter on
a fresh session before building a fleet plan on the assumption.

## Why this decision

The real alternative was pinning foremen to a 200k tier of a different
model. The Operator's explicit direction wins: access to the 1M tier
was limited-time, and the direction was to use it to full potential. The 200k expectation was instrumental (a context-management
concern), not terminal — and 1M foremen make the actual requirement
(never auto-compact; synthesis-then-peer-compact) EASIER, not harder.
Per P4: >80% prior signal, reversible (sessions can be restarted any
time) → judgment exercised, surfaced in the first rollup.

## Implications

- Compaction discipline unchanged: foremen still synthesize + msg
  Captain at 60-65% of THEIR meter; Captain still drives peer compaction
  (F8). Thresholds are percentage-based, so a bigger meter just means
  they hit later.
- Subagent rule unchanged: foremen fan out with the ungated 200k
  subagent aliases; any gated subagent tier stays off-limits per the
  alias table.
- `ac-spawn --model` flag stays — it correctly passes the alias through;
  callers must know main-session aliases resolve per profile settings,
  not per the subagent table.
- Future fleets on this host: expect 1M foremen while the time-boxed
  access lasts; revisit when model access changes.

## Anti-decision

Does not change Captain's model or the subagent alias table.
