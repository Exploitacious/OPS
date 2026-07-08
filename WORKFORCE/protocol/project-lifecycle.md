# Project lifecycle — open, run, close

The fleet handles projects in four states. Each transition has
preconditions + tooling. This file is operator-facing and
agent-facing — both need to know the same lifecycle.

```
proposed ──→ active ──→ wind-down ──→ closed
                 │           │
                 └── (no ────┘ skip wind-down if all tasks closed
                     wind-down)  cleanly already)
```

---

## State definitions

### `proposed`

- Operator + Coordinator have agreed a project should happen but
  no `FLEETPROJECTS/<name>/` dir exists yet.
- Captured as: an entry in your own backlog / idea-tracking file, or
  a decision record under the current active project's
  `runtime/decisions/` with `proposed_project: true`.
- Transition trigger: Operator says "let's start it" + assigns
  a slug.

### `active`

- `FLEETPROJECTS/<name>/runtime/` exists with manifest, tasks,
  decisions, journal, etc.
- One or more agents bound (`bound_root` matches the project
  path).
- Tasks flowing through `assigned → in_progress → awaiting_review → done`.
- This is the bulk of the project's life.

### `wind-down`

- All ship-class tasks `done`. Remaining tasks are `ready`
  (unstarted), `cancelled`, or rolling forward to a sibling
  project.
- Agents in `idle` or `closed` state.
- Lessons-learned harvest in progress: candidate doctrine
  promotions identified.
- Coordinator drafts the closeout artifact.
- Transition trigger: Coordinator runs `ac-close-project --dry-run`
  and the report is clean.

### `closed`

- `CLOSEOUT.md` exists in the project root.
- All agent manifests `status: closed-with-project`.
- Coordinator slot released (if pointing here).
- Closeout decision record filed.
- Entry appended to `WORKFORCE/protocol/closeout-log.md`.
- Optionally: project dir archived to
  `~/OPS/ARCHIVE/<project>__<closed-date>.tar.gz` + removed
  from FLEETPROJECTS/.

---

## Opening a new project

Operator drives:

1. Pick a slug (kebab-case, descriptive, machine-safe).
   Examples: `n8n-pipeline`, `mcp-server-v2`, `quarterly-review-2026q2`.
2. Create the dir: `mkdir -p ~/OPS/WORKFORCE/FLEETPROJECTS/<slug>/runtime`.
3. Activate the Coordinator (or first agent) with the project
   path in the brief:
   ```
   export AC_FLEET=$HOME/OPS/WORKFORCE
   export AC_ROOT=$HOME/OPS/WORKFORCE/FLEETPROJECTS/<slug>
   ```
4. Coordinator runs `$AC_FLEET/bin/ac-register --role coordinator`
   (claims the coord slot for THIS project).
5. Coordinator drafts initial task spec(s) + assigns agents.

No script automates step 1-3 by design. The Operator decides
when a project is real and what to call it.

---

## Running a project

Standard fleet ops apply per `personalities/COORDINATOR.md`
and `personalities/AGENT.md`. The only project-lifecycle-relevant
thing during `active`: keep `FLEETPROJECTS/<slug>/CLOSEOUT.md`
absent. Its existence is the closed-state signal.

---

## Closing a project

Coordinator runs:

```bash
$AC_FLEET/bin/ac-close-project <slug> --dry-run
```

The dry-run prints what will happen. If clean → re-run without
`--dry-run`. Phases:

1. **Sanity check.** Refuses to close if any task is in
   `in_progress|assigned|blocked|needs-direction`, if any agent
   pulse is `working`, if unprocessed inbox messages exist, OR
   (added 2026-05-13 per decision `2026-05-13__closeout-scope-aware`)
   if any `runtime/improvements/*.md` has both `scope: cross-cutting`
   and `status: proposed` — cross-cutting doctrine proposals must be
   resolved (settled/rejected/superseded) before close. Also surfaces
   (informational, doesn't block) any settled cross-cutting decision
   linked to a `READY` entry in your own backlog / idea-tracking file — these are
   "open cross-cutting threads" recorded in the closeout-log so
   future Captains inherit the punch list.
2. **Closeout artifact.** Writes `FLEETPROJECTS/<slug>/CLOSEOUT.md`
   with: outcomes (task counts, decisions, directions captured,
   drift-alerts closed), agents involved + tenure, **auto-promoted
   cross-cutting artifacts** (new section), **open cross-cutting
   threads** (new section), manual-review legacy candidates
   (heuristic fallback), open items rolled forward.
3. **Free resources.** Each agent registered to the project gets
   `status: closed-with-project`. Pulse files deleted. Ack-pending
   flags cleared. Names freed back to pool.
4. **Detach coordinator slot.** If `_coordinator.json` points here,
   flipped to `status: project-closed`.
5. **Auto-promote + manual-review candidates.** Artifacts with
   `scope: cross-cutting` frontmatter are auto-copied to fleet-wide
   locations:
   - Decisions + improvements → `WORKFORCE/protocol/lessons/<date>__<slug>.md`
   - Operator-directions → `WORKFORCE/protocol/standing-directions/<date>__<slug>.md`
   The in-project original gets a "Promoted to" banner appended
   (audit trail in both places). Legacy / untagged files matching
   the original keyword + length heuristic are surfaced in
   CLOSEOUT.md as manual-review candidates; the Operator copies
   them manually if they deserve promotion.
6. **Closeout decision.** Filed in the project's
   `runtime/decisions/`. Mirrored summary appended to
   `WORKFORCE/protocol/closeout-log.md` (the fleet's
   institutional memory across all projects), now with extended
   format including cross-cutting promotion count + open-threads list.
7. **Optional archive.** With `--archive`, tars the project dir
   to `~/OPS/ARCHIVE/` and removes it from FLEETPROJECTS/.
   Without, dir stays in place — Operator decides when to delete.
   Auto-promoted artifacts have canonical copies in `protocol/`
   regardless of archive state.

---

## Why closeout matters

Without it, the fleet doesn't learn. Project 2 makes project 1's
mistakes. With `closeout-log.md`, every new Captain reads it on
activation and inherits prior projects' pattern recognition.
Operating-doctrine Principle 1 (document the why) extends to
projects: every closed project documents what was tried, what
worked, what to promote.

---

## File map (closeout-related)

```
WORKFORCE/
├── bin/
│   ├── ac-close-project        ← orchestrates the closeout
│   └── ac-rollup               ← daily artifact (different from closeout)
├── protocol/
│   ├── project-lifecycle.md    ← this file
│   ├── closeout-log.md         ← append-only registry of closed projects
│   ├── lessons/                ← doctrine promoted from closed projects
│   │   └── <date>__<slug>.md   (auto-promoted from cross-cutting
│   │                            decisions + improvements; also
│   │                            manual-copy from heuristic candidates)
│   └── standing-directions/    ← cross-cutting operator-directions
│       └── <date>__<slug>.md   (auto-promoted from cross-cutting
│                                operator-directions at project close)
└── FLEETPROJECTS/
    └── <slug>/
        ├── CLOSEOUT.md         ← per-project closeout artifact
        └── runtime/
            └── decisions/
                └── <date>__project-closed-<slug>.md
```

Scope-aware promotion logic is documented in the promoted lesson
itself: `protocol/lessons/2026-05-13__closeout-scope-aware.md`.
