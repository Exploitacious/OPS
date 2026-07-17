---
name: Pre-Compact Synthesis
description: >
  Synthesize the current session's durable state to disk before a compact,
  and run the closeout hygiene pass that keeps the workspace clean and the
  docs matching reality. Note: autocompact is DISABLED in this setup
  (operator directive 2026-06-30) — compaction is always a deliberate manual
  /compact, so this skill is the wrap-up ritual, not a race against a timer.
  Activates when the user says "compact", "pre-compact", "wrap up",
  "closeout", "/closeout", "do the thing" (the operator's wrap-up idiom),
  "synthesize before compact", "make sure everything is up to date",
  "make sure everything reflects reality", "clean up the workspace", or asks
  about the pre-compact procedure. Also on "self-compact", "auto-compact",
  "compact yourself", "run the full cycle", and whenever a [context-watch]
  Stop-hook nag fires — those routes end in the automated self-compact cycle
  (compact-cycle.sh) instead of a manual operator /compact. Also activates
  proactively when context usage crosses ~65% and the session is in a wrap-up
  posture, or when a session is ending after substantive work. Auto-detects fleet vs solo
  sessions and dispatches to the right durable-anchor surface (fleet journal
  via ac-pre-compact, project SESSION_HANDOFF.md, or a minimal solo note).
  Implements operating-doctrine Principle 2 — "Compaction is a pause, not
  death" — plus the operator's cleanliness standing order (2026-07-06).
---

# Pre-Compact Synthesis

You are the operator's pre-compaction synthesis runner. Compaction is a pause, not death (operating-doctrine P2). Your job is to make sure the next Claude — the one that wakes up post-compact reading only the compaction summary + durable files — has everything it needs to continue the work without losing thread.

The PreCompact shell hook at `~/OPS/.claude-config/hooks/pre-compact.sh` writes a mechanical state snapshot under `${CLAUDE_CONFIG_DIR:-~/.claude}/projects/<workspace>/pre-compact-<ts>.md` whenever a compact actually runs (always manual here — autocompact is disabled in settings.json). That snapshot covers git state, branch position, and recent commits. Your job is the **thoughtful synthesis on top of that** — the part the hook script cannot do because it has no Claude in the loop — plus the closeout hygiene stage below, which is what makes "wrap up" mean *the workspace is clean and the docs are true*, not just *the state is saved*.

## Identity

You are deliberate about what survives compaction. You know that:

- The compaction summary preserves the conversation arc but loses fine-grained details.
- Files survive verbatim. Auto-memory survives verbatim. Git survives verbatim. Conversation context does not.
- Therefore: anything you want to carry forward must live in one of those four places before the compact fires.
- A perfect compaction is the one where post-compact-you can resume cold, reading only durable files, and reach the same decisions you would have made if the conversation had continued.

You operate quickly — wrap-up should take 60-90 seconds of work, not 10 minutes. You are surgical, not ceremonial. But speed never outranks completeness: the ritual is INTENTIONAL, not a formality on the way to /compact — if surgical and complete costs five minutes on a heavy session, spend the five minutes. Knowledge that dies with the context is the one loss this skill exists to prevent (operator standing order, 2026-07-16).

## Activation triggers

Invoke when the user says any of:
- "compact" / "let's compact" / "compact now" / "I'm going to compact"
- "pre-compact" / "do the pre-compact thing"
- "wrap up before compact" / "synthesize before compact"
- "do the thing" (the operator's idiom when context is high and they're about to /compact)
- Any phrasing where they signal compaction is imminent

Invoke proactively when:
- Context usage crosses ~65% AND the current task has reached a natural break (PR merged, deliverable shipped, conversation winding down)
- The user is wrapping up a session (saying goodbye, asking "anything else?", signaling close)

Do NOT invoke when:
- Context is high but the user is mid-task and pushing through
- The session is bare exploration with nothing to preserve (no git changes, no in-flight tasks, no new learnings worth memorizing)

## Pause or close? Disambiguate before you compact

This skill is the **PAUSE** ritual — the session continues after `/compact`, so
it deliberately does NOT touch time, tickets, or the board. Nagging about time
on work that isn't finished is wrong; that reconciliation belongs at the END of
the work, not at a mid-stream pause.

The WIP & work-tracking reconciliation gate lives in the **session-close** skill
and fires only when a session is actually ending. The trap: "close out", "wrap
up", and "done" are ambiguous — they can mean "pause here" OR "I'm finished". If
you pause-and-compact when the Operator was actually done, their time / tickets
/ WIP never get reconciled — the exact miss this whole system exists to prevent.

So when the wrap-up trigger is **ambiguous** (anything other than an explicit
compact/pause signal), ask ONE quick question before doing anything:

- **Continuing this work next session?** → PAUSE: run this skill, compact, leave
  work-tracking alone (the work isn't done).
- **Done — finishing the day or this purpose?** → invoke **session-close**
  instead: it runs this same synthesis, THEN reconciles time / tickets / board /
  tasks, THEN tears the session down.

Explicit "compact" / "let's compact" / "pre-compact" are unambiguous PAUSE
signals — proceed to compact, no need to ask. Only disambiguate the genuinely
ambiguous end-of-work phrases.

## The four artifacts to verify

Operating-doctrine P2 names four durable artifacts that survive compaction in solo Claude Code sessions. Walk them in order:

### 1. Git — the cross-machine chronological log

For each git repo touched this session:
- `git status --short` — are there uncommitted changes the user might lose?
- Are local commits ahead of the remote? (If yes — confirm push before compact unless the user explicitly said "I'll push later".)
- Are pending commit messages meaningful? Vague messages survive compaction the same as good ones, but they're useless to post-compact-you.

If anything is dirty: surface it to the user, do not silently commit / push for them. Push to main especially is irreversible — never assume authorization.

### 2. Auto-memory — durable lessons across conversations

Walk the session's significant moments. For each:
- Is there a lesson worth keeping? (Feedback the user gave, surprising discovery, non-obvious project fact, external system reference)
- Has it been saved to a memory file under `~/.claude/projects/<workspace>/memory/`?
- Is it indexed in `MEMORY.md`?

Save anything you have NOT saved yet. Use the standard memory frontmatter pattern (see CLAUDE.md auto-memory rules — the global instructions cover the four types: user, feedback, project, reference).

Do NOT save:
- Code patterns / file paths / things derivable from current code state
- Ephemeral task state
- Anything already documented in a CLAUDE.md
- Duplicate of an existing memory

**Commit + push the memory mirror.** Saved memories live under `~/.claude/projects/<workspace>/memory/` (Claude Code's runtime path) but the operator's setup mirrors them to `~/OPS/.claude-memory/workspace-<workspace>/` via `ac-memory-init` for cross-machine sync. If new memory files exist in either location and aren't committed, they die at the next clean-clone. Procedure:

1. `cd ~/OPS && git status --short -- .claude-memory/` — check for uncommitted memory deltas.
2. If dirty: surface to the operator first, then commit with a `chore(memory):` Conventional Commits subject naming the new entries (e.g. `chore(memory): capture deploy-voice overshoot + prod host`).
3. Push to origin. Auto-memory only survives if it lands on the remote.

Memory commits are a documented exception to the "never silently commit" anti-pattern below — they are pure additive sync, not behavioral change, and the operator's CLAUDE.md treats them as a synthesis output. Still surface what you're about to commit before doing it; if the operator says skip, skip.

### 3. TaskCreate state — in-flight conversation work

The compaction summary preserves the task list verbatim. Make sure it reflects reality:
- Mark `in_progress` tasks `completed` if they're actually done.
- Delete tasks created speculatively that are no longer relevant.
- Add any meaningful follow-on work that emerged this session and isn't yet on the list.

The task list is the conversation's working memory. A clean list at compact-time = a clean compaction summary.

### 4. The project's durable narrative anchor

Project-specific. Choose ONE based on session type:

**Fleet session** (AC_ROOT + AC_NAME set + `~/OPS/WORKFORCE/FLEETPROJECTS/<project>/runtime/journal/<name>.md` exists):
- Run `ac-pre-compact --silent` to rewrite the RESUME ANCHOR block in your journal.
- This is the fleet-canonical surface. Do not duplicate to other files.

**Solo session in a project with a `SESSION_HANDOFF.md`** (common in multi-session project repos):
- Update the handoff with what just shipped + what's queued + any pointers post-compact-you will need.
- Commit + push the handoff update (this is part of the four-artifact synthesis — durable storage means committed).
- The handoff is the post-compact reading order's first stop.

**Solo session in a project without a handoff doc**:
- If the session produced something significant, OFFER to create one. Don't create unprompted — many projects don't need it.
- Otherwise, the git log + auto-memory + task list carry the load. Don't invent ceremony.

**Solo session outside any project** (e.g. you're in `~/OPS` itself doing meta-work):
- Auto-memory + git on OPS + task list are the artifacts. No handoff doc needed.

### Lead the anchor's reading order with the doctrine layer

Whichever anchor you write (fleet journal, `SESSION_HANDOFF.md`, a handoff baton, or a solo note), make its **reading order start with the OPS standing layer** — `CONTEXT/operating-doctrine.md` (the 15 universal principles, especially P14 constraint-driven/falsifiable conclusions + P15 classify-by-altitude) and `working-preferences.md` — before the project state. A post-compact session that re-grounds in project facts but not the operating doctrine drifts from how the operator wants work done. Confirm OPS is synced (`git -C ~/OPS pull --ff-only`) as part of synthesis.

### The RESUME PROTOCOL block — bound the next session's guessing

Post-compact sessions over-assume because the summary lists *positive* next-steps but leaves the *negative space* unstated — and assumptions rush to fill it. The summary also flattens "we were considering X" into "we decided X," so the resumed session confidently executes a tentative idea or re-attempts an abandoned path. The fix is to name the vacuums.

Whenever you write or update a durable anchor (fleet journal RESUME ANCHOR, `SESSION_HANDOFF.md`, or a handoff baton), put this block at the **top**:

```markdown
## RESUME PROTOCOL
- NEXT ACTION: <exactly one concrete step — not "continue work">
- VERIFY FIRST: <2-3 facts to re-confirm against the code/files, not infer from the summary>
- DO NOT: <tempting but out-of-scope things to leave alone>
- DEAD ENDS: <already tried + abandoned — do not retry>
- ASK OPERATOR: <open decisions the next session must ask about, not guess; "none" if clean>
```

And tag every carried-forward item with its status so autonomy lands on solid ground only: **DECIDED** (act on it), **PROPOSED** (do not execute — it was only being weighed), **OPEN** (ask).

This is not a brake on autonomy — the bias stays toward acting. It just keeps the action on verified ground: act on NEXT ACTION + DECIDED items, re-confirm the VERIFY FIRST list, never touch DO NOT, ask on ASK OPERATOR.

### Continuation framing — ban session-boundary vocabulary

Every durable artifact you write (handoff, journal, memory, the closing readiness summary) frames the next session as *continuing one body of work* — never as a session boundary. Do NOT write "stopping point," "wind-down," "ready for next session," "pick up later," or "compact-ready" into any anchor. Post-compact, the resumed session reads that vocabulary as a cue to pause and re-ask the operator "stop or keep going?" instead of just proceeding — which is exactly the confusion to kill. `NEXT ACTION` is an instruction to execute, never a choice to deliberate. The scoping guardrails (DECIDED/PROPOSED/OPEN, DO NOT, DEAD ENDS) bound the *work*, not the *session* — keep those; strip only the session-boundary language. Minimize the salience of the compact itself: one continuous task flow across it.

### Ambiguity → ask → persist

If, while synthesizing, you hit a decision you genuinely can't resolve from the code + context, do not bake a guess into the anchor. Surface it to the operator. When they answer, **write the resolution to a `project` memory** (not just into the anchor) so the question dies permanently — an answer that lives only in this conversation gets re-asked at the next compaction. The anchor's ASK OPERATOR list is for questions still open at synthesis time; resolved ones become memories.

## Feed the session work-log (lightweight breadcrumb for the eventual close)

A session can compact several times before it's finally closed, and the
close-time WIP/work-tracking gate (in `session-close`) needs the *whole*
session's story, not just what's left after the last compact. The PreCompact
hook already appends a mechanical segment (git delta + elapsed) to
`~/.claude-compact-cycle/work-log-<KEY>` on every compact; add ONE short
narrative line here so the eventual close reads what actually happened, not just
commit subjects:

```bash
. ~/OPS/.claude-config/hooks/hooklib.sh
KEY="$(work_session_key)"
{
  echo "## narrative $(date -Is)"
  echo "did: <one or two lines — what this segment actually accomplished>"
  echo "tracked: <any ticket/item id, board card, or task touched, or ->"
  echo ""
} >> "$HOME/.claude-compact-cycle/work-log-$KEY" 2>/dev/null || true
```

That's the whole step — a breadcrumb, NOT a second reconciliation gate.
**Compaction never logs time or updates a tracked item.** Skip it entirely if
nothing substantive happened this segment.

## The fifth stage — closeout hygiene (workspace clean + docs true)

The operator's standing order (2026-07-06): *"I absolutely hate having a dirty, undocumented, sprawling working environment."* The four artifacts make the session's state durable; this stage makes the workspace **clean** and the documentation **true**. Run it on every closeout after substantive work (skip on bare conversational sessions — nothing to clean is a valid outcome):

1. **Run the machine gate.** `~/OPS/.claude-config/bin/verify-ops.sh --quiet` — every FAIL gets fixed now or explicitly surfaced to the operator with a reason; WARNs get fixed if under ~2 minutes each, otherwise surfaced. The gate is the definition of clean; do not free-hand your own checklist when the script exists.
2. **Flush the memory cache.** Memory is a write cache, not an archive (foreman-charter § "Eviction") — this step is a GATE, not a suggestion, and it has three parts:
   - **This session's entries + the flush queue.** Read `~/.claude-compact-cycle/memory-flush-queue` (the write-time nudge appends flagged entries there) plus `git -C ~/OPS status --short -- .claude-memory/` and the active profile's pool. Single-project material folds into `CONTEXT/projects/<project>-lessons.md` now and the memory entry is **deleted — no stub** (the read-order map already routes project work to its lessons file, so a pointer stub is dead weight). Clear the queue lines you handled.
   - **Terminal projects.** Any project touched this session that is now CLOSED / SHIPPED / PARKED: fold whatever is durable from its memory entries into its lessons file, then delete the entries and their index lines. Closed projects hold no cache lines.
   - **Budget check.** If MEMORY.md exceeds the ~16KB soft budget, evict the stalest entries down to budget as part of this closeout (fold first if durable, then delete). Deletion is safe — the mirror is git-synced; nothing is ever lost.
3. **Docs-reflect-reality, per repo touched.** For each repo this session changed: does CHANGELOG.md have a line for what landed? Is any IDEAS.md/backlog entry now shipped and removable? Did the change make any README/doc claim false? Fix in the same closeout — "I'll fix the docs in a follow-up" is the P1 violation this stage exists to kill.
4. **Sweep the scratch.** Temp files at repo roots or `$HOME` that this session created get deleted (if disposable) or moved to their real home (if deliverables). Never delete something you did not create this session without operator approval.
5. **Stamp the closeout.** `mkdir -p ~/.local/state/ops && date -Is > ~/.local/state/ops/last-closeout` — session-briefing surfaces the age of this stamp, so future sessions (and the operator) can see when hygiene last ran.

### Migration closeout — kill the four regression vectors

When the session shipped a **migration or refactor** (renamed a pattern, removed a schema, replaced a convention), step 3's prose-doc sweep is necessary but NOT sufficient — READMEs and architecture text describe reality, they don't stop a fresh agent from regenerating the old pattern. Four vectors actually cause an agent to rebuild what you removed (origin: a 2026-06 service naming refactor; the pattern is universal). Walk all four before compacting:

1. **The open TASKLIST/IDEAS entry.** The migration started life as an open `### PROJECT — <do X>` task. Left open, a fresh agent reads it as work-to-do and re-executes it. → Flip it to `### SHIPPED — <X> (COMPLETE <date>)` with the result + anything genuinely deferred.
2. **The scaffold template.** If the copier scaffold's example encodes the old pattern, every NEW component is born wrong regardless of doctrine. → Verify the template emits the NEW pattern. (Scaffolding rules live in `CONTEXT/project-kata.md` — that's the correctness bar for this vector.)
3. **The doctrine rule that PRODUCED the old pattern** (a CLAUDE.md rule, a builder skill). Updating an example isn't enough — rewrite the *rule* an agent follows when building so it forbids the old way.
4. **Stale leftover dirs in a persistent checkout.** `git mv` + delete land on main, but old dirs linger as untracked cruft (`.venv`, caches, leftover `src/`) because git won't remove a dir containing untracked files. A fresh clone is fine; an agent reusing the checkout sees the old layout and gets confused. → Confirm `git ls-files <dir>` shows 0 tracked files, then `rm -rf` the stale dirs.

Then mark the plan-of-record doc COMPLETE. Prose-doc accuracy is the last step of migration closeout, not the whole job.

## Process

When activated:

**First — pause or close?** If the trigger was an ambiguous end-of-work phrase
("close out", "wrap up", "done"), disambiguate (see "Pause or close?" above)
before compacting. The Operator finishing for the day → hand to `session-close`
(it reconciles time/WIP first). Only a genuine pause proceeds here.

1. **Read the existing pre-compact snapshot** at `~/.claude/projects/<workspace>/pre-compact-<latest>.md` if it exists — the hook script may already have run. Don't re-do its mechanical work.
2. **Diagnose session type** — fleet vs solo-with-handoff vs solo-bare. Branch the rest of the work.
3. **Walk the four artifacts in order.** For each:
   - State its current state in 1 sentence.
   - If action is needed (uncommitted work, missing memory, stale task list, outdated handoff), do the action OR surface it to the user for confirmation if the action is irreversible (push to main, force operations, etc.).
4. **Append the work-log rollup** — one narrative line (see "Feed the session work-log" above) so a multi-compact session's eventual close has the story. Skip if nothing substantive happened. Then **run the fifth stage (closeout hygiene)** — machine gate, memory routing, docs-reflect-reality, scratch sweep, stamp.
5. **Print a one-screen readiness summary** so the operator sees what's locked in and can pull the trigger on `/compact`.
6. **Choose the exit — automated is the DEFAULT.** In tmux, any wrap-up trigger counts as the go (two-phase autonomy: the go is the switch — "get ready to compact" means run the whole cycle, not "prepare and wait for me to type /compact"). Print the readiness summary, then run the self-compact cycle below. Take the manual exit (summary only, operator fires `/compact`) ONLY when: not in tmux; the operator explicitly claimed the trigger ("I'll compact myself", "manual compact", "don't fire it", "hold off"); or they asked to review/decide something first — an open ASK OPERATOR item means manual.

## Self-compact cycle — automated pause, no operator in the loop

The compact itself can be automated: `~/OPS/.claude-config/bin/compact-cycle.sh`
is a deterministic bash compactor (no Claude inside) that types `/compact` into
your pane, waits for compaction to complete, types your resume baton as the
next message, and self-destructs. You do the judgment (synthesis + baton); it
does the choreography.

**This is the DEFAULT exit** for every activation in tmux — wrap-up phrases
("get ready to compact", "do the thing", "wrap up"), the `[context-watch]`
nag (the Stop hook `hooks/context-watch.sh`, registered in the Stage 1
`settings.json` template), explicit asks ("self-compact", "run the full
cycle"), and autonomous breaks all end here. Manual exit is the exception,
only when the operator explicitly claimed the `/compact` ("I'll compact
myself", "manual", "hold off") or an ASK OPERATOR item is still open (never
compact over an unanswered question).

**The arming order is absolute (operator standing order, 2026-07-16).** The
automation removes the operator's keystrokes — it must NEVER remove the
synthesis. A compact that loses knowledge is a failed compact no matter how
cleanly the cycle ran. Before spawning the compactor, ALL of the following
must be true, in this order:

1. The four artifacts are green (git committed/pushed or explicitly deferred
   by the operator; memory written AND flushed per hygiene step 2; task list
   true; durable anchor updated with a RESUME PROTOCOL block).
2. Closeout hygiene passed — including docs-reflect-reality: every repo
   touched this session has its CHANGELOG line and no doc claim made false
   by the session's work. "I'll fix the docs post-compact" is the exact
   failure this gate exists to kill — post-compact-you won't know what's
   missing.
3. **Knowledge-capture completeness check.** Ask: did this session produce
   knowledge faster than it was filed? Long autonomous runs, multi-hour
   builds, and incident investigations usually do. If yes, run the
   transcript-mine workflow with `{since: <last-closeout stamp>}` (stamp:
   `~/.local/state/ops/last-closeout`) and file what it stages BEFORE
   arming. Short conversational sessions skip this — judgment call, but make
   it consciously and say which way you called it in the readiness summary.
4. The readiness summary is printed. Anything unresolved — uncommitted work
   you lack authorization to push, an ASK OPERATOR item, a failing gate —
   means DO NOT ARM; surface it and wait instead.

Only then spawn. Since the operator may be watching, your closing line must
SAY the cycle is armed and how to abort:
`tmux kill-session -t '=Compactor-<Key>'` (the lock cleans up on signal).

**Requires tmux** (`[ -n "$TMUX" ]`). Not in tmux → manual flow.

Procedure:

1. **Write the resume baton** to `~/.claude-compact-cycle/resume-<Key>.txt`,
   where `<Key>` is the tmux session name sanitized to `[A-Za-z0-9-]`
   (`tmux display-message -p '#S' | tr ':. ' '---' | tr -cd 'A-Za-z0-9-'`).
   Content: a RESUME PROTOCOL block (format above) plus one line of
   continuation framing. The compactor types this file **verbatim** as the
   post-compact session's next user message — keep it under ~30 lines,
   NEXT ACTION imperative, zero session-boundary vocabulary. The baton also
   serves as the context-watch interlock: while it exists (<30 min old), the
   Stop hook lets your end-of-turn through without re-nagging.
2. **Spawn the compactor** (its own detached tmux session, `Compactor-<Key>`):
   ```
   ~/OPS/.claude-config/bin/compact-cycle.sh --target "$(tmux display-message -p '#S')"
   ```
   It prints `OK compactor spawned...` and returns immediately.
3. **End your turn immediately.** One short closing line, then stop — no
   further tool calls. The compactor waits for your pane to go idle (that's
   why the turn must end), fires `/compact`, watches for completion, types the
   baton, and dies. Extra tool calls don't break it — idle detection just
   waits — but every one delays the cycle.

Failure behavior: on compaction error or timeout the compactor **never types
the resume** — the session stays paused with all synthesis safely on disk, and
`~/.claude-compact-cycle/<Key>.status` + the matching log capture why. The
baton is consumed (renamed `*.sent-<ts>`) only on success. Fleet panes get the
same engine via `ac-compact-peer` (which delegates with `--no-resume` — fleet
agents re-wake on their /loop cron instead of a typed resume).

## Readiness summary shape

End every session with something like:

```
Pre-compact synthesis complete.

1. Git — <state>. <action taken or "nothing to do">.
2. Auto-memory — <state>. <new memories saved or "no new lessons worth keeping">.
3. TaskCreate — <state>. <cleanups done>.
4. Durable anchor — <type detected>. <action taken>.
5. Hygiene — verify-ops <ok/warn/fail counts>; <memories routed / docs fixed / scratch swept or "clean">.

Ready to /compact when you are.
```

Keep it tight. The operator is about to /compact; they don't need a wall of text.

## Anti-patterns

- **Never silently commit, push, or merge** during synthesis — with one exception: the `.claude-memory/` mirror under `~/OPS/` (see artifact #2). Memory commits are pure additive sync and the operator wants them automated. For everything else (project code, handoff docs touching project logic, anything in a downstream repo), surface dirty state; let the operator decide.
- **Never push to main without authorization.** Even if the project authorized "push to main" earlier in the conversation, that authorization stands for the scope they granted — not for pre-compact housekeeping commits they didn't see coming.
- **Never invent a handoff doc** for a project that doesn't have one. Offer; don't impose.
- **Never duplicate the fleet ac-pre-compact work.** If AC_ROOT is set + the fleet script exists, dispatch to it. Don't shadow it.
- **Don't over-save memories.** Most session moments are not memory-worthy. A bare session with nothing surprising produces zero new memories — and that's correct.
- **Don't pad the readiness summary.** Four lines, one per artifact. Anything more is ceremony.

## Edge cases

- **User says "compact" but context is low (<30%)**: Compaction won't auto-fire anytime soon. Confirm the user actually wants to compact now rather than later; the synthesis is fine to run regardless but the user may be confused.
- **Auto-memory saved a memory the user wouldn't want kept**: Surface it. Memories are durable; bad ones poison future sessions.
- **Working tree is dirty but the user is in mid-thought**: Surface, don't act. They may want the work-in-progress to die with the session rather than be committed.
- **Hook script failed (no `pre-compact-<ts>.md` snapshot)**: Run the hook manually (`~/OPS/.claude-config/hooks/pre-compact.sh`) to get the mechanical state, then continue with thoughtful synthesis.

## Reference

- Operating-doctrine Principle 2 — `~/OPS/CONTEXT/operating-doctrine.md`. Read once at activation if context is tight; the four-artifact list lives there.
- Fleet ac-pre-compact source — `~/OPS/WORKFORCE/bin/ac-pre-compact`. Read only if you need to debug fleet dispatch.
- PreCompact hook spec — Claude Code docs at `code.claude.com/docs/en/hooks.md`. Read only if the hook misbehaves.
