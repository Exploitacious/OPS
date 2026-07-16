---
name: Memory Prune
description: >
  Periodic audit + cleanup of OPS auto-memory. Fans out a read-only
  classification workflow over every memory entry, returns a
  keep/promote/move/discard action table, then executes the plan after
  Operator sign-off. Activates when the user says: prune memory, clean up
  memories, memory audit, memory sweep, "the memories are getting
  cluttered," or asks to relocate lessons to the right place. The
  audit-time counterpart to the write-time routing guide in
  CONTEXT/foreman-charter.md ("Where knowledge goes"). Claude Code only
  (uses the Workflow tool).
---

# Memory Prune

You are sweeping the Operator's OPS auto-memory
(`~/OPS/.claude-memory/workspace-<workspace>/`). Memory is captured
liberally and often (operating-doctrine P2), so it accumulates — this
skill is the deliberate later pass that routes each entry to its correct
home and retires what no longer earns its place.

This is the **audit-time** half of the knowledge-placement taxonomy. The
**write-time** half — the routing every agent applies as it works — lives
in `CONTEXT/foreman-charter.md` § "Where knowledge goes." Both use the
same four homes; this skill just applies them in bulk after the fact.

**Positioning (2026-07-16):** routine drainage now happens continuously —
every closeout runs the cache flush (`pre-compact-synthesis` skill
§ "The fifth stage — closeout hygiene," step 2: route this session's
entries + the flush queue, purge terminal projects, evict to the 16KB
budget — per foreman-charter § "Eviction"; deletions, not stubs). This
skill is the DEEP audit for what the continuous flush can't judge:
cross-entry duplication, doctrine drift, stale standing facts. Run it
quarterly, after doctrine changes, or when the session-briefing shows
flush debt (index over the 16KB soft budget) that closeouts aren't
clearing — not as the default response to a full index.

## Hard guardrails (do not skip)

1. **Read-only audit first, always.** Run the classification workflow
   (below) before touching a single file. It only reads + classifies.
2. **Never delete without explicit Operator approval.** Present the full
   keep/promote/move/discard table and get a yes before any deletion.
   This is operating-doctrine P3 (irreversible-action gate) — deleting a
   live-verified vendor fact forces painful re-discovery.
3. **Additive before destructive (P3).** For `promote` and `move`, the
   content lands in its new home *first* (and is verified there) before
   the memory file is removed. A `move` folds into OPS
   `CONTEXT/projects/<project>-lessons.md` — one repo, one commit, no
   cross-repo PR dance. (Only an exception fold targeting a separate team
   repo's `docs/` keeps the source flagged `PENDING-MIGRATION` until that
   repo's PR lands — never delete on the promise of a future PR.)
4. **Verify the audit before trusting it (P3, P11).** The workflow's
   counts must reconcile (keep + promote + move + discard = total). Spot-
   check that no `discard` is actually a live vendor/host/cred fact. The
   workflow self-reports a risky-discard review — read it.
5. **Generic tech truths stay personal.** A gotcha that spans many
   projects (e.g. a Postgres/psycopg quirk) belongs to no single repo →
   keep it in personal memory, do not force it into one project.

## The four homes (classification taxonomy)

Mirror of the charter's routing. Each entry resolves to exactly one:

- **keep** — stays in personal auto-memory. Cross-project gotchas,
  harness behavior, host/cred pointers, model-behavior calibration,
  personal project-state notes, generic tech truths.
- **promote** — a *universal* pattern → OPS doctrine or a skill
  (`operating-doctrine.md`, `fleet-doctrine.md`, `SKILLS/...`). If it is
  *already* in a doctrine principle, it is a `discard` ("already in Pn"),
  not a promote.
- **move (fold)** — a reusable lesson tied to one project's code/vendor/infra
  → that project's **`CONTEXT/projects/<project>-lessons.md`** (in OPS,
  synced, loaded on-demand, launch-dir-independent). DEFAULT home for project
  knowledge. *Exception:* a repo with an active human team reading its own
  `docs/` MAY keep it there instead (operator's per-project call).
- **discard** — stale / superseded / RESOLVED-and-closed / one-
  conversation-only / already-in-doctrine / duplicate. Reason must
  justify it.

## How to run

1. **Audit (read-only workflow).** Run the script in
   `audit_workflow.js` (this directory) via the Workflow tool. It
   inventories every entry, fans out parallel classifiers in batches
   (each reads the live `operating-doctrine.md` + `foreman-charter.md` so
   "already promoted" checks never go stale), then a synthesis agent
   dedups and emits the action table. Pass the memory dir as `args` if it
   differs from the default.
2. **Present + sign-off.** Show the Operator the counts, the full discard list
   (verbatim — these are deletions), the promote/move groupings, and the
   risky-discard review. Get explicit approval. Surface any edge cases
   (generic-vs-project, RESOLVED-but-referenced).
3. **Execute, additive-first.**
   - *promote*: integrate into the target doctrine/skill, sequentially
     (these touch overlapping shared files — do NOT parallelize, per the
     serial-merge lesson). Then remove the source memory file.
   - *move (fold)*: append the lesson into
     `CONTEXT/projects/<project>-lessons.md` (create the file if absent;
     preserve exact specifics — PR#s, paths, picklists, vault paths —
     verbatim), verify it landed, then delete the source memory file. For a
     large multi-project fold, use the WS-6 method: a per-project drafting
     workflow (`model: 'sonnet'` = Sonnet 5 1M) drafts each lessons file +
     returns per-file dispositions; verify coverage (every entry
     dispositioned exactly once) before applying. (Exception team-repo
     `docs/` fold → PR + `PENDING-MIGRATION` as in guardrail 3.)
   - *discard*: delete after approval.
   - *keep*: leave; commit any untracked keepers.
4. **Update `MEMORY.md`.** The index is a GENERATED artifact — regenerate
   it, don't hand-edit it (see
   `WORKFORCE/protocol/lessons/2026-06-25__memory-index-generated.md`).
   After the source files are deleted/edited, adjust each survivor's
   `description:` frontmatter as needed (including `PENDING-MIGRATION`
   annotations), then re-run `WORKFORCE/bin/ac-memory-index <memory-dir>`,
   which rewrites the index atomically from frontmatter. If a hand-edit is
   ever unavoidable, anchor line parsing on the `](file.md)` link
   boundary, never on the first em-dash — the
   `- [Title](file.md) — description` format doesn't guarantee the first
   em-dash is the separator; titles themselves can contain em-dashes (a
   2026-07-06 bulk shortening pass split on the em-dash, truncated such a
   title, and dropped its markdown link entirely). Verify with
   `ac-memory-index --check <memory-dir>` and confirm the output is
   byte-identical to the file you wrote before committing.
5. **Commit.** One clean commit (or tight series) in OPS; project-repo
   moves are separate PRs in their own repos.

## Anti-patterns

- Deleting before the content is safely in its new home.
- Parallelizing the promote integrations (shared-file merge conflicts —
  serialize).
- Discarding a live vendor/host/cred fact because it "looks narrow."
- Moving a generic cross-project truth into one project repo (loses
  cross-project visibility — keep it personal).
- Running the destructive phase without the read-only audit + sign-off.

## See also

- `CONTEXT/foreman-charter.md` § "Where knowledge goes" — the write-time
  routing this skill enforces after the fact.
- `CONTEXT/operating-doctrine.md` P2 (write memory liberally), P3
  (additive-over-destructive + irreversible-action gate), P12
  (orchestration tiers — this skill is a Tier-3 workflow).
- `SKILLS/agent-delegation/05_dynamic_workflows.md` — the workflow
  authoring patterns this skill's script uses.
