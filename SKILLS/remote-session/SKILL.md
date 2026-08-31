---
name: remote-session
description: "Use when the operator asks to start, list, attach, park, revive, or end a Claude Code session running in tmux on this machine that they remote-control from another device (e.g. the claude.ai app). Triggers: 'start/spin up a new session called X', 'give me a session for X', 'list my sessions', 'park/kill this session'. Creates a registry-backed, reboot-persistent tmux session and reports its name, dir, and profile. This skill manages the session CONTAINER; the durable work baton is session-handoff's job, and the two compose (this spins up the target, session-handoff writes what it reads). Claude Code only."
---

# Manage remote Claude Code sessions

This machine runs always-on Claude Code sessions in tmux that the operator remote-controls from another device (`claude --remote-control <Name>`, through their claude.ai account). A registry (`~/.claude-remote-sessions.tsv`) plus an `@reboot` cron make every session persist and resume across reboots. This skill runs the lifecycle: start, list, attach, park, revive, and end. The scripts live in `~/OPS/.claude-config/remote-sessions/`; that directory's `README.md` holds install and configuration.

## Start a session

    ~/OPS/.claude-config/remote-sessions/new-remote-claude.sh "<name>" [workdir]

- `<name>` (required): pass it exactly as the operator said it. The script normalizes it to Title-Case-Hyphen for tmux and TSV safety (`morning briefing` -> `Morning-Briefing`). Do not pre-format it.
- `[workdir]` (optional): where Claude opens, default `$HOME`. Resolve loose names ("the website repo") to a real path via `~/OPS/PROJECTS/projects-map.md`. If it does not resolve, ask rather than guess. Ignored for a name that is already registered (it keeps its registered dir so its conversation resumes).

The script handles naming, the tmux session, the `claude --remote-control` launch, the first-run MCP prompt, and a cwd sanity-check in one shot.

## Profiles: launching under a second profile

The launcher captures the live `CLAUDE_CONFIG_DIR` at creation and records it in the registry's 4th column, so a session started under a second profile resumes under that profile after a reboot rather than silently starting fresh under the default `~/.claude`. There is no `--profile` flag: to launch a session on a second profile (e.g. a personal `~/.claude-personal`), invoke the launcher from a shell where `CLAUDE_CONFIG_DIR` already points at that profile. The default profile normalizes to a clean 3-column row.

## Read the result

The script prints one status line and sets an exit code:

- `OK name=<Name> cwd=<dir> ... profile=<default|name> remote_control=on` (exit 0). Report back the name, the dir (sanity-check it is what they wanted), the profile, and that it is live on their device now.
- `ERR_EXISTS` (3) a session with that name is already running (the script prints its cwd). `ERR_DIR` (4) the dir is missing. `ERR_USAGE` / `ERR_NAME` (2) no usable name. The message names which. Fix and retry.

## List and inspect

- Live tmux sessions: `tmux ls`.
- Live registry health (what boot-resumes): `archive-remote-claude.sh sweep` prints per-session status, age, tmux presence, and a case-collision scan. Read-only.
- Parked sessions: `archive-remote-claude.sh list`.

## Attach

`tmux attach -t "=<Name>"`, detach with `Ctrl-b` then `d`. The session is already reachable from the operator's claude.ai account, so attaching is only for a local look.

## Park, revive, and end

- Park with history: `archive-remote-claude.sh archive "<Name>"` removes it from the boot registry and kills its tmux (drops off the operator's device); the row and session-id move to the archive file.
- Revive a parked session: `archive-remote-claude.sh revive "<Name>"` moves it back to the live registry and relaunches it with full history.
- End for good, so it stops now and stops returning on reboot:

      source ~/OPS/.claude-config/remote-sessions/lib-remote-claude.sh && \
        rc_deregister "$(rc_normalize_name "<Name>")"
      tmux kill-session -t "=<Name>"

Re-running the launcher with an existing name resumes it and reuses its dir, id, and profile; a new dir arg is ignored, so deregister first to move it. A `RC_GUARANTEED_NAMES` entry in `lib-remote-claude.sh` is always kept running by the boot script; archiving one is refused (`ERR_GUARANTEED`) because it would orphan the session's history.

## Mechanics: the tmux target trap

Pane-level tmux commands (`send-keys`, `capture-pane`, `display-message`) do not resolve a bare `=<Name>` exact-session target on recent tmux; they need the window component `=<Name>:`. Session-level commands (`has-session`, `kill-session`) still take bare `=<Name>`. The launcher handles this internally; the trap only bites if you hand-roll `tmux new-session` plus `send-keys` yourself, so prefer the launcher. To read a pane: `tmux capture-pane -p -t "=<Name>:"`. To hand a running session new work, write the work order to a file and inject a single line pointing at it (`send-keys -t "=<Name>:" -l 'read <path> and execute it'` then a separate `send-keys -t "=<Name>:" Enter`); a multi-line paste can submit early. The durable cross-session baton itself is `session-handoff`'s job.

## Self-registration

A `SessionStart` hook (`.claude-config/hooks/remote-session-register.sh`) registers any Claude session started by hand inside tmux, so a session the operator created without this skill also returns on reboot. It is an idempotent upsert, respects archived names, and is disabled with `RC_AUTOREGISTER=0`.
