# Session-state mechanics

Read during the reconciliation gate (step 2). Two jobs: reconstruct THIS session's work picture from the on-disk stamps, and finish the judgment on a leftover stamp the boot briefing flagged. Also holds the step-E stamp-and-cleanup writes.

## Reconstruct this session's work picture

A box can run concurrent sessions plus crons that commit on their own. A blanket "all commits since t0 across every repo" sweep pulls in other sessions' and automation's commits and attributes them to the wrong item. Scope to the boot repo, the cwd, and repos the work-log names:

```bash
. ~/OPS/.claude-config/hooks/hooklib.sh
KEY="$(work_session_key)"; RUN="$HOME/.claude-compact-cycle"
STAMP="$RUN/session-start-$KEY"
cat "$STAMP" 2>/dev/null              # t0, boot repo, cwd
cat "$RUN/work-log-$KEY" 2>/dev/null  # per-compact segments: repos/cwd + narrative
T0="$(grep -m1 '^started_at=' "$STAMP" 2>/dev/null | cut -d= -f2-)"

# THIS session's repos = boot repo + cwd + any repo named in the work-log.
# while-read, not `for r in $VAR`: the interactive shell is zsh, which does not
# word-split unquoted expansions, so a for-loop would iterate once over the
# whole blob. read splits on newlines in both bash and zsh.
echo "== this session's repos: uncommitted WIP + candidate commits since t0 =="
{ grep -m1 '^boot_repo=' "$STAMP" 2>/dev/null | cut -d= -f2-;
  grep    '^repo='        "$RUN/work-log-$KEY" 2>/dev/null | sed 's/^repo=//; s/ .*//';
  pwd; } | sort -u | grep -vE '^-?$' | while read -r r; do
  [ -d "$r/.git" ] || continue
  echo "-- $r"
  git -C "$r" status --short 2>/dev/null | sed 's/^/  WIP /'   # work still in the tree at close
  # Commits since t0, with the harness's own memory-sync commits filtered out —
  # they fire from every session's closeout and are never session labor. Declare
  # your own cron/automation commit markers in work-tracking.md and add them here.
  git -C "$r" log --since="${T0:-3 hours ago}" --pretty='  %h %s (%cr)' 2>/dev/null \
    | grep -vE 'chore\(memory\)'
done
```

Commits are candidates, not attributions: a commit in the window may belong to a parallel session or a cron, and git stamps them all as the same identity. The filter drops the obvious automation (`chore(memory)`); treat what survives as "did we do this?" questions for the operator. Lead with the uncommitted working tree and the work-log narrative; use commits only to corroborate.

Optional wider sweep: to catch a repo the stamp did not name, sweep `~/OPS/PROJECTS/*/*` for window activity, apply the SAME automation filter, label it "other repos with commits in the window (parallel session or cron, confirm before logging)", and make the operator confirm. Never auto-attribute a swept repo.

No stamp for this KEY? The tmux name can change across a crash or resume (a session that booted as `projecta` can resume as `main`), so `session-start-$KEY` may not match even though the session did stamp. Try the newest stamp as a candidate and sanity-check its cwd and boot_repo against where you are:

```bash
ls -t "$RUN"/session-start-* 2>/dev/null | head -1   # most-recent session; confirm its cwd matches
```

If nothing matches (a session predating the stamp, or non-tmux), say so, fall back to the cwd repo plus `git status` plus a best `--since` estimate, and lean harder on asking the operator what the session covered. Never attribute off a mismatched stamp.

## A leftover stamp the briefing flagged

The boot briefing scans `~/.claude-compact-cycle/session-start-*` and warns when a prior session's stamp was left behind, meaning that session ended without a work-tracking reconciliation and its work may be unlogged. It only warns; finishing the judgment is a close's job, because the briefing has no work-tracking access and must never block boot on a network call. If a warning fired and you are closing, you may reconcile that window too:

```bash
RUN="$HOME/.claude-compact-cycle"
cat "$RUN"/session-start-<key>      # the flagged stamp: t0, cwd, boot repo
cat "$RUN"/work-log-<key>           # its narrative, if it ever compacted
```

Cross-check the flagged window against what is already logged, using the time tool and identity in `work-tracking.md`. Three outcomes:

- Hours already cover that work: nothing owed. Name the covering entry, then retire the stamp so this backstop does not flag it forever: `rm -f "$RUN/session-start-<key>" "$RUN/work-log-<key>"`.
- Genuinely zero hours for work that should be tracked: report it to the operator in chat with the evidence (t0, repos, commit subjects, work-log narrative) and let them set the hours. Chat only, no automated write off a leftover finding.
- Zero hours but nothing owed (a personal repo, a test fixture, someone else's parallel session): say so in one line and retire the stamp.

## Step-E stamp and cleanup

After executing the authorized writes, record the outcome and clear the session state so a later revive starts clean:

```bash
mkdir -p ~/.local/state/ops
printf '%s\treconciled=%s\tdeclined=%s\n' "$(date -Is)" "<n items logged>" "<reason or ->" \
  > ~/.local/state/ops/last-worktrack-check
rm -f "$RUN/session-start-$KEY" "$RUN/work-log-$KEY"
```

The `rm` is not optional even when nothing was billable: leaving `session-start-$KEY` behind false-flags this clean close as abandoned-unreconciled at the next boot's briefing.
