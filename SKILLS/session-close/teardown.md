# Teardown

Read at step 5, the final tool call of the close. Deregister the session and stop its backend. Pick the branch for the backend this session runs on: tmux (`$TMUX` set), or not in tmux. The tmux branch kills the session you are in, so run the receipt (step 4) first and make the teardown the last tool call.

No registry row: a session started by hand, or any tmux session nothing registered. Check with `~/OPS/.claude-config/remote-sessions/archive-remote-claude.sh sweep` (read-only; it lists every live registry row). `rc_archive` matches a name by its canonical form (case-insensitive, spaces and underscores read as hyphens), so a hand-written grep of the registry file can disagree with it; trust the command. With no row, `archive` refuses with `ERR_NOT_FOUND` before it touches anything, so skip the archive and forget commands and run only the tmux kill:

```bash
# No registry row: tear down this tmux session only. Same single-capture rule as below.
SN="$(tmux display-message -p '#S')" && tmux kill-session -t "=$SN"
```

## In tmux (`$TMUX` set)

Capture the name exactly once, before anything dies. One command does both the registry and the tmux kill:

```bash
# Archive (default): parks the registry row, then kills this tmux session.
SN="$(tmux display-message -p '#S')" && \
  ~/OPS/.claude-config/remote-sessions/archive-remote-claude.sh archive "$SN"; \
  tmux kill-session -t "=$SN" 2>/dev/null
```

```bash
# Forget: deregister, then kill this tmux session. Same single-capture rule.
SN="$(tmux display-message -p '#S')" && \
  source ~/OPS/.claude-config/remote-sessions/lib-remote-claude.sh && \
  rc_deregister "$(rc_normalize_name "$SN")" && \
  tmux kill-session -t "=$SN"
```

The single capture is load-bearing. If the command re-evaluates `$(tmux display-message -p '#S')` for the second kill, by then `rc_archive` has already killed this tmux session, and from a dead-pane context tmux silently falls back to ANOTHER live session's name; the `=` exact-match kill then faithfully kills that innocent session (observed: closing one session killed an unrelated one this way, mechanism reproduced). The `=` guard itself is mandatory: a bare `-t <name>` unique-prefix-matches and can kill a sibling in a family like `Finrep`/`Finrep2` or `Mcp`/`Mcpwork`.

Verify the target BEFORE you tear down. tmux session names diverge from the registry name for the same session (live tmux names are often lowercase, e.g. `main`, while the registry stores Title-Case, e.g. `Project-Two`), and names get reused across sessions. When they diverge, `rc_archive "$(#S)"` may resolve to the wrong row and park or kill the wrong session. As the first move of teardown, run `tmux display-message -p '#S'`, confirm it is THIS session, confirm it matches the registry row you intend to archive (`grep -i <name> ~/.claude-remote-sessions.tsv`), and only then kill. If the name-to-registry mapping looks inconsistent, STOP and surface it; do not kill on a guess.

This failure mode is structural to tmux: `display-message -p '#S'` queries a live server for "the current session" and, asked from a dead pane, answers with a sibling. Capturing the name once, before `rc_archive` kills the session, is what avoids it.

## Not in tmux

No `$TMUX`, as in a T3 Code thread, an IDE terminal, or a plain terminal: there is no registry row and nothing for you to kill (rows come only from `new-remote-claude.sh`, which launches in tmux). Run steps 1 through 4 (synthesis, reconciliation, decision, receipt), then tell the operator the close is complete. In a terminal they can exit it; in T3 Code the thread is theirs to settle or archive in the T3 UI, and a settle stops the thread's provider session, so it comes after the receipt and only on their word.

## Guardrails

- `ERR_GUARANTEED`: the name is in `RC_GUARANTEED_NAMES`, so the boot script re-seeds it and archiving would orphan its history. Do NOT force it. Report that guaranteed sessions are closed by first removing the name from `RC_GUARANTEED_NAMES` in `lib-remote-claude.sh`.
- Revive is always an explicit act (`archive-remote-claude.sh revive <Name>`); nothing re-registers an archived name on its own.
