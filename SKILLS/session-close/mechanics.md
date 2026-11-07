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
  # Commits since t0, with the harness's own memory-sync commits filtered out:
  # they fire from every session's closeout and are never session labor. Declare
  # your own cron/automation commit markers in work-tracking.md and add them here.
  git -C "$r" log --since="${T0:-3 hours ago}" --pretty='  %h %s (%cr)' 2>/dev/null \
    | grep -vE 'chore\(memory\)'
done
```

Commits are candidates, not attributions: a commit in the window may belong to a parallel session or a cron, and git stamps them all as the same identity. The filter drops the obvious automation (`chore(memory)`); treat what survives as "did we do this?" questions for the operator. Lead with the uncommitted working tree and the work-log narrative; use commits only to corroborate.

Optional wider sweep: to catch a repo the stamp did not name, sweep `~/OPS/PROJECTS/*/*` for window activity, apply the SAME automation filter, label it "other repos with commits in the window (parallel session or cron, confirm before logging)", and make the operator confirm. Never auto-attribute a swept repo.

No stamp for this KEY? Under T3 Code the key is `t3-<session id>`, stable across compaction and resume with one stamp per thread, so a missing stamp there means the session never stamped; do not borrow the newest stamp, which may be another thread's in the same directory. Under tmux the key is the session name, which can change across a crash or resume (a session that booted as `projecta` can resume as `main`), so `session-start-$KEY` may not match even though the session did stamp. There, try the newest stamp as a candidate and sanity-check its cwd and boot_repo against where you are:

```bash
ls -t "$RUN"/session-start-* 2>/dev/null | head -1   # most-recent session; confirm its cwd matches
```

If nothing matches (a session predating the stamp, or non-tmux), say so, fall back to the cwd repo plus `git status` plus a best `--since` estimate, and lean harder on asking the operator what the session covered. Never attribute off a mismatched stamp.

### Cross-check from this session's own transcript

The stamp names the repos a session started in; the transcript names the repos it actually worked in. When `$CLAUDE_CODE_SESSION_ID` is set, this session's transcript is `${CLAUDE_CONFIG_DIR:-~/.claude}/projects/*/$CLAUDE_CODE_SESSION_ID.jsonl`. The git root of every path its tool calls named is a candidate set to confirm from your own context (a repo it only read needs nothing, and a harness checkout or tool cache can appear in it):

```bash
T="$(find "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects" -maxdepth 2 -name "${CLAUDE_CODE_SESSION_ID:?}.jsonl" 2>/dev/null | head -1)"
python3 -I - "$T" <<'PY'
import json, os, re, subprocess, sys
home = os.path.expanduser("~")
path_re = re.compile(re.escape(home) + r"/[\w.@+-]+(?:/[\w.@+-]+)*")
seen = set()
with open(sys.argv[1], encoding="utf-8", errors="replace") as fh:
    for line in fh:
        try:
            rec = json.loads(line)
        except ValueError:
            continue
        content = (rec.get("message") or {}).get("content")
        if rec.get("type") != "assistant" or not isinstance(content, list):
            continue
        for block in content:
            if not isinstance(block, dict) or block.get("type") != "tool_use":
                continue
            args = block.get("input") or {}
            for key in ("file_path", "path", "command"):
                val = args.get(key)
                if isinstance(val, str):
                    val = val.replace("~/", home + "/").replace("$HOME/", home + "/")
                    seen.update(path_re.findall(val))
roots = set()
for p in seen:
    d = p if os.path.isdir(p) else os.path.dirname(p)
    while d and d != home and not os.path.isdir(d):
        d = os.path.dirname(d)
    if d and d != home:
        r = subprocess.run(["git", "-C", d, "rev-parse", "--show-toplevel"], capture_output=True, text=True)
        if r.returncode == 0:
            roots.add(r.stdout.strip())
print("\n".join(sorted(roots)))
PY
```

For each repo it lists: `git -C <repo> status --short`, `git -C <repo> branch --show-current`, `git -C <repo> log --oneline origin/HEAD..HEAD`, and `git -C <repo> worktree list`. If no transcript is found (a session lost in a rescue, or another host's layout), say so and fall back to the stamp above; never invent a repo list.

The memory side: the `~/.claude-compact-cycle/memory-flush-queue` lines whose pool this session wrote to and whose time falls in its window, plus `git -C ~/OPS status --short -- .claude-memory/`. Queue lines carry no session id, so a line from a concurrent session in the same pool can look like yours; disposition only what you recognize and leave the rest.

## A leftover stamp the briefing flagged

A scan the boot briefing starts in the background (at most every 30 minutes, off the boot path) reads `~/.claude-compact-cycle/session-start-*` and flags a prior session's leftover stamp only when real commits landed in its window, meaning that session ended without a work-tracking reconciliation and its work may be unlogged; an idle leftover stays quiet. The warning the briefing shows can be up to 30 minutes old, and a stamp a close removed stops counting at the next boot. It only warns and never removes a stamp; finishing the judgment is a close's job, because the briefing has no work-tracking access and must never block boot on a network call. If a warning fired and you are closing, you may reconcile that window too:

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
  > ~/.local/state/ops/last-reconcile
rm -f "$RUN/session-start-$KEY" "$RUN/work-log-$KEY"
```

`last-reconcile` is the operator's record of the last reconciliation and its outcome. The redirect is load-bearing: without it the trailing `\` makes the `rm` on the next line an argument to `printf`, so the stamp is never cleared and the next boot flags this clean close as unreconciled. The `rm` is not optional even when nothing was billable: leaving `session-start-$KEY` behind false-flags this clean close as abandoned-unreconciled at the next boot's briefing.
