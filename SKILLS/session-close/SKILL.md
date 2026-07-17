---
name: session-close
description: Permanently close a Claude Code session, end to end — full closeout synthesis (work committed, docs matching reality, memory captured, nothing hanging), THEN the WIP & work-tracking reconciliation gate (reconcile what the session did against your ticketing / time / board systems — log time, advance the card, flag blockers, or draft the entry text when no tool is wired), then remove it from the reboot-resume registry and tear down its tmux session. Use when the Operator says "close this session", "close this out for good", "shut this session down", "end this session permanently", "we're done with this session", "close out / wrap up for the day", "I'm done working". NOT for pausing (that's a closeout + /compact via pre-compact-synthesis — no reconciliation there) and NOT for moving work elsewhere (that's session-handoff). Close means: documented, reconciled, archived, gone.
---

# Close a session — permanently, cleanly

Three session endings exist in this harness. Pick the right one before running
anything:

| Ending | Meaning | Skill |
|--------|---------|-------|
| **Pause** | Same session continues after a `/compact` | `pre-compact-synthesis` |
| **Move** | Work continues in a different session/profile/machine | `session-handoff` |
| **Close** | The session's purpose is DONE. Document, archive, tear down | this skill |

Close is for a finished purpose, not a finished day. If real work is still
in-flight, say so and offer handoff or compact instead — a close with open
threads is a future archaeology dig.

## Flow

### 1. Closeout synthesis (the four-artifact pass)

Run the full hygiene checklist from `pre-compact-synthesis` — everything except
its final `/compact`:

- **Git**: every touched repo committed and pushed; working trees clean or
  deliberately dirty with the Operator's knowledge. Name what you're leaving.
- **Docs match reality**: README / CHANGELOG / lessons files updated for what
  this session actually shipped, in the same pass — not "later".
- **Memory**: durable lessons, decisions, and feedback from this session are
  written to the memory pool (one fact per file, indexed) — then the cache is
  purged for whatever this close terminates: per `foreman-charter.md` §
  "Eviction — memory is a write cache, not an archive", the closing project's
  entries fold into `CONTEXT/projects/<project>-lessons.md` and get
  **deleted** (index lines too — no stubs). Close means the write cache holds
  nothing for this work anymore.
- **Tasks**: the session's task list is resolved — completed, or explicitly
  re-homed with the Operator's sign-off. Nothing silently abandoned.
- **Leftovers**: if a genuinely open thread survives all of the above, write a
  handoff baton (`session-handoff` WRITE) so the thread has a home that isn't
  this dying session. A clean close usually needs none.

### 2. WIP & work-tracking reconciliation (the gate)

This is where the session's work becomes accountable: make the tickets, time,
and boards reflect what this session actually did — **before** the session is
gone. Run it on every close. It is a **firm forcing function**: you may skip an
item, but only with an explicit reason the Operator gives — nothing is silently
dropped, and nothing is written to an external system without the Operator's OK.

The gate reads `CONTEXT/work-tracking.md` to learn which systems the Operator
configured. Where a surface names a tool, it offers to call it; where none is
configured it **drafts** the entry text for the Operator to log themselves (see
that file's "If nothing here is configured"). The gate hardcodes no system — an
unconfigured OPS still reconciles, it just drafts and reminds instead of writing.

**A. Assemble the work picture — do NOT ask the Operator to remember it.**
The session's activity is already on disk. Reconstruct it, **scoped to what THIS
session touched.** A box can run many concurrent sessions plus cron jobs (memory
sync, fleet peers, scheduled agents) that commit on their own — a blanket "all
commits since t0 across every repo" sweep WILL pull in other sessions' and
automation's commits and attribute them to the wrong item. Scope tightly:

```bash
. ~/OPS/.claude-config/hooks/hooklib.sh
KEY="$(work_session_key)"; RUN="$HOME/.claude-compact-cycle"
STAMP="$RUN/session-start-$KEY"
cat "$STAMP" 2>/dev/null              # t0, boot repo, cwd
cat "$RUN/work-log-$KEY" 2>/dev/null  # per-compact segments: repos/cwd + narrative (if any)
T0="$(grep -m1 '^started_at=' "$STAMP" 2>/dev/null | cut -d= -f2-)"

# THIS session's repos = boot repo + cwd + any repo named in the work-log.
# while-read (not `for r in $VAR`): the interactive shell here is zsh, which
# does NOT word-split unquoted expansions — a for-loop would iterate once over
# the whole blob. read splits on newlines in both bash and zsh.
echo "== this session's repos: uncommitted WIP + candidate commits since t0 =="
{ grep -m1 '^boot_repo=' "$STAMP" 2>/dev/null | cut -d= -f2-;
  grep    '^repo='        "$RUN/work-log-$KEY" 2>/dev/null | sed 's/^repo=//; s/ .*//';
  pwd; } | sort -u | grep -vE '^-?$' | while read -r r; do
  [ -d "$r/.git" ] || continue
  echo "-- $r"
  git -C "$r" status --short 2>/dev/null | sed 's/^/  WIP /'   # work still in the tree at close
  # Commits since t0, with obvious AUTOMATION/housekeeping filtered out — the
  # harness's own memory-sync commits (chore(memory)) fire from every session's
  # closeout, so they are never session labor. Add your own cron/automation
  # commit markers to this filter (declare them in work-tracking.md). What
  # remains is CANDIDATE work to confirm, not auto-attributed: a parallel
  # session in the same repo commits under the identical git identity, so the
  # human confirms.
  git -C "$r" log --since="${T0:-3 hours ago}" --pretty='  %h %s (%cr)' 2>/dev/null \
    | grep -vE 'chore\(memory\)'
done
```

- **Commits are CANDIDATES, not attributions.** Even in the session's own repos,
  a commit in the window may belong to a parallel session or a cron — git stamps
  them all as the same identity, so it cannot tell them apart. The loop filters
  the obvious automation (`chore(memory)`); treat what remains as "did we do
  this?" questions for the Operator, never as auto-attributed fact. The
  **highest-confidence** signals of THIS session's work are the uncommitted
  working-tree changes (`git status`/`git diff` — synthesis commits what should
  be committed, but work is often still in the tree at close) and the work-log
  narrative. Lead with those; use commits only to corroborate.
- **Span, not a guessed number.** Present the wall-clock span (t0 → now) AND the
  git-active span (first → last commit) as the Operator's *evidence*; the
  Operator sets the hours. Never invent one.
- **Optional wider sweep — same skepticism.** To catch a repo the stamp didn't
  name, you may sweep `~/OPS/PROJECTS/*/*` for window activity — but apply the
  SAME automation filter as the primary loop, label it "other repos with commits
  in the window (parallel session or cron — confirm before logging)," and make
  the Operator confirm. Never auto-attribute a swept repo. Automation / cron /
  `*-sync` / fleet-peer commits are never the Operator's session time.
- **No stamp for this KEY?** The tmux session name can change across a
  crash/resume (a session that booted as `projecta` can resume as `main`), so
  `session-start-$KEY` may not match even though the session did stamp. Before
  giving up, try the newest stamp as a candidate and sanity-check its
  `cwd`/`boot_repo` against where you actually are:
  ```bash
  ls -t "$RUN"/session-start-* 2>/dev/null | head -1   # most-recent session; confirm its cwd matches
  ```
  If nothing matches (a session predating the stamp, or non-tmux), say so — fall
  back to the cwd repo + `git status` + your best `--since` estimate, and lean
  harder on asking the Operator what the session covered. Never attribute off a
  mismatched stamp; confirm cwd/repo first.

**B. Learn the Operator's systems, then resolve each work area.**
Read `CONTEXT/work-tracking.md`. It declares, per surface (time/billing,
ticketing, board, personal tasks), either a tool the AI may call or "manual —
draft for me to paste." Then, per touched work area:

- **What's already logged today?** If a time system is configured, ask it (via
  its configured tool, or the Operator) what today already holds so you never
  double-log a day captured elsewhere. No tool → ask the Operator directly.
- **Which item does this map to?** There is NO global resolver. Consult the
  optional repo→item table in `work-tracking.md` for a hint, then confirm per
  touched repo that it is the right OPEN item — a repo is not 1:1 with an item
  (phase-scoped work spawns new items). Confirm; never auto-pick.
- **Is there a board/card to advance?** Only if a board is configured. Defer to
  `work-tracking.md` for the card conventions.
- **A personal task tracker item?** Check it only if the Operator configured one.

**C. Present the table and OFFER — one AskUserQuestion, multiSelect.**
Show a compact reconciliation table, then let the Operator pick what to apply:

```
This session — Xh wall / Yh git-active (t0 … now)
 repo/area          → item / card                 logged today  proposed
 example-webapp     → TCK-1042 · Webapp work        0.0h         log 2.0h + note
 (board card 50%)                                                advance card → Active
```

Offer, per resolved item (the Operator authorizes each):
- **Log time** — via the configured time tool, with the hours the Operator sets,
  plus a note summarizing what shipped (pull it from commit subjects — concrete,
  not "worked on stuff"). No tool configured → **draft** the time + note text for
  the Operator to paste.
- **Advance the board card** — via the configured board tool (percent + label +
  title stamp), a separate write from the time entry. No board configured → skip.
- **Update the personal task tracker** — tick/complete/edit via its configured
  tool. None configured → skip.
- **Flag a blocker** — mark the item/card blocked and add a note naming the
  block, rather than advancing it.
- **Skip** — allowed, but the Operator names the reason (`not billable`, `logged
  already`, `personal work`, etc.). The reason goes in the receipt and the stamp.

**D. No item for the work? Create it first.** The principle, stated generically:
*new labor without a tracked item is a process bug — create the tracked item
first.* Offer to create the item (via the configured tool, else draft it under
the right board/theme), then log against it. Never log orphaned labor. Never
terminally close an item on the Operator's behalf.

**E. Execute, learn, stamp.**
- Execute only the writes the Operator authorized — via the configured tools, or
  by handing over the drafted text for the surfaces that have no tool.
- **Learn-on-confirm:** if the Operator confirmed a NEW repo→item association not
  already in `work-tracking.md`, append/update its row in that file's learned map
  (tag the note `(learned <date>)`) so next time the guess is right. That file is
  the project-local knowledge home per foreman-charter § "Where knowledge goes" —
  it rides one OPS sync, so the mapping follows you across machines.
- **Stamp** `~/.local/state/ops/last-worktrack-check` with the outcome:
  ```bash
  mkdir -p ~/.local/state/ops
  printf '%s\treconciled=%s\tdeclined=%s\n' "$(date -Is)" "<n items logged>" "<reason or ->" \
    > ~/.local/state/ops/last-worktrack-check
  ```
  (session-briefing's backstop surfaces an abandoned, unreconciled session at the
  next boot — see its Hygiene line.)
- **Clean up the session state** now that it's captured:
  `rm -f "$RUN/session-start-$KEY" "$RUN/work-log-$KEY"` — a later revive is a
  new work session and must not inherit this one's t0/log.

Some work may be non-trackable or non-billable — ask, don't assume. Internal /
overhead items can take a time entry for tracking but aren't client-billable;
personal work takes none by default — note "skipped — <reason>" and move on.

If the scan turns up genuinely nothing to reconcile (bare exploration, no
commits, no item work), that's one line — "Nothing trackable this session" —
then still run **all of step E** (write the `last-worktrack-check` stamp AND
delete `session-start-$KEY` + `work-log-$KEY`) before moving to step 3. Skipping
the cleanup would leave the stamp behind and the next boot's briefing backstop
would false-flag this cleanly-closed session as "abandoned unreconciled."
Self-gating, no ceremony — but the cleanup is not optional.

### 3. One decision from the Operator

Ask (AskUserQuestion, two options):

- **Archive** (recommended default) — the session's registry row moves to the
  archive file. It stops returning on reboot, but keeps its session-id,
  workdir, and profile; `archive-remote-claude.sh revive <Name>` brings it
  back later with full conversation history.
- **Forget** — deregister entirely. Off the boot list with no archive row. The
  transcript still exists on disk (nothing here deletes conversation history;
  `claude --resume` can always find it by id), but the harness stops tracking
  it.

### 4. Deliver the closeout receipt

Report BEFORE the teardown, because step 5 ends this session mid-breath —
nothing you print after it arrives anywhere. The receipt names: what was
committed/pushed (repos + short SHAs), what memory/lessons were written, what
docs changed, **the WIP/work-tracking outcome (time logged with hours + item, or
the draft text handed over; cards advanced; tasks updated — or what was declined
and why)**, any baton written, and the revive command if archived.

### 5. Last act: teardown (final tool call of the session)

**In tmux** (`$TMUX` set) — one command does both registry and tmux:

```bash
# Archive (default): parks the registry row, then kills this tmux session by its
# RAW name. The chained kill matters: the registry stores the NORMALIZED name
# (Title-Case-Hyphen), and rc_archive kills that — a hand-made session with
# different casing (e.g. "harness") survives it, because tmux names are
# case-sensitive. The second kill targets the actual live name; it no-ops if
# rc_archive's kill already landed.
~/OPS/.claude-config/remote-sessions/archive-remote-claude.sh archive "$(tmux display-message -p '#S')"; tmux kill-session -t "$(tmux display-message -p '#S')" 2>/dev/null
```

```bash
# Forget variant: deregister, then kill this tmux session.
source ~/OPS/.claude-config/remote-sessions/lib-remote-claude.sh && \
  rc_deregister "$(rc_normalize_name "$(tmux display-message -p '#S')")" && \
  tmux kill-session -t "$(tmux display-message -p '#S')"
```

This kills the session you are running in — that is the point. Make it the
absolute last tool call; the receipt (step 4) already went out.

- `ERR_GUARANTEED`: the name is in `RC_GUARANTEED_NAMES` — the boot script
  deliberately re-seeds it and archiving would orphan its history. Do NOT
  force it; report to the Operator that guaranteed sessions are closed by
  first removing the name from `RC_GUARANTEED_NAMES` in
  `lib-remote-claude.sh`.
- The auto-register hook respects the archive: reopening a tmux session with
  an archived name will NOT silently re-register it. Revive is always an
  explicit act.

**Not in tmux**: there is no registry row and no tmux to tear down (only
tmux-hosted sessions are boot-registered). Run steps 1-4, then tell the
Operator the close is complete and this terminal can simply be exited.

## Notes

- Closing never deletes history. Registry rows are pointers; transcripts live
  under the profile's `projects/` dir untouched.
- A closed session that was remote-controlled disappears from the Operator's
  claude.ai device list when its tmux dies — expected, part of "gone".
- If the Operator asks to close a DIFFERENT session by name (not the one you
  are in), skip steps 1-2 (you can't run another session's closeout OR reconcile
  its WIP/work-tracking from here) — warn that its in-session state is whatever
  it is, then archive/forget its row the same way. Prefer telling the Operator to
  run the close from inside that session, precisely so its reconciliation gate
  actually fires.
