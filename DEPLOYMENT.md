# OPS Deployment

How to deploy OPS on a new machine, from zero to fully working. Read this first
when setting up a new host.

This doc is the authoritative deployment reference. `CLAUDE.md` and the READMEs
point here. Do not duplicate steps elsewhere; reference this file.

## Architecture: Two-Stage Deploy

Deployment splits cleanly into two stages with no overlap. Stage 1 invokes
Stage 2 automatically — no manual step between them.

| Stage | Owner | Repo | What it does |
|-------|-------|------|--------------|
| **1 — Host setup** | `shellSetup.sh` / `winSetup.ps1` | `linuxploitacious` (public) | OS packages, dotfiles via Stow, AI CLI install, `gh` auth, Level 1 Claude files (`CLAUDE.md`, `settings.json`, `statusline.sh`), clone your private OPS copy, **then invoke Stage 2**. |
| **2 — OPS setup** | `.claude-config/deploy.sh` (Linux/macOS) / `deploy.ps1` (Windows) | your private OPS copy | Symlink `~/.claude/{skills,commands,agents,workflows}`. Wire `WORKFORCE/bin` onto PATH. Wire the `claude-wrapper` shim. Initialize auto-memory git-sync. Schedule daily backup. Install Claude Code plugins. Seed the trust anchor. |

Rule: **anything OPS-specific lives in Stage 2.** linuxploitacious clones the
repo and hands off — it does not configure OPS itself.

On Linux, Stage 1's OPS routine ends with `bash ~/OPS/.claude-config/deploy.sh`.
The operator does nothing extra.

## Stage 1: Host setup

Run on a fresh machine. Source:
<https://github.com/Exploitacious/linuxploitacious> (public).

The installer lives at **`~/linuxploitacious/`** on both Linux and Windows —
outside the `OPS/PROJECTS/` convention because Stow + matching symlink layouts
expect it as a home-folder sibling. See its README for the full reason.

**Linux:**
```bash
curl -fsSL https://raw.githubusercontent.com/Exploitacious/linuxploitacious/main/shellSetup.sh | bash
```

In the menu, pick:
- `SSHKEY` (provisions a GitHub key + `gh auth` — **required before the OPS
  clone**: your OPS copy is a private repo, so the clone can't see it without an
  authenticated `gh`)
- `AI Harness` (the `HARNESS` menu item — clones your private OPS copy to
  `~/OPS`; if you don't have one yet, it offers to create one from the
  `Exploitacious/OPS` template)
- Anything else relevant (zsh, omp, btop, etc.)

**Windows:** Run from an elevated PowerShell. Same source repo.

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
.\winSetup.ps1
```

In the checkbox menu, toggle on:
- `SSHKEY` (provisions `gh auth login` — required before the OPS clone)
- `AI Harness` (the `HARNESS` menu item — clones your private OPS copy to
  `~/OPS`, then auto-invokes Stage 2)
- Anything else relevant (PS7, WezTerm, OMP, Claude Code, etc.)

After Stage 1 completes with the `AI Harness` item selected, the installer
automatically invokes Stage 2 — `bash ~/OPS/.claude-config/deploy.sh` on Linux,
`& "$HOME\OPS\.claude-config\deploy.ps1"` on Windows — once the clone/sync
finishes. No additional command needed.

## Stage 2: OPS setup

Auto-invoked by Stage 1 on both Linux and Windows (when the `AI Harness` menu
item is selected). Manual invocation is only needed when:

- You deselected the `AI Harness` item and want to invoke it later
- You pulled updates and want to re-run idempotent setup
- Stage 1's auto-invoke failed and you're recovering

**Linux / macOS (bash):**
```bash
bash ~/OPS/.claude-config/deploy.sh
```

**Windows (PowerShell):**
```powershell
& "$HOME\OPS\.claude-config\deploy.ps1"
```

Both scripts are idempotent — safe to re-run anytime.

### What Stage 2 does (Linux, `deploy.sh`)

In order:

1. **Symlink `~/.claude/{skills,commands,agents,workflows}` → the matching OPS
   directories.** `skills` → `SKILLS/`; the other three →
   `.claude-config/{commands,agents,workflows}/`. Any real dir already at a
   target is backed up, not clobbered. This is the single source for Claude
   Code's skills, slash commands, sub-agent definitions, and workflow scripts.

2. **Wire `WORKFORCE/bin` onto PATH.** `chmod +x` every non-`.ps1` script in
   that dir, then export the dir ahead of existing PATH by writing to the
   untracked `~/.zshrc.local` **and** `~/.bashrc.local` seam. It writes to the
   `.local` files, not `~/.zshrc` / `~/.bashrc` directly, because those are Stow
   symlinks into the public linuxploitacious repo — appending there would either
   dirty that repo or be wiped on its next `git pull --ff-only`. Result:
   `ac-status`, `ac-msg`, and the rest of the `ac-*` helpers are globally
   callable in new shells.

3. **Wire `claude-wrapper.sh` into the invoking user's and root's shellrcs.**
   The wrapper handles two problems that appear when `claude` runs under both a
   regular user and root on the same host: (a) Claude Code refuses
   `bypassPermissions` as root, so the wrapper injects `--permission-mode auto`
   at the CLI level; (b) concurrent `claude` processes across two UIDs corrupt
   shared state, so the wrapper holds a `flock` on `~/.claude/.instance.lock`.
   Root's rcs are wired only if passwordless sudo is available.

4. **Wire the always-on ultracode shim** (untracked `~/.<shell>rc.local` seam).
   A `claude()` shell function that launches interactive Claude Code with
   `--settings '{"ultracode":true}'` unless the caller already passed
   `--settings`. Kept out of the tracked repo and out of the flock wrapper on
   purpose — see the comment in `deploy.sh` for why. Idempotent via a marker.

5. **Initialize Claude Code auto-memory git-sync.** Invokes
   `WORKFORCE/bin/ac-memory-init --auto-commit`, which walks Claude's encoded
   cwd subdirs under `~/.claude/projects/` and symlinks each into
   `.claude-memory/<host>-<encoded>/` so per-session memory survives in this
   repo (and syncs to your other machines on push).

6. **Schedule daily backup.** Installs a user crontab entry
   (`0 9 * * * ~/OPS/.claude-config/backup/daily-sync.sh`). The sync script
   commits + pushes any uncommitted changes to the OPS origin (no-op if clean).

7. **Install Claude Code plugins.** Adds the `JuliusBrussee/caveman` marketplace
   and installs the `caveman` plugin. A bare `bash deploy.sh` doesn't source a
   login profile, so it probes known install locations (`~/.local/bin`, pnpm,
   npm-global, `/usr/local/bin`, `/opt/homebrew/bin`) to find `claude`.

8. **Seed the trust anchor.** Marks `$HOME` trusted in `~/.claude/.claude.json`
   (`hasTrustDialogAccepted: true`) so Claude Code's parent-dir trust walk
   covers every repo under `$HOME` with no folder-trust prompt. Keyed off
   `$HOME` (never a hardcoded username); idempotent and atomic — merges into the
   existing `.claude.json` without touching other keys. If you run a second
   Claude Code profile via `CLAUDE_CONFIG_DIR`, re-run against that config dir's
   `.claude.json` too — it isn't covered automatically.

### What Stage 2 does (Windows, `deploy.ps1`)

Windows runs single-user, so the pipeline is shorter: symlink
`~/.claude/{skills,commands,agents,workflows}`, wire `WORKFORCE/bin` onto
PATH via an untracked `profile.local.ps1` seam (one per PowerShell edition,
under `Documents/PowerShell` and `Documents/WindowsPowerShell`) — never
`$PROFILE` itself, since `$PROFILE` is a shim/symlink tied to the public
linuxploitacious repo and `deploy.ps1` refuses to append there — initialize
auto-memory git-sync (`ac-memory-init.ps1`), register a `OPS Daily Backup`
scheduled task, and install the caveman plugin.

**Windows parity gap:** the `claude-wrapper` remains Linux-only (a root/user
flock is meaningless on single-user Windows). The ultracode shim and the
trust-anchor seed ARE implemented in `deploy.ps1` (steps 4-5) — parity holds
for those two.

### Verifying Stage 2

After the script finishes:

```bash
# Skills should resolve — listing matches SKILLS/ contents
diff <(ls ~/.claude/skills/) <(ls ~/OPS/SKILLS/)   # empty diff == correct

# WORKFORCE/bin should be on PATH after opening a new shell
which ac-status        # Linux/macOS
Get-Command ac-status  # Windows PowerShell

# Plugin should be registered (expect: caveman)
claude plugin list

# Backup scheduler
crontab -l | grep OPS                       # Linux
schtasks /Query /TN "OPS Daily Backup"      # Windows
```

If all succeed, deployment is complete. Open a new shell and use Claude Code
normally.

## Hooks and the drift gate (activated outside Stage 2)

Two pieces of OPS machinery ship in the repo but are **not** wired by the Stage
2 deploy scripts — they activate through Claude Code's config and systemd
directly.

- **Hooks** — the scripts in `.claude-config/hooks/` (SessionStart briefing +
  foreman-charter injection, pre-compact snapshot, post-compact resume,
  handoff-check, memory-index, the context-watch escalation ladder
  (Stop + PostToolUse), and the secrets/git guards) are registered in
  `settings.json`, which is a **Level 1 file owned by Stage 1**
  (linuxploitacious). Its hook entries point at these scripts by path, so the
  hooks come alive as soon as Stage 1 has deployed `settings.json` and this repo
  is at `~/OPS`. Editing the hook scripts here takes effect immediately; adding
  a *new* hook means registering it in the Stage 1 `settings.json`.

- **systemd `ops-*` timers** — `.claude-config/systemd/` ships two user units:
  `ops-verify.timer` (nightly drift gate that runs `.claude-config/bin/verify-ops.sh`)
  and `ops-memory-gc.timer` (weekly read-only memory-pool inventory via
  `ac-memory-gc`). Both write their reports to `~/.local/state/ops/`, which
  `session-briefing.sh` surfaces at session start. Enable them per-user:

  ```bash
  mkdir -p ~/.config/systemd/user
  ln -sf ~/OPS/.claude-config/systemd/ops-*.{service,timer} ~/.config/systemd/user/
  systemctl --user daemon-reload
  systemctl --user enable --now ops-verify.timer ops-memory-gc.timer
  ```

## Deploying without linuxploitacious

linuxploitacious is the paved road, not a hard dependency. Stage 2 only needs
this repo cloned to `~/OPS` and the Claude Code CLI installed. On any Linux or
macOS host:

```bash
git clone git@github.com:<you>/<your-name>.git ~/OPS
bash ~/OPS/.claude-config/deploy.sh
```

On Windows:

```powershell
git clone git@github.com:<you>/<your-name>.git $HOME\OPS
& "$HOME\OPS\.claude-config\deploy.ps1"
```

What you give up by skipping Stage 1: the Level 1 Claude files (`CLAUDE.md`,
`settings.json`, `statusline.sh`) and the OS-level shell/dotfile setup. Provide
your own `settings.json` (that's where hooks register — see above), and Stage 2
handles the rest.

## Multi-machine

OPS is designed to run on several machines off **one private repo**. Clone the
same repo to `~/OPS` on each host and run Stage 2 there. Auto-memory is the
shared surface: `ac-memory-init` symlinks each machine's Claude session-memory
dirs into `.claude-memory/<host>-<encoded>/`, and the daily backup cron commits
+ pushes them. Pull on another machine and that machine sees the memory the
first one wrote. Doctrine, identity (`CONTEXT/`), project lessons, and handoff
batons ride the same git sync — every machine boots from the same durable state.

## Updating an existing deploy

Pull latest, then re-run Stage 2:

```bash
cd ~/OPS && git pull --ff-only
bash ~/OPS/.claude-config/deploy.sh   # or deploy.ps1 on Windows
```

Stage 2 is idempotent — it no-ops where state is already correct.

## What stays out of these scripts

Explicitly NOT handled by Stage 2 (`deploy.sh` / `deploy.ps1`):

- **Level 1 Claude files** (`CLAUDE.md`, `settings.json`, `statusline.sh`) —
  these come from linuxploitacious (Stage 1). Editing them inside OPS does
  nothing.
- **OS-level shell config** (`.bashrc`, `.zshrc`, prompts, AI CLI installs) —
  Stage 1's responsibility.
- **The systemd `ops-*` timers** — shipped here but enabled manually (see
  "Hooks and the drift gate" above).
- **Project-scoped skills** that live inside specific
  `PROJECTS/<org>/<repo>/.claude/skills/` directories — those deploy with each
  project's own workflow.
- **Multi-agent runtime dirs** (`WORKFORCE/FLEETPROJECTS/<project>/`) — created
  on-demand by the Coordinator agent, not pre-provisioned.

## Adding a new step to Stage 2

If a new piece of OPS setup needs to run on every host:

1. Add it to **both** `deploy.sh` and `deploy.ps1`, with the same semantics.
2. Make it idempotent (check state before acting; no-op if already correct).
3. Update this doc's "What Stage 2 does" list.
4. Test on both OSes.

## Reference

- `.claude-config/deploy.sh` — Linux/macOS Stage 2 entry point.
- `.claude-config/deploy.ps1` — Windows Stage 2 entry point.
- `.claude-config/backup/daily-sync.sh` — backup script invoked by the scheduler.
- `.claude-config/hooks/` — SessionStart/pre-compact/guard hooks (registered via Stage 1 `settings.json`).
- `.claude-config/systemd/` — `ops-verify` + `ops-memory-gc` timers.
- `.claude-config/bin/verify-ops.sh` — the drift gate run by `ops-verify.timer`.
- `SKILLS/README.md` — what gets symlinked into `~/.claude/skills/`.
- `WORKFORCE/bin/claude-wrapper.sh` — root/user flock + permission-mode shim (Linux).
- `WORKFORCE/bin/ac-memory-init`, `ac-memory-init.ps1` — auto-memory git-sync.
- [`Exploitacious/linuxploitacious`](https://github.com/Exploitacious/linuxploitacious)
  — public Stage 1 repo (dotfiles + host provisioning).
