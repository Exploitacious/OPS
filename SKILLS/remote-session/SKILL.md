---
name: remote-session
description: "Use to start, attach, list, park, revive, or end a one-off Claude Code session in tmux that the operator remote-controls from another device (the claude.ai apps). Triggers: 'start/spin up a session called X', 'give me a session for X', 'list my sessions', 'park/kill this session'. Manages the session container only; session-handoff carries the work baton. Claude Code only."
---

# Manage remote Claude Code sessions

This machine can run Claude Code sessions in tmux that the operator drives from another device (`claude --remote-control <Name>`, through their claude.ai account). They are one-off sessions the operator starts and manages by hand: nothing registers a session on its own, nothing brings one back after a reboot, and nothing compacts one for you, so the operator fires `/compact` in it. This skill runs the lifecycle: start, seed a handoff, list, attach, park, revive, and end. The scripts live in `~/OPS/.claude-config/remote-sessions/`; that directory's `README.md` holds configuration.

Why hand-run: an auto-register hook plus an `@reboot` resume brought finished sessions back into stale context after every reboot, and three systems (that resume, tmux-resurrect, a restarting tmux unit) fought over the same tmux server. A session that matters is one the operator starts on purpose.

## Start a session

Through the launcher, when the session should be resumable and parkable by name:

    ~/OPS/.claude-config/remote-sessions/new-remote-claude.sh "<name>" [workdir]

- `<name>` (required): pass it exactly as the operator said it. The script normalizes it to Title-Case-Hyphen for tmux and TSV safety (`morning briefing` becomes `Morning-Briefing`). Do not pre-format it.
- `[workdir]` (optional): where Claude opens, default `$HOME`. Resolve loose names ("the website repo") to a real path through `~/OPS/PROJECTS/projects-map.md`. If it does not resolve, ask rather than guess. Ignored for a name already in the registry (it keeps its dir so its conversation resumes).

The script records a row in `~/.claude-remote-sessions.tsv` (name, dir, session id, profile), starts the tmux session, launches `claude --remote-control`, accepts the first-run MCP prompt, and checks the cwd, in one shot. The row is what lets a later call resume the same conversation by name; it does not make the session come back on its own.

By hand, for a scratch session: `tmux new -s <Name>`, then `claude --remote-control <Name>` inside it. A hand-started session has no registry row, so it cannot be parked or revived by name.

## Second profile

The launcher records the live `CLAUDE_CONFIG_DIR` in the row's fourth column, so a session started under a second profile resumes under that profile. There is no `--profile` flag: start the launcher from a shell where `CLAUDE_CONFIG_DIR` already points at that profile. The default profile writes a plain three-column row.

## Seed a handoff

To hand work to a new session, write the work order to a file (a committed plan or a `session-handoff` baton is the durable copy), start the session, then inject one line pointing at the file (see Mechanics). A second profile shares neither the task list nor auto-memory, so put the durable state in git.

## Read the result

The launcher prints one status line and sets an exit code:

- `OK name=<Name> cwd=<dir> session_id=<id> mode=<create|resume> profile=<default|name> remote_control=on` (exit 0). Report the name, the dir (sanity-check it is what they wanted), the profile, and that it is live on their device now.
- `ERR_EXISTS` (3): a session with that name is already running (the script prints its cwd). `ERR_DIR` (4): the dir is missing. `ERR_USAGE` / `ERR_NAME` (2): no usable name. The message names which; fix and retry.

## List and inspect

- Live tmux sessions: `tmux ls`.
- Registry health: `archive-remote-claude.sh sweep` prints each row's status (`GONE` when it is not running, `STALE` when its transcript is old, `IDLE` when detached, `OK`), age, tmux presence, and any name collisions. Read-only.
- Parked sessions: `archive-remote-claude.sh list`.

## Attach

`tmux attach -t "=<Name>"`, detach with `Ctrl-b` then `d`. A `--remote-control` session is also reachable from the operator's claude.ai account, so attaching is only for a local look.

## Park, revive, and end

- Park with history: `archive-remote-claude.sh archive "<Name>"` kills its tmux session (it drops off the operator's device) and moves the row and session id to the archive file.
- Revive a parked session: `archive-remote-claude.sh revive "<Name>"` moves the row back and relaunches it with full history.
- Resume a registered session that is not running (after a reboot, say): rerun the launcher with its name.
- End for good, no archive row:

      source ~/OPS/.claude-config/remote-sessions/lib-remote-claude.sh && \
        rc_deregister "$(rc_normalize_name "<Name>")"
      tmux kill-session -t "=<Name>"

- Closing the session you are in, with work tracking: `session-close`.

## Mechanics: the tmux target trap

Pane-level tmux commands (`send-keys`, `capture-pane`, `display-message`) do not resolve a bare `=<Name>` exact-session target on recent tmux; they need the window component `=<Name>:`. Session-level commands (`has-session`, `kill-session`) still take bare `=<Name>`. The launcher handles this; the trap only bites if you hand-roll `tmux new-session` plus `send-keys`. To read a pane: `tmux capture-pane -p -t "=<Name>:"`. To hand a running session new work, inject a single line pointing at a file (`send-keys -t "=<Name>:" -l 'read <path> and execute it'`, then a separate `send-keys -t "=<Name>:" Enter`); a multi-line paste can submit early, and a dialog on screen can swallow the first keystrokes, so confirm with `capture-pane` afterward.

## Under T3 Code

A T3 Code thread is not a tmux session and has no registry row. Start, switch, and end T3 threads in the T3 UI; this skill does not reach them.
