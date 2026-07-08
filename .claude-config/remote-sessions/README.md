# Remote-controlled Claude sessions

Run always-on Claude Code sessions in `tmux` that you drive from another device
(phone, laptop) via `claude --remote-control <Name>` and your claude.ai account.
Sessions **persist and resume across reboots**: a registry records each session,
an `@reboot` cron recreates them, and each resumes its conversation from its
stable `--session-id`.

## Pieces

| File | Role |
|------|------|
| `lib-remote-claude.sh` | Shared library — naming, registry I/O, launch/resume, archive/revive. Sourced by the others. |
| `start-remote-claude.sh` | `@reboot` boot target — waits for network, then recreates + resumes every registered session. |
| `new-remote-claude.sh <name> [dir]` | Start one session on demand. |
| `archive-remote-claude.sh <archive\|revive\|list> [name]` | Park a session (keeps history, stops it returning on boot) / bring it back / list parked. |
| `../hooks/remote-session-register.sh` | `SessionStart` hook — any Claude session started inside `tmux` self-registers (idempotent upsert), so boot-resume covers hand-launched sessions, not only skill-created ones. |
| `registry.tsv.example` | Sample registry. The live registry is `~/.claude-remote-sessions.tsv` (machine-local, not committed). |
| `../systemd/tmux-main.service` | Optional: a base `main` tmux session at boot. |

The companion **`remote-session` skill** (`SKILLS/remote-session/`) lets Claude spin
sessions up on request.

## Registry schema

The live registry (`~/.claude-remote-sessions.tsv`) is TAB-separated, one row per
session:

| Column | Required | Meaning |
|--------|----------|---------|
| `NAME` | yes | `Title-Case-Hyphen` session name (also the `tmux` + remote-control name). |
| `WORKDIR` | yes | Directory Claude opens in. |
| `SESSION_ID` | yes | Stable `--session-id`; boot-resume replays it with `-r` once a transcript exists. |
| `CONFIG_DIR` | no | Secondary Claude Code profile — a `CLAUDE_CONFIG_DIR`. Empty/absent means the default `~/.claude`. When set, resume searches `<CONFIG_DIR>/projects` and relaunches the session under that profile; **without it a secondary-profile session would silently start fresh** under the default profile. |

3-column (default-profile) rows and 4-column rows coexist — every reader treats a
missing 4th column as the default profile, so older registries keep working.

## Prerequisites

- `tmux` and `curl` installed.
- The `claude` CLI, signed in to a claude.ai account that supports Remote Control.

## Install

1. **Boot resume** — add the `@reboot` cron (paths derive from `$HOME`):

   ```
   @reboot $HOME/OPS/.claude-config/remote-sessions/start-remote-claude.sh >> $HOME/.claude-boot-sessions.log 2>&1
   ```

1b. **Auto-register hand-launched sessions** (optional) — register the `SessionStart`
   hook so any Claude session started inside `tmux` adds itself to the registry and
   returns on the next reboot, not just skill-created ones. Add to the Claude Code
   `settings.json` (same `$HOME`-fallback shape the harness's other hook entries use —
   `OPS_DIR` overrides the deploy root, else `$HOME/OPS`):

   ```json
   {
     "hooks": {
       "SessionStart": [
         {
           "hooks": [
             {
               "type": "command",
               "command": "H=\"${OPS_DIR:-$HOME/OPS}\"; [ -x \"$H/.claude-config/hooks/remote-session-register.sh\" ] && \"$H/.claude-config/hooks/remote-session-register.sh\""
             }
           ]
         }
       ]
     }
   }
   ```

   Hook config loads at session start, so **already-running sessions register on their
   next restart/clear/compact**, not immediately. Disable per-machine with
   `RC_AUTOREGISTER=0`. The hook never blocks session start: it exits silently when not
   in `tmux`, when `tmux` is absent, or when its stdin is unparseable, and it refuses to
   re-register a name you have archived.

2. **Optional base tmux session** — enable the systemd user unit:

   ```
   systemctl --user enable --now tmux-main.service   # unit in ../systemd/
   ```

   Skip this if you deployed via linuxploitacious with its `TMUX` option —
   Stage 1 already writes and enables an identical `tmux-main.service`.

3. **Create your first session:**

   ```
   ~/OPS/.claude-config/remote-sessions/new-remote-claude.sh "Main"
   ```

## Configuration (env vars, all optional)

| Var | Default | Meaning |
|-----|---------|---------|
| `RC_DEFAULT_WORKDIR` | `$HOME` | Directory a session opens in when none is given. |
| `RC_REGISTRY` | `$HOME/.claude-remote-sessions.tsv` | Live registry (recreated on boot). |
| `RC_ARCHIVE` | `$HOME/.claude-remote-sessions.archive.tsv` | Parked sessions (ignored on boot). |
| `RC_ENVFILE` | `$HOME/.claude-mcp.env` | Optional env sourced into each session (e.g. MCP secrets). Absent by default. |
| `RC_AUTOREGISTER` | `1` (on) | Set `0` to disable the `SessionStart` auto-register hook (Install step 1b). |

**Guaranteed sessions:** edit `RC_GUARANTEED_NAMES` in `lib-remote-claude.sh` (e.g.
`( "Main" )`) to always keep one or more sessions registered and running — the boot
script self-heals them (re-seeds a fresh id if the registry row is ever lost, so
history survives normal reboots).

## Notes

- Session names normalize to `Title-Case-Hyphen` (`morning briefing` →
  `Morning-Briefing`); any casing/spacing resolves back to the stored name.
- Deleting a session in the claude.ai UI orphans its registry row (next boot tries a
  dead `-r <id>`) — run `rc_deregister <Name>` to clean it up.
- Renaming a session in the app is **not** durable across reboot — the boot script
  relaunches under the registry name. Set the name at creation.
