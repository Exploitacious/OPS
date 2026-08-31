# Closeout hygiene, in full

Read when running the fifth stage. The body carries the steps in one line each; this file carries the detail, the memory-routing table, and the migration vectors. The operator's standing order: a dirty, undocumented, sprawling working environment is the thing to prevent. The four artifacts make state durable; this stage makes the workspace clean and the docs true. Skip on bare conversational sessions; nothing to clean is a valid outcome.

## Work-log breadcrumb (before you flush)

A session can compact several times before it closes, and session-close needs the whole session's story, not just what is left after the last compact. The hook already appended a mechanical segment (git delta plus elapsed) to `~/.claude-compact-cycle/work-log-<KEY>`. Add ONE narrative line so the eventual close reads what happened. Skip entirely if nothing substantive happened this segment. This is a breadcrumb, not a second reconciliation gate. Compaction never logs time or touches a ticket.

```bash
. ~/OPS/.claude-config/hooks/hooklib.sh
KEY="$(work_session_key)"
{
  echo "## narrative $(date -Is)"
  echo "did: <one or two lines, what this segment accomplished>"
  echo "tracked: <any ticket/item id, board card, or task touched, or ->"
  echo ""
} >> "$HOME/.claude-compact-cycle/work-log-$KEY" 2>/dev/null || true
```

## 1. Machine gate

`~/OPS/.claude-config/bin/verify-ops.sh --quiet`. Every FAIL gets fixed now or explicitly surfaced to the operator with a reason. WARNs get fixed if under about two minutes each, otherwise surfaced. The gate is the definition of clean; do not free-hand your own checklist when the script exists.

## 2. Flush the memory cache

Memory is a write cache, not an archive (foreman-charter, Eviction). This step is a gate with three parts.

This session's entries plus the flush queue. Read `~/.claude-compact-cycle/memory-flush-queue` (the write-time nudge upserts flagged entries there, one line per memory file), plus `git -C ~/OPS status --short -- .claude-memory/` and the active profile's pool. Every queue line gets one of five dispositions, then the line is DELETED either way. A line left in the queue is not a disposition; it reads as an unevaluated entry to every later session.

| disposition | means | entry |
|---|---|---|
| folded | durable, tied to ONE project | to its lessons file, deleted |
| split | multi-project whose per-project parts dominate | to each lessons file, deleted |
| kept | genuinely cross-project (harness or tooling behavior, host pointer, model calibration, tech truth spanning projects) | stays in the pool |
| promoted-to-doctrine | a UNIVERSAL pattern (a verification habit, a foreman rule, a brief discipline) | to `operating-doctrine.md` / `fleet-doctrine.md` / the SKILL, deleted |
| promoted-to-standing-orders | an operator RULING (a policy, permission, scope closure, design law) | to `working-preferences.md` Standing Orders, deleted |

Ask the last two explicitly per line: is this universal? is this a ruling? A universal habit and a project lesson read identically from the inside, and no content heuristic separates them. The two promotion dispositions exist because "kept" silently absorbs both classes otherwise. Single-project material folds into `CONTEXT/projects/<project>-lessons.md` now and the entry is deleted with no stub; the startup read-order already routes project sessions to their lessons file. Deferring the evaluation to `/memory-prune` is NOT a disposition. The prune drains leftover queue lines as a quarterly backstop, not the routine path; treating it as routine is what produces a backlog.

Terminal projects. Any project touched this session that is now CLOSED, SHIPPED, or PARKED: fold whatever is durable from its memory entries into its lessons file, then delete the entries and their index lines. Closed projects hold no cache lines.

Budget check. If MEMORY.md exceeds the soft budget, evict the stalest entries down to budget (fold first if durable, then delete). Deletion is safe; the mirror is git-synced, nothing is lost.

## 3. Docs reflect reality, per repo touched

For each repo this session changed: does CHANGELOG.md have a line for what landed? Is any IDEAS.md or backlog entry now shipped and removable? Did the change make any README or doc claim false? Fix in the same closeout. "I'll fix the docs in a follow-up" is the P1 violation this stage exists to kill.

## 4. Sweep the scratch

Temp files at repo roots or `$HOME` that this session created get deleted (if disposable) or moved to their real home (if deliverables). Never delete something you did not create this session without operator approval.

Whenever you update a memory entry's BODY, update its frontmatter `description:` in the same edit. MEMORY.md is a DERIVED artifact: the SessionStart `memory-index.sh` hook regenerates it from frontmatter every boot, so an index-only edit silently reverts. Frontmatter is the only durable layer. Regenerate the index with `~/OPS/WORKFORCE/bin/ac-memory-index <mem-dir>` if you need it current mid-session.

## 5. Stamp the closeout

`mkdir -p ~/.local/state/ops && date -Is > ~/.local/state/ops/last-closeout`. Session-briefing surfaces the age of this stamp, so future sessions and the operator can see when hygiene last ran.

## Migration closeout: kill the four regression vectors

When the session shipped a migration or refactor (renamed a pattern, removed a schema, replaced a convention), step 3's prose-doc sweep is necessary but not sufficient. READMEs and architecture text describe reality; they do not stop a fresh agent from regenerating the old pattern. Four vectors actually cause an agent to rebuild what you removed (the pattern is universal, drawn from a real service-naming refactor). Walk all four before compacting.

1. The open TASKLIST/IDEAS entry. The migration started as an open `### PROJECT - <do X>` task. Left open, a fresh agent reads it as work-to-do and re-executes it. Flip it to `### SHIPPED - <X> (COMPLETE <date>)` with the result plus anything genuinely deferred.
2. The scaffold template. If the copier scaffold's example encodes the old pattern, every NEW component is born wrong regardless of doctrine. Verify the template emits the NEW pattern. Scaffolding rules live in `CONTEXT/project-kata.md`, the correctness bar for this vector.
3. The doctrine rule that produced the old pattern (a CLAUDE.md rule, a builder skill). Updating an example is not enough; rewrite the rule an agent follows when building so it forbids the old way.
4. Stale leftover dirs in a persistent checkout. `git mv` plus delete land on main, but old dirs linger as untracked cruft (`.venv`, caches, leftover `src/`) because git will not remove a dir containing untracked files. A fresh clone is fine; an agent reusing the checkout sees the old layout and gets confused. Confirm `git ls-files <dir>` shows 0 tracked files, then `rm -rf` the stale dirs.

Then mark the plan-of-record doc COMPLETE. Prose-doc accuracy is the last step of migration closeout, not the whole job.
