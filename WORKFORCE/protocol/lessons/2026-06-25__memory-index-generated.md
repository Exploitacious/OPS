---
id: 2026-06-25__memory-index-generated
date: 2026-06-25
author: Agent
contributors:
  - Operator
status: settled
scope: cross-cutting
affects:
  - ops-doctrine
  - claude-memory
  - cross-machine-sync
supersedes: null
superseded_by: null
related_tasks: []
related_improvements: []
related_repos:
  - ~/OPS
tags:
  - doctrine
  - claude-memory
  - cross-machine-sync
  - tooling
---

# MEMORY.md is a GENERATED artifact — resolves the sync-doctrine MEMORY.md-format question

## Decision

`MEMORY.md` (the per-directory auto-memory index) is a **generated
artifact**, derived from each memory file's frontmatter. It is regenerated
by a SessionStart hook and **never hand-edited**. This resolves the open
question as an open item in `2026-05-13__memory-sync-doctrine.md`
("Whether `MEMORY.md` should be in a fixed canonical format vs free-form
— status quo: free-form bullet list"): the canonical format is now a
derived index, not a hand-maintained list.

The format of each index line is fixed:

```
- [title](filename.md) — description
```

where `title` and `description` are read from the file's `---`-delimited
frontmatter (`title:` and `description:`). Files are grouped by
`metadata.type` (project → feedback → reference → other), then sorted by
title. The mapping from file to line is keyed on the **filename** (the link
target), not the frontmatter `name:` field — some files carry a `name:`
that differs from their filename, and the link must resolve.

## Context

Surfaced 2026-06-24/25. `MEMORY.md` was a hand-maintained index: every
memory write appended a bullet line by hand. Cross-machine sync moves
memory files **additively** (`cp` + git — never `rsync --delete`; the
mirror is the cross-machine union, the runtime is a per-machine subset),
but nothing kept the hand-maintained index equal to the set of files
actually present. Result: the two indexes drift and clobber each other
across machines.

Concretely, on one machine the cross-machine **mirror**
(`~/OPS/.claude-memory/<encoded-workspace-path>/`, ~165 files —
the union of all machines' memories) carried a `MEMORY.md` that indexed
only ~39 files; 126 real memories other machines had written were on disk
but invisible to the index. The **runtime**
(`~/.claude/projects/<encoded-workspace-path>/memory/`, that machine's
~37-file working subset) carried a different 37-line index. Hand-merging
those two indexes safely on every sync is the clobber trap.

## Why this decision

Deriving the index from the files ends the clobber **class**, not just an
instance:

- The index can no longer drift from the file set — it IS the file set,
  recomputed. A sync that adds a file automatically gets an index line; a
  sync that removes one drops the line. No hand-merge step, nothing to
  clobber.
- It is **profile-agnostic**. If you run a second profile via
  `CLAUDE_CONFIG_DIR`, both wire their per-cwd memory dir to the same
  OPS store, so regenerating in place is correct whichever profile fires.
- It is **idempotent + deterministic**. Same files → byte-identical index
  on every machine, so git sees no spurious index churn.

The cost is that a file with no curated title falls back to a Title-Cased
filename (e.g. `feedback_aiosqlite_close_in_tests.md` →
"Feedback Aiosqlite Close In Tests"). That is cosmetic — the
`description:` (the real content) is preserved verbatim — and a curated
`title:` in frontmatter overrides it at any time. Acceptable tradeoff for
making 126 previously-invisible memories indexed.

## Implications

1. **Source of truth = frontmatter.** A memory file's `title:` +
   `description:` produce its index line. To change how a memory appears in
   the index, edit the file's frontmatter, not `MEMORY.md`.
2. **Never hand-edit `MEMORY.md`.** It is overwritten on every SessionStart.
   Any manual edit is lost on the next session.
3. **Tooling.**
   - `~/OPS/WORKFORCE/bin/ac-memory-index <DIR>` — regenerate
     `<DIR>/MEMORY.md`. `--check` prints to stdout without writing. Parses
     frontmatter by hand (no PyYAML dependency). Idempotent.
   - `~/OPS/.claude-config/hooks/memory-index.sh` — SessionStart hook
     that resolves the active memory dir
     (`$CLAUDE_CONFIG_DIR/projects/<encoded-cwd>/memory`) and runs the
     indexer. Best-effort + non-blocking, matching `pre-compact.sh`.
4. **One-time backfill (done 2026-06-25).** Existing files had no `title:`
   and frontmatter `description:` values that differed from the curated
   index hooks. A backfill wrote `title:` (= the curated index title) and
   `description:` (= the curated index hook) into each file's frontmatter —
   **additively, frontmatter only, bodies untouched** — so the generated
   line matches what was loaded that day. A reproduce-verify gate proved
   every existing index line was reproducible (zero line loss) BEFORE either
   real `MEMORY.md` was overwritten.
5. **Sync stays additive.** This does not change the sync mechanism — still
   additive `cp` + git, never `rsync --delete` (the mirror is the
   cross-machine union; runtime is a per-machine subset). The index is now
   self-healing on top of that additive base.

## Anti-decision (what this does NOT settle)

- The runtime→mirror **symlink migration** (collapsing the per-machine
  subset into the shared store) remains a separate, reviewed cutover — NOT
  done here.
- `settings.json` registration of the hook is **not** applied by the
  tooling; the snippet is provided for the Operator to add (mirrors how
  `pre-compact.sh` / `foreman-charter.sh` are registered).
- Pruning cadence + the promote/move/delete triage (Option A) are unchanged
  and still governed by `2026-05-13__memory-sync-doctrine.md`.

## Related

- `2026-05-13__memory-sync-doctrine.md` — the parent doctrine; its open MEMORY.md-format question
  (canonical MEMORY.md format) is resolved by this lesson.
- The additive-sync rule this builds on: mirror = union of all machines'
  memory, runtime = per-machine subset, sync is always additive
  (`cp` + git) and never `rsync --delete`.
