# Teardown

Read at step 5, the final tool call of the close. Deregister the session and kill its tmux. This kills the session you are in, so run the receipt (step 4) first and make the teardown the last tool call.

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

No `$TMUX`: there is no registry row and nothing to tear down (only tmux-hosted sessions are boot-registered). Run steps 1 through 4 (synthesis, reconciliation, decision, receipt), then tell the operator the close is complete and this terminal can be exited.

## Guardrails

- `ERR_GUARANTEED`: the name is in `RC_GUARANTEED_NAMES`, so the boot script re-seeds it and archiving would orphan its history. Do NOT force it. Report that guaranteed sessions are closed by first removing the name from `RC_GUARANTEED_NAMES` in `lib-remote-claude.sh`.
- The auto-register hook respects the archive: reopening a tmux session with an archived name will NOT silently re-register it. Revive is always an explicit act.
