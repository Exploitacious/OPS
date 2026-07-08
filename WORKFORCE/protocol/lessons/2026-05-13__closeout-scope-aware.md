---
id: 2026-05-13__closeout-scope-aware
date: 2026-05-13
author: Captain
contributors:
  - Operator
status: settled
scope: cross-cutting
affects:
  - fleet-protocol
  - ac-close-project
  - project-lifecycle
  - closeout-log
supersedes: null
superseded_by: null
related_tasks: []
related_improvements:
  - 2026-05-13__closeout-cross-cutting-data-loss
related_repos:
  - ~/OPS
tags:
  - doctrine
  - closeout
  - cross-cutting-artifacts
  - data-loss-prevention
---

# Close-out becomes scope-aware (Phase A blocks + Phase E auto-promotion)

## Decision

`ac-close-project` is extended to read the `scope:` frontmatter field on `runtime/{decisions,improvements,operator-directions}/*.md` and act on `scope: cross-cutting` artifacts differently than `scope: project` ones. Specifically:

1. **Phase A (sanity check) gains scope-aware blocks.** Refuse close if any `improvements/*.md` has `status: proposed` AND `scope: cross-cutting`. Surface (warn but don't block) if any settled `scope: cross-cutting` decision links to a `READY` or `READY (HIGH PRIORITY)` entry in your own backlog / idea-tracking file.
2. **Phase E (promotion candidates) gains auto-promotion on `scope: cross-cutting`.** Decisions + improvements with cross-cutting scope auto-copy to `WORKFORCE/protocol/lessons/<date>__<slug>.md`. Operator-directions with cross-cutting scope auto-copy to a new `WORKFORCE/protocol/standing-directions/<date>__<slug>.md` directory. The in-project original gets a "Promoted to X" banner appended (preserves audit trail in both places).
3. **The existing keyword + length heuristic is kept as a fallback** for legacy / untagged files. Manual-copy candidates still surface in CLOSEOUT.md.
4. **CLOSEOUT.md gains an "Auto-promoted cross-cutting artifacts" section** and an "Open cross-cutting threads at close" section.
5. **closeout-log.md format is extended** to record cross-cutting promotion counts + open-thread list, so future Captains inherit the punch list across project boundaries.

## Context

Surfaced during a working session (2026-05-13). Captain filed three cross-cutting artifacts in `sample-project`'s runtime — memory-sync doctrine, a DELIVERABLES + memory-sync improvement, and the close-out gap improvement — and Operator asked how close-out handles them. The existing flow promotes via a heuristic (`body > 50 lines` AND `title matches alignment|judgment|protocol|doctrine|naming|handoff|escalation`) that would catch some but not all of them. Documented in the companion `2026-05-13__closeout-cross-cutting-data-loss.md` note.

## Why this decision

Operator approval: "Your closeout-cross-cutting-data-loss improvement: approved. Ship it. Scope-aware Phase A blocking, Phase E auto-promote on `scope: cross-cutting`, new `protocol/standing-directions/` dir, closeout-log format extension, decision-IDEA crossref check. Your 90-120 min estimate sounds right. Use --dry-run liberally before real edits. File a decision record alongside the implementation."

Trade-off rejected: status quo (heuristic-only). The heuristic produces silent data loss on short cross-cutting decisions, untitled-doctrine-keyword improvements, and standing operator-directions. Documented in the improvement note.

Trade-off rejected: scope: cross-cutting becomes mandatory at file creation. Reject — too rigid, breaks the lightweight default-to-project posture that lets agents file artifacts quickly without ceremony. Keep `scope: project` as the omit-default.

Trade-off rejected: build a separate top-level fleet-wide `decisions/` directory. Reject — adds doctrine complexity. Keep per-project authoring; promote on close.

## Implications

- `bin/ac-close-project` gains: a `get_scope()` helper, Phase A scope-aware blocking, Phase E auto-promotion loop, CLOSEOUT.md section additions, closeout-log format extensions.
- `~/OPS/WORKFORCE/protocol/standing-directions/` is created as a new fleet-wide directory.
- `protocol/project-lifecycle.md` is updated to document the new close-out behavior.
- `protocol/closeout-log.md` is updated with the extended entry format.
- `protocol/decisions.md` already documents the `scope:` field (filed 2026-05-13).
- Existing per-project artifacts in `n8n-pipeline/` (already closed) are NOT retroactively migrated. New behavior applies to closures going forward. n8n-pipeline's CLOSEOUT.md and closeout-log entry stay as-is.

## Heuristic fallback retained

Files without `scope:` field (legacy or forgotten) are still surfaced by the original keyword+length heuristic for manual review. This prevents silent loss of pre-doctrine artifacts. The new auto-promotion path supplements rather than replaces.

## Anti-decision

- Doesn't change the `runtime/{decisions,improvements,operator-directions}/` per-project authoring location.
- Doesn't introduce frontmatter requirements beyond what's already documented.
- Doesn't retroactively re-classify or move existing artifacts from any closed project.
- Doesn't auto-commit anything — close-out still produces files; Operator/Captain commits.
- Doesn't replace `--archive` semantics. Auto-promoted artifacts have canonical copies in `protocol/` regardless of whether the project tarball gets archived.
- Doesn't define how `protocol/standing-directions/` integrates with `personalities/captain-standing-orders.md`. That's a follow-up if standing-directions accumulate enough to justify a roll-up.

## Verification plan

Implementation must pass `ac-close-project sample-project --dry-run` exercising:
- Phase A: detect 1+ open cross-cutting `status: proposed` improvement → block (`sample-project` here has the close-out improvement still `proposed` until the implementation merges and Captain re-flags it).
- Phase A: detect cross-cutting settled decision (`2026-05-13__memory-sync-doctrine`) linked to READY IDEA → surface.
- Phase E: identify 2+ cross-cutting decisions/improvements for auto-promotion to `protocol/lessons/`.
- Phase E: identify cross-cutting operator-directions for auto-promotion to `protocol/standing-directions/`. (`sample-project`'s operator-directions are `scope: project`, so none should promote — that's the verification that scope-filtering works.)
- CLOSEOUT.md output reflects the new sections (auto-promoted + open threads).
- closeout-log.md draft entry reflects extended format.

Real close runs only after Operator approves the dry-run output.
