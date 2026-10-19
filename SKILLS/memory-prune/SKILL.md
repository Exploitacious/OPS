---
name: memory-prune
description: "Use when the operator says prune, audit, or sweep memory, the memories are cluttered, or relocate a lesson. Read-only classification, then execute on sign-off."
---

# Memory prune

Sweep OPS auto-memory (`~/OPS/.claude-memory/workspace-<workspace>/`) and route each entry to its correct home, retiring what no longer earns its place. Memory is captured liberally (`CONTEXT/how-i-work.md` P2), so it accumulates. This is the deliberate later pass that reroutes and prunes.

This is the audit-time half of the knowledge-placement taxonomy. The write-time half, the routing every agent applies as it works, lives in the memory section of `CONTEXT/core.md`. Both use the same homes; this skill applies them in bulk after the fact.

Every closeout already drains the cache continuously (pre-compact-synthesis hygiene: route this session's entries, purge terminal projects, evict to the budget). This skill is the deep audit for what that flush cannot judge: cross-entry duplication, doctrine drift, stale standing facts. Run it quarterly, after doctrine changes, or when the briefing shows flush debt closeouts are not clearing. It is not the default response to a full index.

## Guardrails

1. Read-only audit first, always. Run the classification workflow before touching a single file.
2. Never delete without explicit operator approval. Present the full action table and get a yes before any deletion. This is `how-i-work.md` P3, the irreversible-action gate: deleting a live-verified vendor fact forces painful re-discovery.
3. Additive before destructive (P3). For promote and move, the content lands in its new home and is verified there before the source file is removed. A move whose target project has a docs tree the team reads lands there by PR and leaves a one-line pointer in the lessons file. A repo this session owns gets its PR opened and merged in the same pass, so the source is removed once that PR lands; only a PR that must wait on someone else's review keeps the source flagged `PENDING-MIGRATION` until it merges. A project with no such repo folds into `CONTEXT/projects/<project>-lessons.md` in one OPS commit. Never delete on the promise of a future PR.
4. Verify the audit before trusting it (P3, P11). The counts must reconcile: keep + promote + move + discard equals the total. Spot-check that no discard is a live vendor, host, or cred fact, and read the workflow's risky-discard review.
5. Generic tech truths stay personal. A gotcha spanning many projects (a Postgres quirk, say) belongs to no single repo. Keep it in personal memory.

## The six homes

Each entry resolves to exactly one. Route by what the lesson generalizes to, not where it was learned: a universal verification lesson can look project-tied only because its worked example came from one project. Do not classify from keywords.

- keep. Stays in personal auto-memory: cross-project gotchas, harness and tooling behavior, host and cred pointers, model-behavior calibration, personal project-state notes, generic tech truths.
- promote. A universal pattern for any project or agent, folded into OPS doctrine or a skill (`CONTEXT/how-i-work.md` Principles, `SKILLS/`). If it is already in a doctrine principle, it is a discard ("already in Pn"), not a promote.
- move (fold). A reusable lesson tied to one project's code, vendor, or infra, landed in that project's own docs when its repo has a docs tree the team reads (a `docs/` directory, a `GOTCHAS.md` beside the code), by PR in that repo, with a one-line pointer in `CONTEXT/projects/<project>-lessons.md`; otherwise appended to the lessons file itself (synced, loaded on demand, launch-dir-independent). A public repo never receives hosts, keys, people, clients, or ticket numbers: that content stays in the lessons file of a private repo.
- standing-order. An operator ruling, a policy, permission, scope closure, or design law, added to `CONTEXT/standing-orders.md` when it binds every session, or to its domain's lessons file when it binds only that domain. A ruling left in a recall-based cache gets broken the session recall does not fire. Test: if breaking it would be wrong rather than unlucky, it is a standing order, not a gotcha.
- split. An entry whose durable content belongs to several projects with the per-project parts dominating. Fold each part into its own `<project>-lessons.md`, then delete the entry. This is move applied more than once; it earns its own name so an agent does not force a genuinely multi-project entry into one arbitrary lessons file. If the cross-project pattern is the point and the per-project details are incidental, that is keep or promote, not split.
- discard. Stale, superseded, resolved-and-closed, one-conversation-only, already-in-doctrine, or duplicate. The reason must justify it.

The audit workflow classifies four ways (keep/promote/move/discard). Standing-order and split are dispositions you apply during sign-off: a workflow "keep" that is really a ruling becomes standing-order; a "move" whose content spans several projects becomes split. Surface both when you present.

## How to run

1. Audit, read-only. First read `~/.claude-compact-cycle/memory-flush-queue`: any lines are entries a closeout flagged but never dispositioned (flush debt), priority inputs that each must appear in the table with an explicit disposition. Then run `bash scripts/inventory` (this folder) for the pool-level view: entries, index size against the 24KB limit, and newest-content age per pool, with over-limit, empty, and stale pools staged as candidates (it never deletes). Then run `audit_workflow.js` (this folder) via the Workflow tool for the entry-level classification; it keeps its own agent-driven listing of the one pool it audits, because a Workflow script cannot shell out to the inventory. It inventories every entry, fans out parallel classifiers (each reads the live `how-i-work.md` principles and `core.md`, so "already promoted" checks never go stale), and emits the action table. Pass the memory dir as `args.dir` if it differs from the default.
2. Present and sign off. Show the counts, the full discard list verbatim (these are deletions), the promote and move groupings, and the risky-discard review. Get explicit approval. Surface edge cases: generic-versus-project, resolved-but-referenced, and any keep that is really a standing-order or split.
3. Execute, additive first.
   - promote: integrate into the target doctrine or skill sequentially, never in parallel (they touch overlapping shared files). Then remove the source. A promote into a mounted skill is edited at the skill's source repo under `PROJECTS/` and synced with `skills-vendor.sh` (`SKILLS/VENDORED.tsv` is the manifest), never in the `SKILLS/` mirror, because the sync overwrites a hand-edited mirror.
   - move (fold): when the target project's repo has a docs tree the team reads, land the lesson there by PR (preserve exact specifics verbatim: PR numbers, paths, picklists, vault paths) and leave a one-line pointer in `<project>-lessons.md`; a repo this session owns gets its PR opened and merged in the same pass and the source removed once it lands, while a PR that must wait on someone else's review keeps the source flagged `PENDING-MIGRATION` until it merges. A project with no such repo folds into `<project>-lessons.md` (create it if absent, same verbatim specifics), verify it landed, then delete the source. For a large multi-project fold, drive it with a per-project drafting workflow (`model: 'sonnet'`) that returns per-file dispositions, and verify every entry is dispositioned exactly once before applying.
   - discard: delete after approval.
   - keep: leave it; commit any untracked keepers.
4. Rebuild MEMORY.md. The index is a generated artifact; regenerate it, never hand-edit. Every `- [Title](file.md)` line reproduces that file's frontmatter `description:` verbatim, and the harness rebuilds the index from the files on its own schedule, so a hand-edited index gets silently reverted (an in-place edit of the index reverted within minutes on one occasion; the one survivor was the line whose file `description:` had been edited). After the sources are deleted or edited: adjust each survivor's `description:` frontmatter (including any `PENDING-MIGRATION` note; quote the value if it contains a colon), then rewrite the index atomically with the SessionStart indexer: `MEMORY_INDEX_DEBUG=1 MEMORY_INDEX_DIR=<memory-dir> ~/OPS/.claude-config/hooks/memory-index.sh </dev/null` (debug on so a failed regeneration prints instead of vanishing). Mirror every change into MEMORY.md so the next unattended rebuild is a no-op. If a hand-edit is ever unavoidable, anchor parsing on the `](file.md)` link boundary, never on the dash separator (titles can contain dashes; a split on the separator once truncated a title and dropped its link), then verify a byte-identical prefix diff across all entries.
5. Drain the flush queue. Delete every `~/.claude-compact-cycle/memory-flush-queue` line whose entry the prune dispositioned. The queue should be empty when the prune commits: a line left behind reads as an unevaluated entry to every later session.
6. Stamp the cadence. Record completion, even on a prune that changed nothing (audited and all correctly homed is a result), so the next prune can tell how long ago the last one ran:
   ```bash
   mkdir -p ~/.local/state/ops && date -Is > ~/.local/state/ops/last-memory-prune
   ```
7. Commit. One clean commit in OPS; project-repo moves are separate PRs in their own repos.

## Anti-patterns

- Deleting before the content is safely in its new home.
- Parallelizing the promote integrations (shared-file merge conflicts; serialize them).
- Discarding a live vendor, host, or cred fact because it looks narrow.
- Moving a generic cross-project truth into one project repo (it loses cross-project visibility; keep it personal).
- Running the destructive phase without the read-only audit and sign-off.

## See also

- `CONTEXT/core.md`, the memory section. The write-time routing this skill enforces after the fact.
- `CONTEXT/how-i-work.md` P2 (write memory liberally), P3 (additive over destructive, irreversible-action gate), P12 (orchestration tiers; this is a workflow-tier job).
- The `dynamic-workflows` skill (mounted from the skill sources) for the workflow-authoring patterns `audit_workflow.js` uses.
- Run the prune from a Claude Code session: the audit runs through the Workflow tool, and the flush queue is a Claude Code surface.
