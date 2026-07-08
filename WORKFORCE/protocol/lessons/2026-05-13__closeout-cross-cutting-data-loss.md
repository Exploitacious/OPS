---
id: 2026-05-13__closeout-cross-cutting-data-loss
date: 2026-05-13
filed_by: Captain
status: settled
scope: cross-cutting
affects:
  - fleet-protocol
  - ac-close-project
  - project-lifecycle
operator_review: complete
review_outcome: |
  Approved 2026-05-13. Implementation settled in decision record
  2026-05-13__closeout-scope-aware.md. Phase A blocks + Phase E auto-promotion
  shipped to bin/ac-close-project; protocol/standing-directions/ created;
  protocol/project-lifecycle.md + protocol/closeout-log.md updated.
decision_ref: 2026-05-13__closeout-scope-aware
tags:
  - closeout
  - data-loss-prevention
  - cross-cutting-artifacts
  - doctrine
---

# Close-out flow has a data-loss gap for cross-cutting + unbuilt artifacts

## The gap (concrete)

`ac-close-project` archives a project cleanly when work is done. The close-out artifact (`CLOSEOUT.md`), the decision summary, and the closeout-log entry all land in expected places. The script even surfaces "promotion candidates" — decision records that look doctrine-level by title-keyword + body-length heuristic, plus improvements with `status: accepted`.

But the heuristic misses three classes of artifact that should survive a project close:

### Class 1 — Cross-cutting decisions

Today's promotion-candidate filter:

- Decision body > 50 lines AND
- Filename matches `alignment|judgment|protocol|doctrine|naming|handoff|escalation`

The new `scope: cross-cutting` frontmatter is the precise signal. A short cross-cutting decision (under 50 lines, no doctrine-keyword in the slug) will currently be archived with the project despite being fleet-wide in effect. Example from this session: `2026-05-13__memory-sync-doctrine.md` is 130+ lines and scoped cross-cutting, so it would catch the existing heuristic — but a future cross-cutting decision called `2026-05-13__deliverables-naming.md` at 40 lines would silently archive.

### Class 2 — Standing operator-directions

Operator-directions get *counted* in CLOSEOUT.md (`Operator-directions captured: N`) and listed by filename, but the script does NOT distinguish project-scoped from cross-cutting / standing directions. A standing direction filed under project A applies to project B too — but if A closes with `--archive`, the direction is in a tarball.

Concrete example: `2026-05-12__sample-direction.md` is properly project-scoped (only applies to `sample-project`). But imagine if a future operator-direction filed inside `sample-project` said something like "from now on, all Coordinators use kebab-case slugs in decision filenames." That's cross-cutting. Today it would archive with the project.

### Class 3 — Decisions with unimplemented action threads

The `2026-05-13__memory-sync-doctrine.md` decision is settled. The implementation lives as a READY HIGH-PRIORITY IDEA in `IDEAS.md`. If `sample-project` closes before that IDEA is built, the decision is archived (good — historical record) but the link between "WE DECIDED THIS" and "IT NEEDS TO HAPPEN" is broken. Future Captain inheriting `closeout-log.md` sees the decision filename but not the un-built status.

### Class 4 — Improvement notes with `status: proposed`

`ac-close-project` promotes improvements only with `status: accepted`. Improvements in `status: proposed` (awaiting Operator review) just sit in the project. Archive = silent loss of "we noticed this gap, never resolved it." Future Captain doesn't inherit the open question.

---

## What "data loss" looks like in practice

Operator's framing: "if in case we have stuff like this sitting in the project dir, that was never built or actioned, it obviously would need to get migrated to a new home, as part of another project or a specced item in IDEAS. just trying to avoid important data loss and harden against future 'shit happens'."

Precise failure modes:

- A cross-cutting decision archives → next project relitigates the same call because the institutional memory was tar'd.
- A standing direction archives → next Captain doesn't read it because it's not in their active project.
- An improvement `status: proposed` archives → the gap it identified never gets fixed; the noticing-work is wasted.
- A settled decision archives while its implementation IDEA is still READY → the WHY is gone but the WHAT-TO-DO is still in IDEAS.md, now orphaned.

---

## Proposal — scope-aware close-out

### 1. Block close on unresolved cross-cutting items

`ac-close-project` Phase A (sanity check) currently refuses to close on in-flight tasks / working agents / unread inbox. Add three more checks:

- `improvements/` with `status: proposed` AND `scope: cross-cutting` — block. Operator must flip to settled / rejected / superseded OR migrate to fleet-wide before close.
- Settled `decisions/` with `scope: cross-cutting` AND an associated `IDEAS.md` entry tagged `READY` or `READY (HIGH PRIORITY)` referencing it — surface in Phase A. "This project has settled cross-cutting decisions with unimplemented action threads. Migrate the IDEAS entry(ies) to a successor project, or accept the loose pointer?"
- `operator-directions/` with `scope: cross-cutting` — Phase A surfaces the count; Phase E auto-promotes (see below).

### 2. Auto-promote on `scope: cross-cutting`

Phase E currently lists promotion candidates and asks the Operator to manually copy. For `scope: cross-cutting` artifacts, AUTO-COPY to fleet-wide directories. Suggested layout:

- `WORKFORCE/protocol/lessons/<date>__<slug>.md` — already exists, for doctrine lessons promoted from projects (decisions + improvements with cross-cutting scope).
- `WORKFORCE/protocol/standing-directions/<date>__<slug>.md` — NEW. For long-lived operator-directions that survive a project. Promoted automatically on close when `scope: cross-cutting` is set.

The original in-project file gets a one-line header banner appended:

```
> Promoted to `WORKFORCE/protocol/lessons/<date>__<slug>.md` on <date>
> during close of project `<slug>`. Canonical copy is the promoted version.
```

This preserves the audit trail in two places (in-project + fleet) without silent duplication.

### 3. Heuristic kept as fallback

Even with `scope:` field, some artifacts will be filed without it (legacy files, missed tagging). Keep the existing "title-keyword + body-length" heuristic as a fallback so old data isn't silently dropped. Surface heuristic hits as manual-review candidates the way today's script does.

### 4. Decision–IDEA cross-reference

When a decision has `scope: cross-cutting` AND its body links to an `IDEAS.md` entry tagged READY/READY-HIGH-PRIORITY, the close-out flow inspects the linkage. If the IDEA is still READY (unbuilt) at close time:

- Surface in CLOSEOUT.md under "Open cross-cutting threads."
- Recommend the Operator: migrate IDEA to the next active project, or accept the loose pointer in your backlog / idea-tracking file (which lives outside any single project and survives it).

This handles the "decided X, never built X" failure mode without forcing implementation before close.

### 5. Closeout-log already does the right thing

`protocol/closeout-log.md` is fleet-wide and append-only. Every new Captain reads it on activation. The summary line per project should call out cross-cutting items so the institutional memory is queryable without scanning archived tarballs.

Add to the closeout-log entry format:

```markdown
- **Cross-cutting artifacts promoted:** <count> decisions, <count> improvements, <count> standing directions
  - Decisions: <list of paths under protocol/lessons/>
  - Standing directions: <list of paths under protocol/standing-directions/>
- **Open cross-cutting threads at close:** <count>
  - <slug-and-status of each unresolved item>
```

This is the "what hasn't been actioned but mattered enough to flag" record. Equivalent to a punch list inherited across projects.

---

## Worked example

Say `sample-project` has three cross-cutting artifacts in its runtime:

1. `decisions/2026-05-13__memory-sync-doctrine.md` (settled) → needs `protocol/lessons/` promotion at close.
2. `improvements/2026-05-13__deliverables-and-memory-sync.md` (settled, two-gap improvement note) → needs promotion or split-and-promote (gap 1 + gap 2).
3. `improvements/2026-05-13__closeout-cross-cutting-data-loss.md` (this improvement note, status: proposed) → blocks close until Operator review.

A memory-sync READY IDEA in `IDEAS.md` is also linked to (1) — if `sample-project` closes before that IDEA is built, the decision–IDEA crossref check (proposal #4 above) would surface it.

If `ac-close-project sample-project --archive` ran at that point without these proposals implemented, items 1 and 2 would auto-promote IF the existing keyword heuristic matched (it does for both — "memory" and "deliverables" don't match, but the body length saves item 1; item 2's filename has "deliverables" which doesn't match the keyword list). Mixed bag.

After proposal implementation: both auto-promote on `scope: cross-cutting`, regardless of title or length. Item 3 blocks close until resolved. Cleaner.

---

## Implementation scope

If approved, edits needed:

- `bin/ac-close-project` — Phase A new checks, Phase E auto-promotion, scope-aware filtering.
- `protocol/project-lifecycle.md` — document new close-out behavior.
- `protocol/closeout-log.md` — entry format extension (cross-cutting count + open threads).
- `mkdir protocol/standing-directions/` — new fleet-wide directory.
- `protocol/decisions.md` — already updated (scope field documented).
- `personalities/COORDINATOR.md` — note close-out scope-awareness in the close-out section.

Estimated time: 90-120 min focused. Reversible (script changes can be tested with `--dry-run`).

---

## Anti-decision (what this does NOT propose)

- Doesn't move existing artifacts. Just tags + new close-out behavior + new fleet-wide directories.
- Doesn't force scope-tagging retroactively on existing in-project files. Convention starts going forward.
- Doesn't replace the manual-copy promotion flow entirely. Auto-promote happens for `scope: cross-cutting`; manual-copy stays for heuristic matches (legacy / forgotten-to-tag files).
- Doesn't propose a "central decisions" directory above projects. Cross-cutting decisions still live in their authoring project + get promoted on close. Single canonical location post-promotion: `protocol/lessons/`.

---

## Decision points for the Operator

- Approve scope-aware close-out flow as described?
- Approve new `protocol/standing-directions/` directory for promoted operator-directions?
- Approve the four blocking checks in Phase A (cross-cutting `proposed` improvements, settled cross-cutting decisions with unimplemented IDEAs, etc.)?
- Build `ac-close-project` changes now, or defer until a project is actually closing?
- Should this be its own separate IDEA in IDEAS.md (READY) once approved, or rolled into the memory-sync IDEA's "out of scope" list?
