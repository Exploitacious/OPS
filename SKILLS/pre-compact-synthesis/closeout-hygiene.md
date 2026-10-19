# Closeout hygiene, in full

Read when running the fifth stage. The body carries the steps in one line each; this file carries the detail, the memory-routing table, and the migration vectors. The operator's standing rule: a dirty, undocumented, sprawling working environment is the thing to prevent. The four artifacts make state durable; this stage makes the workspace clean and the docs true. Skip on bare conversational sessions; nothing to clean is a valid outcome.

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

Memory is a write cache, not an archive: the routing is in the memory section of `CONTEXT/core.md`, and this step is where the cache gets evicted. It is a gate with three parts.

When a captured lesson proposes a skill change, review the evidence and the current skill before promoting it (the mounted `meta-skill-creator` carries a learning-from-work procedure when its source ships one). Keep candidates distinct from operator rulings and honor existing scope.

This session's entries plus the flush queue. Read `~/.claude-compact-cycle/memory-flush-queue` (the write-time nudge upserts flagged entries there, one line per memory file), plus `git -C ~/OPS status --short -- .claude-memory/` and the active profile's pool. Every queue line gets one of five dispositions, then the line is DELETED either way. A line left in the queue is not a disposition; it reads as an unevaluated entry to every later session.

| disposition | means | entry |
|---|---|---|
| folded | durable, tied to ONE project | to that project's own docs tree by PR when the repo has one the team reads (a pointer left in its lessons file), else to `CONTEXT/projects/<project>-lessons.md`; source deleted once it lands |
| split | multi-project whose per-project parts dominate | to each lessons file, deleted |
| kept | genuinely cross-project (harness or tooling behavior, host pointer, model calibration, tech truth spanning projects) | stays in the pool |
| promoted-to-doctrine | a UNIVERSAL pattern (a verification habit, a foreman rule, a brief discipline) | to `CONTEXT/how-i-work.md` Principles or the SKILL, deleted |
| promoted-to-standing-orders | an operator RULING (a policy, permission, scope closure, design law) | to the operator's standing orders (the file or section `CONTEXT/how-i-work.md` points to) when it binds every session, else to its domain's lessons file, deleted |

Ask the last two explicitly per line: is this universal? is this a ruling? A universal habit and a project lesson read identically from the inside, and no content heuristic separates them. The two promotion dispositions exist because "kept" silently absorbs both classes otherwise: a routing audit found that most of the entries it moved out of a pool were exactly those two. Single-project material folds to that project's own docs tree by PR when the repo has one the team reads (a pointer stays in its lessons file), else into `CONTEXT/projects/<project>-lessons.md`, and the source entry is deleted once it lands; the startup read-order already routes project sessions to their lessons file. Deferring the evaluation to `/memory-prune` is NOT a disposition. The prune drains leftover queue lines as a quarterly backstop, not the routine path; treating it as routine is what produces a backlog.

Terminal projects. Any project touched this session that is now CLOSED, SHIPPED, or PARKED: fold whatever is durable from its memory entries to that project's home per the routing above, then delete the entries and their index lines. Closed projects hold no cache lines.

Budget check. If MEMORY.md exceeds the ~20KB soft budget, evict the stalest entries down to budget (fold first if durable, then delete). Deletion is safe; the mirror is git-synced, nothing is lost.

Whenever you update a memory entry's BODY, update its frontmatter `description:` in the same edit. MEMORY.md is a DERIVED artifact: the SessionStart `memory-index.sh` hook regenerates it from frontmatter every boot, so an index-only edit silently reverts. Frontmatter is the only durable layer. Regenerate the index mid-session with `MEMORY_INDEX_DEBUG=1 MEMORY_INDEX_DIR=<mem-dir> ~/OPS/.claude-config/hooks/memory-index.sh </dev/null` if you need it current.

## 3. Docs reflect reality, per repo touched

For each repo this session changed: does CHANGELOG.md have a line for what landed? Is any IDEAS.md or backlog entry now shipped and removable? Did the change make any README or doc claim false? Fix in the same closeout. "I'll fix the docs in a follow-up" is the P1 violation this stage exists to kill.

## 4. Sweep the scratch

Temp files at repo roots or `$HOME` that this session created get deleted (if disposable) or moved to their real home (if deliverables). Never delete something you did not create this session without operator approval.

Branches and worktrees are not swept by hand. Where `~/OPS/.claude-config/bin/branch-gc` is installed (an optional tool; not every copy has it), run `branch-gc --apply <repo>` on each repo this session touched and surface any report row it produced (a merged branch in a dirty worktree, the main checkout left on a merged branch). Without it, list merged branches with `git branch --merged <default-branch>` and remove only a local branch whose PR merged, with `git branch -d`, which refuses a branch the default branch does not already hold. Never delete a pushed branch or a worktree you did not create without the operator's word.

## 5. Reconcile pending items

Pending work lives in each repo's backlog file (`IDEAS.md`, per `CONTEXT/project-kata.md`), and the operator reads those files between sessions, so a stale line costs them trust. Three moves every closeout, in each repo this session touched:

- Delete any line this session's work or an operator statement completed or obsoleted (delete a line the moment it is done; a checked box is a graveyard).
- Correct any line whose facts drifted (counts, gates, what is actually blocking).
- Route new pending work to the home the repo's backlog convention names, keeping operator actions (things only the operator can do), agent follow-ups, and open decisions apart so each reader finds only what is theirs.

## 6. Update the operator's notes vault (optional)

Skip this step when the operator keeps no notes vault (`NOTES/MASTER/` is the vault location OPS expects). Where one exists, follow the vault's own conventions for two moves, and commit nothing from it unless the operator asks:

- Append this segment's rollup to the day's session note, creating it if absent.
- Sweep the vault's inbox to zero: every captured line routed to a ticket, a task, a vault note, or an answer, then deleted, since a line left there reads as untriaged to the next session.

An open question in the vault may already carry its answer written inline under it. Read open questions too, and act on any answered one.

## 7. Stamp the closeout

`mkdir -p ~/.local/state/ops && date -Is > ~/.local/state/ops/last-closeout`. Session-briefing surfaces the age of this stamp, so future sessions and the operator can see when hygiene last ran.

## Migration closeout: kill the four regression vectors

When the session shipped a migration or refactor (renamed a pattern, removed a schema, replaced a convention), step 3's prose-doc sweep is necessary but not sufficient. READMEs and architecture text describe reality; they do not stop a fresh agent from regenerating the old pattern. Four vectors actually cause an agent to rebuild what you removed (the pattern is universal, drawn from a real service-naming refactor). Walk all four before compacting.

1. The open TASKLIST/IDEAS entry. The migration started as an open `### PROJECT - <do X>` task. Left open, a fresh agent reads it as work-to-do and re-executes it. Flip it to `### SHIPPED - <X> (COMPLETE <date>)` with the result plus anything genuinely deferred.
2. The scaffold template. If the copier scaffold's example encodes the old pattern, every NEW component is born wrong regardless of doctrine. Verify the template emits the NEW pattern. Scaffolding rules live in `CONTEXT/project-kata.md`, the correctness bar for this vector.
3. The doctrine rule that produced the old pattern (a CLAUDE.md rule, a builder skill). Updating an example is not enough; rewrite the rule an agent follows when building so it forbids the old way.
4. Stale leftover dirs in a persistent checkout. `git mv` plus delete land on main, but old dirs linger as untracked cruft (`.venv`, caches, leftover `src/`) because git will not remove a dir containing untracked files. A fresh clone is fine; an agent reusing the checkout sees the old layout and gets confused. Confirm `git ls-files <dir>` shows 0 tracked files, then `rm -rf` the stale dirs.

Then mark the plan-of-record doc COMPLETE. Prose-doc accuracy is the last step of migration closeout, not the whole job.
