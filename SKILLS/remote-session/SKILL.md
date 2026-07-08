---
name: remote-session
description: Start a new remote-controlled Claude Code session in tmux on this machine that the operator can drive from another device (e.g. the claude.ai mobile app). Use when they ask to "start/spin up/open a new remote session (called X)", "give me a session for X", "new remote control session", optionally naming a directory. Creates a tmux session, launches `claude --remote-control` in the chosen dir (default $HOME), names it with the Title-Case-Hyphen convention, and reports the session's working directory back so no manual sanity check is needed.
---

# Start a remote-controlled Claude session

This machine can run always-on Claude Code sessions in tmux that the operator
remote-controls from another device (`claude --remote-control <Name>`, reachable
via their claude.ai account). This skill spins up sessions on demand; each one
persists across reboots via a registry + an `@reboot` cron
(`~/OPS/.claude-config/remote-sessions/start-remote-claude.sh`). Optionally one or
more **guaranteed** sessions are always kept running (see the feature README).

## What the operator gives you

- **A name** (required) — e.g. "Trading", "morning briefing", "MCP".
- **A directory** (optional) — where Claude should open. Default to `$HOME` if they
  don't say. They may name it loosely ("the website repo", "the mcp server");
  resolve it to a real path first (consult `~/OPS/PROJECTS/projects-map.md` for the
  project layout). If a path they name doesn't resolve, ask rather than guess.

## How to do it

Run the companion script — it handles naming, the tmux session, the
`claude --remote-control` launch, the first-run MCP prompt, and the cwd
sanity-check in one shot:

    ~/OPS/.claude-config/remote-sessions/new-remote-claude.sh "<name they gave>" [resolved-workdir]

- Pass the name **exactly as they said it**; the script applies the naming
  convention (Title-Case each word, hyphen-join — `morning briefing` →
  `Morning-Briefing`). Don't pre-format it yourself.
- Omit the second arg to default to `$HOME`; pass a resolved absolute path when
  they named a directory.

## Reading the result

The script prints one status line and uses exit codes:

- `OK name=<Name> cwd=<dir> ... profile=<default|name> remote_control=on` (exit 0) —
  success. **Report back:** the final session name, the directory it opened in (the
  sanity check — confirm it's the dir they wanted), and that it's live on their device
  now. `profile=` is `default` unless the session runs under a secondary
  `CLAUDE_CONFIG_DIR` profile, in which case it names that profile.
- `ERR_EXISTS` (exit 3) — a session with that name is already running (script prints
  its cwd). Tell them; offer a different name or the existing one.
- `ERR_DIR` (exit 4) — the directory doesn't exist. Ask for the right path.
- `ERR_USAGE` / `ERR_NAME` (exit 2) — no usable name; ask what to call it.

## Persistence across reboot

Every session created this way is written to the **registry**
(`~/.claude-remote-sessions.tsv`, `NAME<TAB>WORKDIR<TAB>SESSION_ID[<TAB>CONFIG_DIR]`).
On reboot the `@reboot` boot script (`start-remote-claude.sh`) recreates every
registered session **and resumes its conversation** (each has a stable
`--session-id`; the boot script uses `-r` when a transcript exists, `--session-id` on
first create). So a session made today comes back — with its history — after a reboot.

- **Profile-aware resume.** The optional 4th column, `CONFIG_DIR`, holds a secondary
  Claude Code profile (`CLAUDE_CONFIG_DIR`); empty means the default `~/.claude`. A
  session started under a secondary profile keeps its transcript under
  `<CONFIG_DIR>/projects`, so the boot script resumes it there and relaunches it under
  that profile — otherwise it would silently start fresh. The script captures the
  caller's live `CLAUDE_CONFIG_DIR` at creation, so this is automatic.
- **Hand-launched sessions self-register.** A `SessionStart` hook
  (`.claude-config/hooks/remote-session-register.sh`) registers any Claude session
  started inside `tmux`, so sessions the operator created by hand — not via this skill
  — also return on reboot. It is an idempotent upsert (the same tmux session
  re-registers with its newest session id on each restart), respects archived names,
  and is disabled with `RC_AUTOREGISTER=0`. See the feature README for install.

- **Stop a session returning on reboot:** `source ~/OPS/.claude-config/remote-sessions/lib-remote-claude.sh && rc_deregister <Name>`
  (then `tmux kill-session -t <Name>`). Or park it with history:
  `~/OPS/.claude-config/remote-sessions/archive-remote-claude.sh archive <Name>`.
- **Re-running the skill with an existing name** reuses that name's registered dir +
  session-id, so it **resumes** rather than starting fresh (a new dir arg is ignored
  for a known name — deregister first to move it).

## Notes

- All scripts share `~/OPS/.claude-config/remote-sessions/lib-remote-claude.sh` (one
  source of truth). See that directory's `README.md` for install + configuration.
- The sanity check reports the tmux pane's working directory (where `claude`
  launched) — non-invasive; it does **not** inject a prompt into the new session.
  Don't send keys into the session to ask its cwd.
- List current sessions: `tmux ls`. Tear one down: `tmux kill-session -t <Name>`.
  List parked: `archive-remote-claude.sh list`.
- The optional `ENVFILE` (`~/.claude-mcp.env`, override via `RC_ENVFILE`) is sourced
  with `2>/dev/null` — harmless if absent. Create it only to inject local env for a
  session's MCP servers.
