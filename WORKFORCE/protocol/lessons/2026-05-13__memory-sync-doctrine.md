---
id: 2026-05-13__memory-sync-doctrine
date: 2026-05-13
author: Captain
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
---

# Auto-memory git-sync + Option A doctrine — Operator decisions

## Decision

Auto-memory will move from per-host `~/.claude/projects/<encoded>/memory/` to a git-tracked location under `~/OPS/.claude-memory/<encoded>/`. The original path becomes a symlink. Memory then syncs across machines via `git pull`/`push`.

Doctrine: **Option A — drafts that graduate.** Auto-memory is the AI's working notes / staging area. `CONTEXT/` remains the canonical user-identity / working-preferences / doctrine layer. Periodic prune promotes stable memories into `CONTEXT/`, moves project-specific ones into project docs, and deletes stale entries.

## Context

Surfaced during a working session where the Coordinator wrote three auto-memory entries mid-conversation; the Operator asked whether memory should be git-tracked, which Claude flavors it should serve, and what the pruning model looks like. Two interpretations were on the table (Option A = drafts graduate; Option B = flat-with-overrides).

## Why this decision

Rationale captured:

- Option A preserves the existing doctrine pattern — `CONTEXT/` stays the source of truth for user identity / preferences / doctrine. Auto-memory becomes a staging layer beneath it.
- The Operator primarily uses Claude Code; cross-flavor bridges (chat Claude, Claude Cowork (Anthropic's desktop app) on Windows if different, Claude Desktop) are out of scope for v1.
- Symlink works on both Linux (`ln -s`) and Windows (`mklink /D`). Stow remains optional convenience but not required.
- Secrets-scan urgency is low for v1: the hard rule still applies (no credentials, no client PII, ever), but a pre-commit scan is deferred rather than shipped in v1.

## Implications

1. **Scope of v1.** Claude Code instances only. Windows + Linux. Chat Claude + Claude Desktop bridges deferred indefinitely (file an IDEA if the need surfaces).
2. **Mechanism.**
   - Linux: `~/.claude/projects/<encoded>/memory/` → symlink → `~/OPS/.claude-memory/<encoded>/`.
   - Windows: same shape, `mklink /D` instead of `ln -s`.
   - One-time move + symlink per machine.
3. **Git tracking.** `~/OPS/.claude-memory/` is git-tracked. `.gitignore` must NOT ignore it.
4. **Doctrine layer (Option A).**
   - `CONTEXT/` = canonical (user-identity, working-preferences, doctrine, project-kata, fleet-doctrine). Operator-owned.
   - `~/OPS/.claude-memory/` = staging area. AI-authored, Operator-visible via git diff. Promotable.
   - Promotion path: stable + cross-cutting auto-memory → move content into appropriate `CONTEXT/` file → delete the auto-memory entry.
   - Move path: project-specific auto-memory → relocate into `PROJECTS/<repo>/docs/` or `WORKFORCE/<project>/runtime/`. Delete the auto-memory entry.
   - Keep path: transient personal recall that isn't yet stable enough to promote. Stays as auto-memory.
   - Delete path: stale, wrong, superseded.
5. **Pruning workflow.** Implementation deferred per Operator ("agree on pruning, but we can handle this later"). Captured as a follow-up — likely a `~/OPS/WORKFORCE/bin/ac-memory-prune` helper that walks the dir, presents each entry for triage, runs the chosen action, shows the diff.
6. **Secrets / PII hard rule** (lighter than full pre-commit scan, but doctrine-binding):
   - No credentials, API keys, passwords, tokens in auto-memory. Ever.
   - No client PII (names + sensitive context together; first names alone in working-context are fine).
   - No personal medical / financial / family-sensitive content.
   - Pre-commit hook scan is a deferred enhancement (filed as follow-up IDEA).
7. **Cross-machine reconciliation.** When two machines write memory and both try to push: standard git merge. Memory files are independent; conflicts will be rare. Worth noting in docs but not designing around.

## Cross-flavor reach (explicit non-coverage)

- **Claude Code (Linux / WSL / macOS / Windows)** — covered by v1.
- **Cowork on Windows** — verify mechanism before committing the sync claim. Likely same as Claude Code.
- **Chat Claude (claude.ai)** — NOT covered. Different mechanism (Projects feature). If bridge ever wanted, file as new IDEA.
- **Claude Desktop** — NOT covered. Verify before promising future bridge.

## Anti-decision (what this does NOT settle)

- Implementation timing (Operator deferred to "later"; lives as a READY HIGH-priority IDEA).
- The `ac-memory-prune` helper design (deferred follow-up).
- Pre-commit secrets-scan hook (deferred follow-up).
- Chat Claude or Claude Desktop bridges (out of scope; file new IDEA if needed).
- Exact pruning cadence (proposed quarterly in the improvement note; not yet doctrine).
- Whether `MEMORY.md` should be in a fixed canonical format vs free-form (status quo: free-form bullet list).

## Follow-ups filed

- Backlog / idea-tracking file — promoted "Git-track Claude auto-memory" to `READY (HIGH PRIORITY)` with full Task Intake Format block.
- Related improvement note status flipped to `settled` (will be done by Captain in the same turn that filed this decision).
