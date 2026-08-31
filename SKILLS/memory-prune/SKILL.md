---
name: memory-prune
description: >
  Use when the operator says prune memory, clean up memories, memory audit,
  memory sweep, "the memories are getting cluttered," or asks to relocate a
  lesson to its right home. Deep audit of OPS auto-memory: fans out a
  read-only classification workflow over every entry, returns a
  keep/promote/move/standing-order/split/discard action table, then executes
  the plan after operator sign-off. The audit-time counterpart to the
  write-time routing in CONTEXT/foreman-charter.md. Claude Code only (uses the
  Workflow tool).
---

# Memory prune

Sweep OPS auto-memory (`~/OPS/.claude-memory/workspace-<workspace>/`) and route each entry to its correct home, retiring what no longer earns its place. Memory is captured liberally (operating-doctrine P2), so it accumulates. This is the deliberate later pass that reroutes and prunes.

This is the audit-time half of the knowledge-placement taxonomy. The write-time half, the routing every agent applies as it works, lives in `CONTEXT/foreman-charter.md` § "Where knowledge goes." Both use the same homes; this skill applies them in bulk after the fact.

Every closeout already drains the cache continuously (pre-compact-synthesis hygiene: route this session's entries, purge terminal projects, evict to the budget). This skill is the deep audit for what that flush cannot judge: cross-entry duplication, doctrine drift, stale standing facts. Run it quarterly, after doctrine changes, or when the briefing shows flush debt closeouts are not clearing. It is not the default response to a full index.

## Guardrails

1. Read-only audit first, always. Run the classification workflow before touching a single file.
2. Never delete without explicit operator approval. Present the full action table and get a yes before any deletion. This is operating-doctrine P3, the irreversible-action gate: deleting a live-verified vendor fact forces painful re-discovery.
3. Additive before destructive (P3). For promote and move, the content lands in its new home and is verified there before the source file is removed. A move folds into one OPS file in one commit, no cross-repo dance. Only a fold into a separate team repo's `docs/` keeps the source flagged `PENDING-MIGRATION` until that repo's PR lands. Never delete on the promise of a future PR.
4. Verify the audit before trusting it (P3, P11). The counts must reconcile: keep + promote + move + discard equals the total. Spot-check that no discard is a live vendor, host, or cred fact, and read the workflow's risky-discard review.
5. Generic tech truths stay personal. A gotcha spanning many projects (a Postgres quirk, say) belongs to no single repo. Keep it in personal memory.

## The six homes

Each entry resolves to exactly one. Route by what the lesson generalizes to, not where it was learned: a universal verification lesson can look project-tied only because its worked example came from one project. Do not classify from keywords.

- keep. Stays in personal auto-memory: cross-project gotchas, harness and tooling behavior, host and cred pointers, model-behavior calibration, personal project-state notes, generic tech truths.
- promote. A universal pattern for any project or agent, folded into OPS doctrine or a skill (`operating-doctrine.md`, `fleet-doctrine.md`, `SKILLS/`). If it is already in a doctrine principle, it is a discard ("already in Pn"), not a promote.
- move (fold). A reusable lesson tied to one project's code, vendor, or infra, appended to that project's `CONTEXT/projects/<project>-lessons.md` (synced, loaded on demand, launch-dir-independent). The default home for project knowledge. A repo with an active human team reading its own `docs/` may target that repo instead.
- standing-order. An operator ruling, a policy, permission, scope closure, or design law, added to the Standing Orders section of `CONTEXT/working-preferences.md` (a mandatory startup read). A ruling left in a recall-based cache gets broken the session recall does not fire. Test: if breaking it would be wrong rather than unlucky, it is a standing order, not a gotcha.
- split. An entry whose durable content belongs to several projects with the per-project parts dominating. Fold each part into its own `<project>-lessons.md`, then delete the entry. This is move applied more than once; it earns its own name so an agent does not force a genuinely multi-project entry into one arbitrary lessons file. If the cross-project pattern is the point and the per-project details are incidental, that is keep or promote, not split.
- discard. Stale, superseded, resolved-and-closed, one-conversation-only, already-in-doctrine, or duplicate. The reason must justify it.

The audit workflow classifies four ways (keep/promote/move/discard). Standing-order and split are dispositions you apply during sign-off: a workflow "keep" that is really a ruling becomes standing-order; a "move" whose content spans several projects becomes split. Surface both when you present.

## How to run

1. Audit, read-only. First read `~/.claude-compact-cycle/memory-flush-queue`: any lines are entries a closeout flagged but never dispositioned (flush debt), priority inputs that each must appear in the table with an explicit disposition. Then run `audit_workflow.js` (this folder) via the Workflow tool. It inventories every entry, fans out parallel classifiers (each reads the live `operating-doctrine.md` and `foreman-charter.md` so "already promoted" checks never go stale), and emits the action table. Pass the memory dir as `args.dir` if it differs from the default.
2. Present and sign off. Show the counts, the full discard list verbatim (these are deletions), the promote and move groupings, and the risky-discard review. Get explicit approval. Surface edge cases: generic-versus-project, resolved-but-referenced, and any keep that is really a standing-order or split.
3. Execute, additive first.
   - promote: integrate into the target doctrine or skill sequentially, never in parallel (they touch overlapping shared files). Then remove the source.
   - move (fold): append into `<project>-lessons.md` (create it if absent, preserve exact specifics verbatim: PR numbers, paths, picklists, vault paths), verify it landed, then delete the source. For a large multi-project fold, drive it with a per-project drafting workflow (`model: 'sonnet'`) that returns per-file dispositions, and verify every entry is dispositioned exactly once before applying. A team-repo `docs/` fold goes through that repo's PR with the source flagged `PENDING-MIGRATION`.
   - discard: delete after approval.
   - keep: leave it; commit any untracked keepers.
4. Rebuild MEMORY.md. The index is a generated artifact; regenerate it, never hand-edit. Every `- [Title](file.md)` line reproduces that file's frontmatter `description:` verbatim, and the harness rebuilds the index from the files on its own schedule, so a hand-edited index gets silently reverted (an in-place edit of the index reverted within minutes on one occasion; the one survivor was the line whose file `description:` had been edited). After the sources are deleted or edited: adjust each survivor's `description:` frontmatter (including any `PENDING-MIGRATION` note; quote the value if it contains a colon), run `WORKFORCE/bin/ac-memory-index <memory-dir>` to rewrite the index atomically, and mirror every change into MEMORY.md so the next unattended rebuild is a no-op. If a hand-edit is ever unavoidable, anchor parsing on the `](file.md)` link boundary, never on the em-dash separator (titles can contain em-dashes; a split-on-em-dash once truncated a title and dropped its link), then verify a byte-identical prefix diff across all entries.
5. Drain the flush queue. Delete every `~/.claude-compact-cycle/memory-flush-queue` line whose entry the prune dispositioned. The queue should be empty when the prune commits: a line left behind reads as an unevaluated entry to every later session.
6. Stamp the cadence. Record completion so the briefing stops nagging, even on a prune that changed nothing (audited and all correctly homed is a result):
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

- `CONTEXT/foreman-charter.md` § "Where knowledge goes". The write-time routing this skill enforces after the fact.
- `CONTEXT/operating-doctrine.md` P2 (write memory liberally), P3 (additive over destructive, irreversible-action gate), P12 (orchestration tiers; this is a Tier-3 workflow).
- The `dynamic-workflows` skill (mounted from the skill sources) for the workflow-authoring patterns `audit_workflow.js` uses.
