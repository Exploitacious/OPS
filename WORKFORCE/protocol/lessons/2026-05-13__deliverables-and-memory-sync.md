---
id: 2026-05-13__deliverables-and-memory-sync
date: 2026-05-13
filed_by: Captain
status: settled
scope: cross-cutting
affects:
  - ops-folder-structure
  - claude-memory
  - fleet-doctrine
operator_review: complete
review_outcome: |
  Gap 2 (memory sync) — APPROVED. Option A selected (drafts graduate to CONTEXT/).
  Scope: Claude Code only (Linux + Windows). Symlink mechanism. Chat + desktop-client
  bridges out of scope. Pre-commit secrets scan deferred (hard rule still applies —
  the scan is deferred, not dropped). Pruning helper deferred. Settled in decision
  record 2026-05-13__memory-sync-doctrine.md. Promoted in IDEAS.md to READY
  (HIGH PRIORITY).

  Gap 1 (DELIVERABLES folder) — Folder created + first artifact landed
  (example-analysis.md). Doctrine codification (README.md / CLAUDE.md /
  project-kata.md edits) still pending Operator action. IDEA entry remains in
  IDEAS.md awaiting promotion.
decision_ref: 2026-05-13__memory-sync-doctrine
tags:
  - doctrine
  - ops-structure
  - claude-memory
related_ideas:
  - "IDEAS.md / Formalize DELIVERABLES folder in fleet doctrine"
  - "IDEAS.md / Git-track Claude auto-memory into OPS via stow/symlink"
---

# Improvement note — `DELIVERABLES/` folder + auto-memory git-tracking

Two related doctrine gaps surfaced during a working session on
2026-05-13. Filing as `improvements/` per standing-orders rule 5
("Never invent doctrine. New principles get filed as
`improvements/<date>__<slug>.md` for Operator approval"). I acted
on the immediate need (created `DELIVERABLES/` + wrote the example
deliverable) because the Operator explicitly authorized it in
conversation, but the doctrine codification is still pending.

---

## Gap 1 — Orphan deliverables had no documented home

### Symptom

The example-analysis doc is a finished, reusable artifact
that isn't bound to any single project. The existing OPS
top-level layout has:

- `PROJECTS/` — active work, scratchpad projects, github repos
  (gitignored at root)
- `NOTES/MASTER/` — Obsidian vault for personal knowledge
- `WORKFORCE/<project>/runtime/` — fleet operational state
- `IDEAS.md`, `CHANGELOG.md`, `README.md`, `CLAUDE.md` — root files

None of these fit "finished, reusable, git-tracked deliverable not
tied to one project." The doc would have landed in `NOTES/MASTER/`
by default (mixing knowledge base with output artifacts) or in
the active project's `runtime/` (binding it to one session, wrong
scope) — neither right.

### Proposal

Formalize `~/OPS/DELIVERABLES/` as a new top-level folder.
Git-tracked. Holds finished, reusable artifacts that aren't bound
to a specific project: question frameworks, templates, one-pagers,
SOPs, evergreen client docs, etc.

### Boundary rules to codify

- `PROJECTS/<repo>/` → active work, in-flight code, project-bound output
- `WORKFORCE/<project>/runtime/` → fleet operational state (decisions,
  tasks, journal, inbox), per-project
- `NOTES/MASTER/` → personal knowledge base, Obsidian vault, vendor
  research, internal org reference
- `DELIVERABLES/` → finished, reusable artifacts not bound to one
  project; ready to ship / hand off
- `IDEAS.md` (root) → unscoped backlog

### Edits needed (if Operator approves)

- `~/OPS/README.md` — folder structure diagram + one-line purpose
- `~/OPS/CLAUDE.md` — folder-structure block
- `~/.claude/CLAUDE.md` — global folder reference
- `~/OPS/CONTEXT/project-kata.md` — output-routing rule section
- Possibly `~/OPS/CONTEXT/working-preferences.md` "Output Defaults"
  section to include DELIVERABLES as a route option

### Decision points for the Operator

- Sub-structure inside `DELIVERABLES/`? (Start flat, sub-divide later
  when full — proposed default.)
- Versioning convention? (Today the example-analysis doc has a `## Versioning`
  table at the bottom. Should this be standard for all deliverables?)
- Lifecycle: when does a `DELIVERABLES/` artifact get promoted to
  an org-level SOP, a client-facing guide section, or a marketing
  piece? (Probably stays here as the source-of-truth and is exported
  when needed.)

---

## Gap 2 — Claude auto-memory is per-host, isolated from OPS

### Symptom

`~/.claude/projects/<encoded-path>/memory/` is local to one host,
one user, one Claude Code install. Memory written on one machine
doesn't reach a second machine, chat Claude on claude.ai, or any
fresh install. Memory survives compaction within a session but
not host migration.

This contradicts the spirit of `CONTEXT/operating-doctrine.md`
principle 2 ("Compaction is a pause, not death") — which says
durable storage is the continuity mechanism. Auto-memory IS
durable on the local machine but NOT cross-machine. An Operator
moving between hosts loses context that should survive.

The Operator surfaced this 2026-05-13: should memory be
git-tracked into the harness repo? Should that be part of fleet
doctrine, Claude Code only, or every flavor of Claude?

### Proposal — stow/symlink + git-track

**Mechanism.** Symlink (or `stow`) `~/.claude/projects/<encoded>/memory/`
to `~/OPS/.claude-memory/<encoded>/`. Git-track the OPS
directory. Claude reads/writes the same path as before; it can't
detect the indirection.

**Scope of git-tracking.** Track:

- `MEMORY.md` (the index)
- Individual memory `.md` files

Do NOT track:

- Claude Code session caches, transcripts, telemetry
- Anything outside the memory subdirectory

### Cross-Claude-flavor analysis

| Flavor | Mechanism | Git-trackable via stow? |
|---|---|---|
| Claude Code (Linux/WSL/macOS) | File-based, `~/.claude/projects/…/memory/` | **Yes** — primary target. |
| Claude Code on Windows | Verify storage location before committing. Likely same scheme via junction/symlink. | TBD — verify first. |
| Chat Claude (claude.ai) | Projects feature (server-side knowledge files) | **No** — different mechanism. Would need a bridge: export `CONTEXT/` + relevant memories into a Claude Project knowledge file periodically. |
| Claude Desktop | Verify before deciding. Likely separate. | TBD — verify first. |

Conclusion: stow/symlink solves it for Claude Code instances. Chat
and Desktop need a different bridge if cross-Claude continuity is
desired. Defer the bridge until the file-based sync is proven.

### Doctrine question — what IS auto-memory?

Today's `~/.claude/CLAUDE.md` treats auto-memory as durable
personal recall ("auto-memory captures your personal 'why I do X
this way' durable context"). Once git-tracked, it becomes:

- **Visible** to the Operator (commits surface every memory write).
- **Audit-able** (git log shows what AI "thinks it knows about you"
  over time).
- **Promotable** (good memories → `CONTEXT/`, project-specific
  ones → project doc).
- **Cross-flavor reachable via export bridge** (if built).

That's a stronger commitment than "drawer for personal notes." It
becomes a layer beneath `CONTEXT/` — drafts and observations that
graduate (or get pruned) over time.

### Pruning workflow

Quarterly (or on Operator demand):

1. Captain (or any active Claude session with read-write access)
   walks `~/OPS/.claude-memory/<encoded>/`.
2. For each memory, decide:
   - **PROMOTE** → move content into `CONTEXT/about-me.md`,
     `working-preferences.md`, `operating-doctrine.md`, or a new
     context file. Delete the auto-memory entry.
   - **MOVE** → relocate into a project's own doc
     (`PROJECTS/<repo>/docs/` or `WORKFORCE/<project>/runtime/`).
     Delete the auto-memory entry.
   - **KEEP** → stays as auto-memory (transient personal recall,
     not yet stable enough to promote).
   - **DELETE** → stale, wrong, or superseded.
3. Surface the prune diff to the Operator as a pre-commit review.
4. Commit the result.

Could be a helper script: `~/OPS/WORKFORCE/bin/ac-memory-prune`
that walks memory, presents each entry for triage, runs the chosen
move/edit/delete, and shows the diff. Same atomic-write discipline
as other `ac-*` scripts.

### Privacy / sensitivity hard rule

Once memory is git-tracked, the same hard rule that applies to
`WORKFORCE/` files applies here, possibly stronger:

- **No secrets in memory.** Ever. Not even encrypted.
- **No client PII in memory.** Ever.
- **No personal medical / financial / family-sensitive content.**
  Memory drafts can capture the Operator's working preferences but
  not "the Operator is dealing with a specific health issue."

Pre-commit hook on `.claude-memory/` to scan for common leak
patterns (API key prefixes, SSN regex, etc.) — same shape as
existing repo hooks.

### Decision points for the Operator

- Approve stow/symlink approach + git-tracking?
- Approve quarterly pruning cadence? Different cadence?
- Build `ac-memory-prune` helper? Manual prune for now?
- Tackle chat-Claude / Desktop bridge later, or never?
- Verify the Windows Claude Code memory location before committing
  the cross-machine sync claim?

---

## What I did unilaterally (and why)

Per operating-doctrine principle 4 (judgment delegation) +
principle 8 (escalation only when needed):

- Created `~/OPS/DELIVERABLES/` and wrote
  `example-analysis.md` — the Operator explicitly proposed
  the location in chat (a DELIVERABLES folder where loose files can
  go to be git-tracked, ending with "let me know what you think").
  "Let me know what you think" is approval-with-feedback, not "wait
  for approval." Reversible in <24h (delete + move).
- Filed IDEAS entries — backlog hygiene, not doctrine change.
- Filed THIS improvement note — exactly what standing-orders
  rule 5 prescribes for unapproved doctrine proposals.

What I did NOT do:

- Edited `~/OPS/README.md`, `CLAUDE.md`, `project-kata.md`, or
  any `CONTEXT/` file (those are doctrine; Operator owns).
- Set up the stow/symlink (architectural change, needs review).
- Started writing the `ac-memory-prune` helper (no point until
  the upstream doctrine call is made).

---

## Anti-decision (what this does NOT settle)

- Whether `DELIVERABLES/` should have sub-structure now or later.
- Whether all Claude flavors should sync memory or just Claude Code.
- Whether the pruning workflow is automated or manual.
- Whether auto-memory becomes the canonical layer (with `CONTEXT/`
  as "settled" upgrades) or stays as drafts-only.

Operator decides each.
