# Project lessons — `<project>-lessons.md`

This directory holds one Markdown file per project that has accumulated its own
durable rules: `<project>-lessons.md`. Each file is the "what we learned doing
*this one* project" layer — architectural rules, boundaries, and lessons
specific to a single repo or system.

**It ships empty on purpose.** OPS is a fresh template: no project has been
worked yet, so this directory contains only this README. Files appear here as
you build. Nothing else in the harness depends on a lessons file existing.

## The three doctrine layers

Keep these straight — putting a lesson in the wrong layer is how knowledge gets
lost or over-generalized:

| Layer                              | Scope                        | Loaded when                          |
| ---------------------------------- | ---------------------------- | ------------------------------------ |
| `operating-doctrine.md`            | Universal AI philosophy      | Every session (mandatory)            |
| `fleet-doctrine.md`                | Universal multi-agent rules  | On `ACTIVATE AGENT` / `COORDINATOR`  |
| `CONTEXT/projects/<project>-lessons.md` | One specific project    | Only when working directly on that project |

A lesson earns a spot in a `-lessons.md` file when it is **true of this project
and not automatically true of every project**. If it generalizes to any repo or
any AI interaction, promote it up to the doctrine files instead and leave a
project-specific *embodiment* here that points at the universal rule.

## When to read one

The session-startup rule (see the root `CLAUDE.md`) is: read
`CONTEXT/projects/<project>-lessons.md` **only when working directly on that
project**. These files are not general reading — loading every project's lessons
into every session is noise. If the task doesn't touch the project, its lessons
file is not required reading.

## When to create one

Create `<project>-lessons.md` the first time a project has a rule that:

- a future session would get wrong without being told, and
- is specific enough that it doesn't belong in universal doctrine.

Name it after the project directory it documents (`PROJECTS/<org>/<repo>` →
`<repo>-lessons.md`). One file per project. Do not split a project across
several lessons files; sections inside the file do the organizing.

## What goes in one

Match the shape below. The point is a stable, scannable structure so any
session finds the same information in the same place across every project:

- A header blockquote stating scope, what loads it, and pointers to the
  universal doctrine files it sits under.
- **Audience** — who should read it, and who can safely skip it.
- **Project rules** — the durable rules, each with a short "how to apply."
- **Lessons archive** — dated entries recording what was learned and when.
- **Architectural choices made** — settled decisions, preserved as record.
- **References** — the authoritative files/endpoints for the project.
- **See also** — links back to the universal doctrine and the project's own
  in-repo instructions.

---

## EXAMPLE skeleton — `billing-sync-lessons.md`

*(Synthetic. This is the shape a real lessons file takes, not a file that
ships. Replace the whole thing with real content the first time a project earns
one. `billing-sync` is an invented Example Corp project — a small data-
integration pipeline — chosen because that shape naturally has architectural
rules to document.)*

````markdown
# Billing Sync — Lessons & Project Doctrine

> Project-specific principles, architectural rules, and lessons for the
> billing-sync pipeline (`PROJECTS/ExampleCorp/billing-sync/`).
> Loaded ONLY when working directly on that pipeline.
>
> Universal AI philosophy lives in `operating-doctrine.md`. Universal
> multi-agent rules live in `fleet-doctrine.md`. This file is the
> "what we learned doing this one project" layer.

---

## Audience

- Any AI session editing the billing-sync pipeline or its state DB.
- Any future project that wants to learn from how this one was built —
  read once, generalize the principle, leave the billing-specific example here.

For sessions outside that scope, this file is not required reading.

---

## Project rules

### B1. Source pollers are dumb pipes

Pollers authenticate, fetch, normalize, and hand off — nothing else. No
filtering by type or amount in the poller; filtering belongs downstream where
it can be seen and audited in one place.

**How to apply:**
- If a rule can be matched deterministically with high confidence, write the
  rule downstream. Don't burn an LLM call to confirm what a check already knows.
- Already-classified records carry their decision forward so later steps route
  deterministically.

This is the project-specific embodiment of the universal "ruleset before AI"
principle in `fleet-doctrine.md`.

### B2. State lives in one store, entities in another

Workflow state and vendor entities never share a table. Blurring the two is the
failure mode — they drift independently and corrupt each other's assumptions.

---

## Lessons archive

### YYYY-MM-DD — Reconciliation baseline confirmed

Baseline sync confirmed correct; the rules layer handled the bulk of the work.
Real follow-ups were upstream noise reduction and dedup, not new AI logic.

---

## Architectural choices made

Settled for this project, preserved as record, not re-litigated each session:

- **Two-stage split:** normalize/enrich in stage one, write in stage two. No
  business logic in the writer; no writes from the normalizer.
- **State store:** a dedicated database, never scratch files or in-memory state.

---

## References

- Pipeline definition: `PROJECTS/ExampleCorp/billing-sync/`.
- Credentials in the project's gitignored `.env`; load, never commit.

## See also

- `CONTEXT/operating-doctrine.md` — universal AI philosophy.
- `CONTEXT/fleet-doctrine.md` — universal multi-agent coordination.
- `PROJECTS/ExampleCorp/billing-sync/CLAUDE.md` — the repo's own instructions,
  authoritative for current code shape.
````
