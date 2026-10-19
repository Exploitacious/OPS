# Remote-controlled Claude sessions

Run Claude Code sessions in `tmux` that you drive from another device (phone,
laptop) through `claude --remote-control <Name>` and your claude.ai account.
Sessions are **hand-run**: you start one when you want it and park or end it
when its purpose is done. A small registry remembers what the launcher started
so you can resume, park, or revive a session by name; nothing brings a session
back after a reboot, and no hook registers one on its own.

Why hand-run: the earlier design (an `@reboot` resume of every registered
session plus a SessionStart hook that registered any tmux session) revived
finished sessions into stale context after every reboot, and it fought
tmux-resurrect and a restarting tmux unit over the same server, which showed
up as sessions appearing, vanishing, and taking each other down.

## Pieces

| File | Role |
|------|------|
| `lib-remote-claude.sh` | Shared library: naming, registry I/O, launch and resume, archive and revive. Sourced by the others. |
| `new-remote-claude.sh <name> [dir]` | Start one session, or resume a registered one by name. |
| `archive-remote-claude.sh <archive\|revive\|list\|sweep> [name]` | Park a session (keeps history) / bring it back / list parked / **`sweep`**: read-only health view of the registry (status, transcript age, tmux presence, name collisions). |
| `registry.tsv.example` | Sample registry. The live registry is `~/.claude-remote-sessions.tsv` (machine-local, not committed). |
| `../systemd/tmux-main.service` | Optional: a base `main` tmux session at login. |

The `remote-session` skill (`SKILLS/remote-session/`) lets Claude run this
lifecycle on request.

## Registry schema

The live registry (`~/.claude-remote-sessions.tsv`) is TAB-separated, one row per
session:

| Column | Required | Meaning |
|--------|----------|---------|
| `NAME` | yes | `Title-Case-Hyphen` session name (also the `tmux` and remote-control name). |
| `WORKDIR` | yes | Directory Claude opens in. |
| `SESSION_ID` | yes | Stable `--session-id`; a resume replays it with `-r` once a transcript exists. |
| `CONFIG_DIR` | no | Second Claude Code profile (a `CLAUDE_CONFIG_DIR`). Empty or absent means the default `~/.claude`. When set, resume searches `<CONFIG_DIR>/projects` and relaunches under that profile; **without it a second-profile session would silently start fresh** under the default profile. |

Three-column (default profile) and four-column rows coexist; every reader treats
a missing fourth column as the default profile.

## Prerequisites

- `tmux` installed.
- The `claude` CLI, signed in to a claude.ai account that supports Remote Control.

## Use

```
~/OPS/.claude-config/remote-sessions/new-remote-claude.sh "Main"        # start (or resume by name)
~/OPS/.claude-config/remote-sessions/archive-remote-claude.sh sweep     # what is registered, what runs
~/OPS/.claude-config/remote-sessions/archive-remote-claude.sh archive "Main"
~/OPS/.claude-config/remote-sessions/archive-remote-claude.sh revive "Main"
```

After a reboot, `sweep` shows registered sessions as `GONE`; resume the ones you
still need with `new-remote-claude.sh "<name>"` and park the rest.

Optional base tmux session: `systemctl --user enable --now tmux-main.service`
(unit in `../systemd/`). Skip it if Stage 1's `TMUX` option already wrote one.

### Upgrading from the reboot-resume design

If an earlier OPS install added the `@reboot ... start-remote-claude.sh` line to
your crontab, remove it (`crontab -e`); the script is gone, so the line only
logs an error at boot. If your Stage-1 `settings.json` still registers
`remote-session-register.sh`, remove that entry too (`verify-ops.sh` check 17
warns until it is gone).

## Configuration (env vars, all optional)

| Var | Default | Meaning |
|-----|---------|---------|
| `RC_DEFAULT_WORKDIR` | `$HOME` | Directory a session opens in when none is given. |
| `RC_REGISTRY` | `$HOME/.claude-remote-sessions.tsv` | Live registry. |
| `RC_ARCHIVE` | `$HOME/.claude-remote-sessions.archive.tsv` | Parked sessions. |
| `RC_ENVFILE` | `$HOME/.claude-mcp.env` | Optional env sourced into each session (e.g. MCP secrets). Absent by default. |
| `RC_STALE_DAYS` | `7` | Transcript age at which `sweep` flags a row `STALE`. |

## Keeping the registry clean

- **`archive-remote-claude.sh sweep`** flags each row: `GONE` (registered but not
  running), `STALE` (transcript older than `RC_STALE_DAYS`, a likely finished
  purpose), `IDLE` (running, detached), `OK`. It also scans for name
  **collisions**. Park what is finished; `session-close` does it at the end of a
  session's purpose.
- **Collision guard:** names normalize case and separators, so `dev` and `Dev`
  both map to registry name `Dev`; a stray differently-cased tmux session could
  otherwise be mistaken for the real one. `sweep` surfaces live collisions.

## One owner of the tmux server

Nothing may (re)create Claude sessions on its own. Keep these constraints (the
repo unit in `../systemd/` ships the safe shape; apply the tmux ones in your
`.tmux.conf`, as linuxploitacious's `TMUX` option does):

- `@continuum-restore` stays **off**; continuum only auto-saves.
- `claude` never appears in `@resurrect-processes`: a restored pane would run a
  bare `claude` with no `--remote-control` and no `-r`, a context-less impostor
  wearing the real session's name.
- `tmux-main.service` is `Type=oneshot` + `RemainAfterExit` + `KillMode=process`
  with an idempotent `has-session || new-session` start: it never owns or
  restarts the server.
- Every `tmux -t` target in these scripts uses `"=$name"` (exact match): bare
  names prefix-match, so `-t Dev` can hit `Dev2` and `kill-session` the wrong
  session.

## Notes

- Session names normalize to `Title-Case-Hyphen` (`morning briefing` becomes
  `Morning-Briefing`); any casing or spacing resolves back to the stored name.
- Deleting a session in the claude.ai UI orphans its registry row; run
  `rc_deregister <Name>` (source the lib first) to clean it up.
- Renaming a session in the app does not change the registry name; set the name
  at creation.
