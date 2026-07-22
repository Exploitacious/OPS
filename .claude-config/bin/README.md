# `.claude-config/bin/` — operator utilities

Small, tracked helper scripts that ship with OPS and sync to every machine.

## `compact-cycle.sh` — automated /compact for a Claude session in tmux

The deterministic half of the automated compact ritual (the judgment half is
the `pre-compact-synthesis` skill, which runs the synthesis and writes the
resume baton BEFORE spawning this). A session cannot fire `/compact` on itself
— this spawns a detached `Compactor-<Key>` tmux session (plain bash, no Claude)
that waits for the target pane to go idle, types `/compact`, watches until
compaction completes, types the baton (or `--resume` text) as the next user
message, and self-destructs. On error/timeout it never types the resume — the
target stays paused with synthesis already on disk.

```
compact-cycle.sh --target <Session|Session:win.pane> [--baton FILE] [--resume "TEXT"]
                 [--no-resume] [--grace S] [--idle-timeout S] [--timeout S]
```

Runtime state (locks, logs, status, batons): `~/.claude-compact-cycle/`.
Consumers: the skill's self-compact exit, the `[context-watch]` escalation
ladder (`hooks/context-watch.sh` — Stop nags at 65/78/86/92% of the window
plus mid-turn PostToolUse injections from 86%; both registered in the Stage 1
`settings.json` template), and `WORKFORCE/bin/ac-compact-peer` (fleet,
`--no-resume`). tmux gotcha baked in: targets use the `=Name:` exact form —
bare names unique-prefix-match and pane-level commands reject bare `=Name`.

## `grabit` — file transfer over Tailscale

Moves files between a (usually headless) OPS box and whatever machine you're
driving it from, without SFTP or cloud. Everything rides the tailnet
(WireGuard-encrypted) and is **never public** — the browser mode uses
`tailscale serve`, not `funnel`.

```
grabit FILE...              push file(s) to the machine you're SSH'd in from (auto-detected)
grabit --to DEVICE FILE...  push to a specific tailnet device (name or 100.x IP)
grabit --serve PATH...      stage path(s) + expose over tailnet HTTPS; prints browser URLs
grabit --serve-off          tear the serve endpoint down
grabit --inbox [DIR]        pull files someone sent TO this box (default ~/grabit-inbox)
grabit --list               list tailnet devices
grabit -h
```

### How the default (push) works
`grabit report.pdf` reads `$SSH_CONNECTION` to learn which tailnet device you
connected from and Taildrops the file straight to that machine's Tailscale
inbox. **Windows auto-saves received files to your Downloads folder** (no tray
prompt); on macOS/Linux run `tailscale file get ~/Downloads`. Wherever you SSH
in from, the file comes back to you — no flags.

### Two modes, when to use which
- **Push (default):** one-shot, no sudo, lands in your inbox. Best for grabbing
  a file or two.
- **Serve (`--serve`):** stages the named files into `~/.cache/grabit-serve` and
  serves *only those* over tailnet HTTPS. Best for browsing/grabbing several
  files, or when the target isn't a Tailscale device. Needs sudo (serving a path
  is privileged) — that's why push is the default.

### Safety
`--serve` only ever exposes files you explicitly name (staged into a scratch
dir), so a neighbouring `.env` or secret can't leak. The serve endpoint is
tailnet-scoped (your own devices), not the public internet.

### One-time setup per new box
```
sudo tailscale set --operator=$USER     # lets push run without sudo
```
Taildrop must be enabled for the tailnet (it is by default). If `--serve` is
needed, the box also needs passwordless sudo for `tailscale` and tailnet HTTPS
enabled in the admin console.

### Put it on PATH (optional)
```
export PATH="$HOME/OPS/.claude-config/bin:$PATH"
```
Otherwise call it by path, or let your Claude Code session invoke it for you.
