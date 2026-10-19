# OPS Deployment

How to deploy OPS on a new machine, from zero to fully working. Read this first
when setting up a new host.

This doc is the authoritative deployment reference. `AGENTS.md` and the
READMEs point here. Do not duplicate steps elsewhere; reference this file.

## Architecture: Two-Stage Deploy

Deployment splits cleanly into two stages with no overlap. Stage 1 invokes
Stage 2 automatically; there is no manual step between them.

| Stage | Owner | Repo | What it does |
|-------|-------|------|--------------|
| **1. Host setup** | `shellSetup.sh` / `winSetup.ps1` | `linuxploitacious` (public) | OS packages, dotfiles via Stow, AI CLI install, `gh` auth, Level 1 Claude files (`CLAUDE.md`, `settings.json`, `statusline.sh`), clone your private OPS copy, **then invoke Stage 2**. |
| **2. OPS setup** | `.claude-config/deploy.sh` (Linux/macOS) / `deploy.ps1` (Windows) | your private OPS copy | Symlink `~/.claude/{skills,commands,agents,workflows}`. Mount the shared skills. Link the always-loaded core into `~/.claude/rules/`. Strip the retired fleet wiring. Wire the root wrapper. Write the ultracode shim. Initialize auto-memory git-sync. Schedule daily backup. Retire the caveman and ponytail plugins. Seed the trust anchor. |

Rule: **anything OPS-specific lives in Stage 2.** linuxploitacious clones the
repo and hands off; it does not configure OPS itself.

Stage 2 never writes `settings.json`. On Linux and macOS,
`~/.claude/settings.json` is a symlink into your linuxploitacious checkout, so
a write there would dirty that tracked public repo, and its next
`git pull --ff-only` fails whenever upstream changed the same file. The model
pins, the permission mode, and the other defaults that file sets are Stage
1's; README "Opinionated by design" lists them, and BOOTSTRAP's permission step
shows how to change the permission defaults without editing that file.

On Linux, Stage 1's OPS routine ends with `bash ~/OPS/.claude-config/deploy.sh`.
The operator does nothing extra.

## How the core loads

`CONTEXT/core.md` is the one file every session and lane must have loaded.
Stage 2 links it into `~/.claude/rules/ops-core.md`, and Claude Code loads
every user rule file at launch, for every project, with no approval prompt, on
every launch path that reads user settings: the terminal, T3 Code threads, IDE
extensions, `claude -p`, cron, and the subagents they spawn (Explore and Plan
excepted, as for any instruction file). Nothing about it depends on a shell
function or a launch flag.

The Stage-1 `~/.claude/CLAUDE.md` imports the maintainer's private core and,
when that import is absent (every OPS host), asks the model to read
`~/OPS/CONTEXT/core.md`. That is a requested read, not a load: a session can
answer before it reads, and Explore and Plan never see the instruction. The
rule link is the guarantee; the first lines of `core.md` tell a session that
already has it loaded not to read it again.

Check it on a host: `readlink -f ~/.claude/rules/ops-core.md` prints
`~/OPS/CONTEXT/core.md`, the session briefing's `Boot:` line says
`core.md loaded via rules/ops-core.md`, and `/context` in a new session lists
the rule under memory files. A second Claude Code profile
(`CLAUDE_CONFIG_DIR`) needs the same link in its own `rules/`.

## Stage 1: Host setup

Run on a fresh machine. Source:
<https://github.com/Exploitacious/linuxploitacious> (public).

The installer lives at **`~/linuxploitacious/`** on both Linux and Windows,
outside the `OPS/PROJECTS/` convention because Stow and the matching symlink
layouts expect it as a home-folder sibling. See its README for the full reason.

**Linux:**
```bash
curl -fsSL https://raw.githubusercontent.com/Exploitacious/linuxploitacious/main/shellSetup.sh | bash
```

In the menu, pick:
- `SSHKEY` (provisions a GitHub key + `gh auth`; **required before the OPS
  clone**: your OPS copy is a private repo, so the clone can't see it without an
  authenticated `gh`)
- `AI Harness` (the `HARNESS` menu item: clones your private OPS copy to
  `~/OPS`; if you don't have one yet, it offers to create one from the
  `Exploitacious/OPS` template)
- Anything else relevant (zsh, omp, btop, etc.)

**Windows:** Run from an elevated PowerShell. Same source repo.

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
.\winSetup.ps1
```

In the checkbox menu, toggle on:
- `SSHKEY` (provisions `gh auth login`; required before the OPS clone)
- `AI Harness` (the `HARNESS` menu item: clones your private OPS copy to
  `~/OPS`, then auto-invokes Stage 2)
- Anything else relevant (PS7, WezTerm, OMP, Claude Code, etc.)

After Stage 1 completes with the `AI Harness` item selected, the installer
invokes Stage 2 (`bash ~/OPS/.claude-config/deploy.sh` on Linux,
`& "$HOME\OPS\.claude-config\deploy.ps1"` on Windows) once the clone finishes.

## Stage 2: OPS setup

Auto-invoked by Stage 1 on both Linux and Windows (when the `AI Harness` menu
item is selected). Run it by hand when:

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

Both scripts are idempotent: safe to re-run anytime. Both take a flag that
skips every write outside your home directory (the root rc wiring, the
crontab entry, the scheduled task), for a test install under a throwaway
`HOME`: `deploy.sh --no-system` (or `OPS_DEPLOY_NO_SYSTEM=1`),
`deploy.ps1 -NoSystem`. A deploy that hits a failure it cannot work around
finishes the other steps, prints the failure, and exits non-zero.

### What Stage 2 does (Linux, `deploy.sh`)

In order:

1. **Symlink `~/.claude/{skills,commands,agents,workflows}` to the matching OPS
   directories.** `skills` points at `SKILLS/`; the other three at
   `.claude-config/{commands,agents,workflows}/`. Any real dir already at a
   target is backed up, not clobbered.

2. **Mount the shared skills.** `SKILLS/VENDORED.tsv` lists the portable skills
   OPS mounts from the public
   [`Exploitacious/agent-skills`](https://github.com/Exploitacious/agent-skills)
   repo. When `PROJECTS/Exploitacious/agent-skills` is absent, deploy clones it
   over HTTPS, then runs `.claude-config/bin/skills-vendor.sh sync` to mirror
   each listed skill into `SKILLS/<name>/` (rsync where installed, tar
   otherwise, so a minimal container needs no extra package). Deploy never
   pulls an existing clone: a re-deploy must not pull an unreviewed upstream
   change into skills every session loads. Update on purpose:
   `git -C ~/OPS/PROJECTS/Exploitacious/agent-skills pull --ff-only`, then
   `~/OPS/.claude-config/bin/skills-vendor.sh sync`. A failed clone (no
   network) prints an `[XX]` line and fails the deploy (`skills-mount`);
   `verify-ops.sh` warns that the mounts are MISSING until a re-run clones
   them.

3. **Link the always-loaded core** into `~/.claude/rules/ops-core.md` (see "How
   the core loads"). A regular file in the way is backed up under a name Claude
   Code does not load; a symlinked `rules/` dir is refused rather than written
   through. A missing core or a failed link fails the deploy.

4. **Strip the retired fleet wiring.** Earlier deploys appended a PATH export
   for `WORKFORCE/bin` to `~/.zshrc.local` and `~/.bashrc.local`, and a source
   line for the fleet's `claude-wrapper.sh` to `~/.zshrc` and `~/.bashrc` when
   those were real files. Deploy removes exactly those lines (whole-line
   matches; anything you wrote stays) and the blank line the old append put
   before them.

5. **Wire `claude-root-wrapper.sh` into root's shellrcs** (passwordless sudo
   only). The wrapper handles two problems that appear when `claude` runs as
   root on a host where you also run it: Claude Code refuses
   `bypassPermissions` as root, so the wrapper injects `--permission-mode auto`
   at the CLI level; and two UIDs sharing one config dir corrupt its state, so
   for root (or with `CLAUDE_SHARED_HOST` exported) the wrapper holds a `flock`
   on `<config dir>/.instance.lock`. Your own shell is not wrapped: a
   per-config-dir lock would block your concurrent sessions. A fleet-era block
   in `/root/.zshrc` or `/root/.bashrc` is healed in place.

6. **Write the always-on ultracode shim** to the untracked `~/.zshrc.local` and
   `~/.bashrc.local`: a `claude()` function that adds
   `--settings '{"ultracode":true}'` unless the caller passed `--settings`.
   It appends no system prompt (the core loads through `~/.claude/rules`). A
   version tag keys idempotency: a current block is left alone even if you
   edited it (BOOTSTRAP Round F does), and an older block (the retired boot
   shim, or the original ultracode-only one) is replaced, carrying over a
   customized `--settings` JSON. An ambiguous block is reported and left as it
   was. The ultracode default is an operator choice kept out of the public
   Stage-1 files on purpose.

7. **Check the git identity, then initialize Claude Code auto-memory
   git-sync.** Deploy first asks `git var` for your author and committer
   identity. A fresh account often has none (an empty name field and no
   FQDN to build an email from), and then every commit fails: memory-init's,
   the daily backup's, and every agent's. Without one, deploy prints the two
   `git config --global user.name` / `user.email` commands and finishes with
   a failure (`git-identity`). Then it runs
   `.claude-config/bin/memory-init --auto-commit`, which walks Claude's encoded
   cwd subdirs under `~/.claude/projects/` and symlinks each `memory/` into
   `.claude-memory/<host>-<encoded>/` so per-session memory survives in this
   repo and syncs to your other machines. It commits each new pool and pushes
   only to a private origin (see "The push gate" below).

8. **Schedule daily backup.** Installs a user crontab entry
   (`0 9 * * * ~/OPS/.claude-config/backup/daily-sync.sh`). The sync script
   commits any uncommitted changes and pushes them to the OPS origin when the
   push gate verifies it private (no-op if clean; an origin with no branch of
   that name yet gets it as a first push), pulls every project repo, then runs
   `branch-gc --apply` to remove merged branches and park their worktrees in a
   7-day trash. It needs a signed-in `gh`, git 2.45 or newer and GNU coreutils
   9.5 or newer: without `gh` it removes nothing, an older git skips every
   repository, and an older `mv` cannot move a worktree to the trash; each case
   is logged. The sync script logs to `.claude-config/backup/sync.log`, and
   always exits 0, so the session briefing's `Backup:` line repeats the last
   run's OPS-stage errors and skipped pushes at boot. Skipped with `--no-system`.

   **The push gate.** Your copy holds your memory, context, and notes, so the
   two automatic pushes (memory-init's and the daily backup's) run only when
   `.claude-config/bin/origin-private-check` verifies that every push URL of
   `origin` is a private GitHub repo, asking through `gh api`. A public origin
   (a tryout clone of the `Exploitacious/OPS` template, a copy made public by
   mistake, a public fork) is refused; so is an origin it cannot verify (`gh`
   missing or signed out, offline, or a host other than github.com). Either way
   the commit stays local, and the deploy output or `sync.log` names the
   reason and the fix; the next daily run that passes the gate pushes every
   held commit. Your own git server, which `gh` cannot ask: after confirming
   the repo is private, run `git -C ~/OPS config ops.pushVerified true`. That
   opt-in is per repo, covers only what cannot be verified, and never
   overrides a public answer. `memory-init.ps1` applies the same rule on
   Windows, and the Windows backup task runs this same script in Git Bash.
   Agent pushes meet the same gate: the git-guard hook runs it on the pushes
   an agent makes from this copy (through `cd`, `git -C`, `--git-dir`,
   `bash -c`, pipes, `$(...)` and aliases) and blocks one it cannot verify,
   one to a remote other than origin, and one carrying a `-c` setting that
   could move it. Where it cannot follow a command (no Python 3, an
   unparseable line, a directory held in a loop variable) it falls back to
   checking every OPS copy the command names. It is a seatbelt for normal
   agent pushes, not a sandbox: exotic wrappers (`setsid`, `find -exec`,
   `ssh`, `python -c` and the like) and scripts run from a file are not
   parsed. The real protection is a private origin. The hook header in
   `.claude-config/hooks/git-guard.sh` lists what it covers and its limits.

9. **Retire the caveman and ponytail plugins.** Runs
   `claude plugin uninstall <name>@<name>` and
   `claude plugin marketplace remove <name>` for both, so a host provisioned by
   an earlier OPS release loses them; a no-op once they are gone. Stage 1
   retires them too: their modes are now part of the harness's own operating
   rules, and an earlier Stage 2 reinstalled caveman, unpinned, from its
   third-party marketplace right after Stage 1 removed it. Removal goes through
   the CLI only; no plugins directory is deleted by hand. A bare
   `bash deploy.sh` doesn't source a login profile, so it probes known install
   locations (`~/.local/bin`, pnpm, npm-global, `/usr/local/bin`,
   `/opt/homebrew/bin`) to find `claude`.

   Retirement first reads the CLI inventories. If a retired plugin or
   marketplace is still declared in the user's settings, it warns and skips
   that item: CLI removal would also rewrite `settings.json`, following its
   Stage-1 symlink. Update Stage 1 before re-running deploy. Removals use
   `--scope user` so they cannot alter the caller's project settings; a
   marketplace registered outside that scope stays put with a warning.
   Inventory and removal failures are visible warnings, never a silent success.

10. **Seed the trust anchor.** Marks `$HOME` trusted in `~/.claude.json`, which
    sits beside `~/.claude/`, not inside it (`hasTrustDialogAccepted: true`), so
    Claude Code's parent-dir trust walk
    covers every repo under `$HOME` with no folder-trust prompt. Keyed off
    `$HOME`; idempotent; merges into the existing file without touching other
    keys. A second profile via `CLAUDE_CONFIG_DIR` is not covered
    automatically.

On a host where a T3 Code runtime is present, deploy ends with a pointer to the
one-time browser setup ("T3 Code hosts" below); it never runs it.

### What Stage 2 does (Windows, `deploy.ps1`)

Windows runs single-user, so the pipeline is shorter: the same four
`~/.claude` links; the core rule (a symlink, or, where Windows refuses one
without Developer Mode, a rule file that imports the core by absolute path;
UNVERIFIED that Claude Code resolves a drive-letter import, so run `/context`
once to confirm); removal of the retired `WORKFORCE\bin` PATH block from the
untracked `profile.local.ps1` seams (one per PowerShell edition, under
`Documents/PowerShell` and `Documents/WindowsPowerShell`; never `$PROFILE`,
which is tied to the public linuxploitacious repo); the git identity check
(step 7); auto-memory git-sync
(`bin\memory-init.ps1`, behind the same push gate as step 8); the trust
anchor; the ultracode shim in the seam; an `OPS Daily Backup` scheduled task
that runs `daily-sync.sh` in Git Bash (skipped with `-NoSystem`); the skill mount
(clone, then `skills-vendor.sh sync` through Git Bash); plugin retirement (same
CLI calls as step 9); and a Git Bash pin plus the guard self-test.

**Windows parity gap:** the root wrapper is Linux-only (a root/user lock is
meaningless on single-user Windows).

### Verifying Stage 2

After the script finishes:

```bash
# The core loads on every launch path (expect: the path of CONTEXT/core.md)
readlink -f ~/.claude/rules/ops-core.md

# Skills resolve, and every mounted skill matches its source (expect: OK lines only)
diff <(ls ~/.claude/skills/) <(ls ~/OPS/SKILLS/)   # empty diff == correct
~/OPS/.claude-config/bin/skills-vendor.sh --check

# No retired plugin should remain (expect: neither caveman nor ponytail listed)
claude plugin list

# Stage 2 left the Stage-1 settings alone (expect: no output)
git -C ~/linuxploitacious status --short -- claude/.claude/settings.json

# The drift gate passes (expect: no FAIL line, and "0 fail" in the last line,
# "verify-ops: <n> ok · <n> warn · 0 fail (<timestamp>)")
bash ~/OPS/.claude-config/bin/verify-ops.sh

# Backup scheduler
crontab -l | grep OPS                       # Linux
schtasks /Query /TN "OPS Daily Backup"      # Windows

# The backup may push (expect exit 0 and the line
# "origin-private-check: private: github.com/<you>/<repo> is private";
# exit 1 is a public origin, exit 2 one it cannot verify)
bash ~/OPS/.claude-config/bin/origin-private-check ~/OPS; echo "exit $?"

# Commits can run (expect one line, "Your Name <you@example.com> <timestamp> <offset>";
# an error means every commit will fail)
git -C ~/OPS var GIT_AUTHOR_IDENT
```

Then open a new session (any launch path) and check the briefing's `Boot:`
line. If all succeed, deployment is complete.

### Testing a deploy under a throwaway HOME

To try a deploy, or a change to the deployer, without touching your real setup,
run it under a throwaway `HOME`. CI does exactly this on every pull request
(the `smoke` job in `.github/workflows/gate.yml`). The subshell keeps the new
`HOME` out of your session:

```bash
(
  export HOME="$(mktemp -d)"; unset CLAUDE_CONFIG_DIR
  git config --global user.name "Throwaway" && git config --global user.email throwaway@example.invalid
  mkdir -p ~/.claude
  curl -fsSL https://raw.githubusercontent.com/Exploitacious/linuxploitacious/HEAD/claude/.claude/settings.json -o ~/.claude/settings.json
  git clone <path or URL of your checkout> ~/OPS
  git -C ~/OPS remote set-url --push origin /dev/null   # see below: never push from the copy
  bash ~/OPS/.claude-config/deploy.sh --no-system
  bash ~/OPS/.claude-config/bin/verify-ops.sh
)
```

The `curl` line fetches the Stage-1 settings a new host has; the git identity
is the prerequisite from step 7. Expect `Deploy complete.` and, on the last
line of the gate, `verify-ops: <n> ok · 0 warn · 0 fail (<timestamp>)`, with
both commands exiting 0. `--no-system` keeps deploy off your crontab and root's
rc files. Deploy still clones the public skill source over HTTPS, so the test
needs network access, and the throwaway directory stays in your temp dir until
you delete it.

Do not drop the `set-url --push` line when you clone a URL. Deploy's memory sync
commits to the copy and pushes it whenever the push gate finds origin private,
and a new `HOME` hides neither your GitHub login (an exported `GH_TOKEN` or
`GITHUB_TOKEN`, or `GH_CONFIG_DIR`) nor your SSH keys (ssh finds `~/.ssh`
through the passwd entry, not `$HOME`). Without the line, a clone of your
private repository gets a `feat(memory): seed .claude-memory/...` commit pushed
to the real origin, and `--no-system` does not prevent that. With the push URL
at `/dev/null` the gate answers "origin is a local path" and the commit stays in
the throwaway copy (the same answer a clone of a local path gets).

## T3 Code hosts

T3 Code runs Claude Code as a provider thread, so nothing on the OPS boot path
may depend on a shell function: the core loads through `~/.claude/rules`, the
hooks through the Stage-1 settings, exactly as in a terminal
(`CONTEXT/how-i-work.md` § "Hosted inside T3 Code" has the working rules).

**Enable T3's headless browser once per host.** T3's page previews and browser
tools run a headless Chrome that needs host setup:

```bash
t3="$(ls -1d ~/.t3/runtime/versions/*/t3 | sort -V | tail -1)"
sudo "$t3" browser setup
```

The binary is `~/.t3/runtime/versions/<version>/t3`; the line above picks the
newest. The setup installs the browser's system libraries and, on Ubuntu 23.10
and later, an AppArmor profile scoped to T3's chrome-headless-shell
(`/etc/apparmor.d/t3-chrome-headless-shell`); it never changes the system-wide
user-namespace restriction. It needs sudo, so deploy only points at it;
BOOTSTRAP Round G offers to run it with your yes. Run it again after a T3
upgrade if the browser tools stop working.

**Permission mode under T3.** T3 sets each Claude thread's permission mode from
its own settings, not from the `claude()` shell function, so BOOTSTRAP Round F's
terminal option does not reach T3 threads; the managed-settings option does.

## Hooks and the drift gate (activated outside Stage 2)

Three pieces of OPS machinery ship in the repo but are **not** wired by the
Stage 2 deploy scripts.

- **Hooks:** the scripts in `.claude-config/hooks/` (SessionStart briefing,
  pre-compact snapshot, post-compact resume, handoff-check, memory-index, the
  context-watch ladder and readout, and the secrets/git guards) are registered
  in `settings.json`, a **Level 1 file owned by Stage 1**. Its hook entries
  point at these scripts by path, so they come alive once Stage 1 has deployed
  `settings.json` and this repo is at `~/OPS`. Editing a hook script here takes
  effect immediately; adding a *new* hook means registering it in the Stage-1
  `settings.json`. Two retired hooks must not be registered:
  `foreman-charter.sh` and `remote-session-register.sh` (both deleted;
  `verify-ops.sh` check 17 warns while an entry remains). The PreCompact hook
  also starts `branch-gc --apply` for the repo holding the cwd, detached. No
  hook self-compacts: the retired `bin/compact-cycle.sh` typed `/compact` into
  a tmux pane and could not tell a finished compaction from a failed one, so
  the Operator fires `/compact` (T3 Code's composer, or the terminal).

- **Destructive-tool tests run in a sandbox:** every suite that runs a tool
  that deletes or moves files (branch-gc, pre-compact, memory-init, deploy,
  skills-vendor) refuses to start outside `.claude-config/bin/sandbox-run`,
  which needs `bwrap` (bubblewrap; `apt install bubblewrap`).
  `verify-ops.sh` check 24 fails a suite that names one of those tools
  without the guard; `.claude-config/bin/README.md` ("sandbox-run") has the
  command line.

- **The `ops-verify` timer:** `.claude-config/systemd/` ships a user unit that
  runs `.claude-config/bin/verify-ops.sh` nightly and writes the report to
  `~/.local/state/ops/`, which `session-briefing.sh` surfaces. Enable it
  per user:

  ```bash
  mkdir -p ~/.config/systemd/user
  ln -sf ~/OPS/.claude-config/systemd/ops-verify.{service,timer} ~/.config/systemd/user/
  systemctl --user daemon-reload
  systemctl --user enable --now ops-verify.timer
  ```

  The weekly `ops-memory-gc` timer is retired with the fleet tool it ran. If
  you enabled it, disable it:
  `systemctl --user disable --now ops-memory-gc.timer` and remove its links
  from `~/.config/systemd/user/`. The `memory-prune` skill is the memory audit.

**SessionStart matchers.** Keep the Stage-1 SessionStart hooks split by source,
so a resume or compact does not re-pay the full boot: a `"startup|clear"` group
for the full set and a `"resume|compact"` group for the light continuity hooks
(post-compact-resume, handoff-check, session-briefing, session-work-init).
`session-work-init.sh` belongs in both groups: a revived session fires
`source=resume` for its whole life. `verify-ops.sh` checks the split (check 18)
and the stdout budget of every SessionStart payload (check 19).

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
`settings.json`, `statusline.sh`) and the OS-level shell setup. Provide your
own `settings.json` (that is where hooks register); the core still loads,
because the rule link does not depend on the Stage-1 `CLAUDE.md`. If your own
`~/.zshrc` does not source `~/.zshrc.local`, the ultracode shim stays inert.

## Multi-machine

OPS runs on several machines off **one private repo**. Clone the same repo to
`~/OPS` on each host and run Stage 2 there. Auto-memory is the shared surface:
`memory-init` symlinks each machine's Claude session-memory dirs into
`.claude-memory/<host>-<encoded>/`, and the daily backup commits them and
pushes them to your private origin (the push gate in "What Stage 2 does" step
8 refuses a public one). Doctrine, identity (`CONTEXT/`), project lessons, and
handoff batons ride the same git sync, so every machine boots from the same
durable state.

## Updating an existing deploy

Pull latest, then re-run Stage 2:

```bash
cd ~/OPS && git pull --ff-only
bash ~/OPS/.claude-config/deploy.sh   # or deploy.ps1 on Windows
```

Stage 2 is idempotent: it no-ops where state is already correct.

### Migrating to the core boot (copies older than 2026-10-19)

The 2026-10-19 release replaced the charter-and-digest boot with
`CONTEXT/core.md`, retired the `WORKFORCE/` fleet, and moved the identity
layer to new file names. A copy from before it boots through the old
`claude()` shim, which fails open once the charter is gone, so it keeps
working but without doctrine until you migrate. After you sync the template
(the `harness-update` skill pulls `core.md`, `how-i-work.md`, `AGENTS.md`, and
the code; it never copies your identity files in either direction):

1. **Re-run Stage 2.** `bash ~/OPS/.claude-config/deploy.sh` links the core
   into `~/.claude/rules/`, replaces the boot shim in your `.local` files
   (keeping a Round F `--settings` edit), strips the fleet PATH and wrapper
   lines, mounts the shared skills, and runs the ported `memory-init`.
2. **Create the new identity files from the template**, then move your content
   into them. From the OPS root:
   ```bash
   for f in USER.md standing-orders.md; do
     [ -e "CONTEXT/$f" ] || git show ops-template/main:"CONTEXT/$f" > "CONTEXT/$f"
   done
   git show ops-template/main:CONTEXT/voice.md > /tmp/voice-template.md
   ```
   - `about-me.md` and the identity sections of `boot-digest.md` go into
     `USER.md`; remove its `USER-TEMPLATE: unfilled` canary line when done.
   - `brand-voice.md` becomes `voice.md`: your old `voice.md` was only a
     pointer, so replace it with your brand-voice content, using the template
     in `/tmp/voice-template.md` for the section shape.
   - Every dated ruling under `working-preferences.md` § "Standing Orders",
     the "Always-binding standing orders" of `boot-digest.md`, and any knob you
     changed in `working-preferences.md` (autonomy posture, frameworks, output
     defaults, the Round F permission line) become rows in
     `standing-orders.md`.
3. **Move anything of yours out of the root `CLAUDE.md`** into `AGENTS.md` (repo
   working rules) or `standing-orders.md` (rulings), then delete `CLAUDE.md`. A
   root `CLAUDE.md` makes Claude Code skip `AGENTS.md` here and in every repo
   under `PROJECTS/` (`verify-ops.sh` check 1b fails while it exists).
4. **Delete the retired files** once their content has moved:
   `CONTEXT/about-me.md`, `brand-voice.md`, `working-preferences.md`,
   `boot-digest.md`, and, if a template sync left them, `foreman-charter.md`,
   `worker-digest.md`, `operating-doctrine.md`, `fleet-doctrine.md`, and
   `WORKFORCE/` (check 21b warns while any remain). Git history keeps them.
5. **Retire the fleet's leftovers on the host:** remove an `@reboot
   ... start-remote-claude.sh` line from your crontab, the
   `remote-session-register.sh` and `foreman-charter.sh` entries from your
   Stage-1 settings if you added them, and the `ops-memory-gc` timer (see
   "Hooks and the drift gate").
6. **Run the gate.** `bash ~/OPS/.claude-config/bin/verify-ops.sh` should end
   with `0 fail`, and a new session's `Boot:` line should read
   `core.md loaded via rules/ops-core.md`.

### Upgrading from a copy older than 2026-10-18

Copies from before the 2026-10-18 release pinned retired models, ran a deploy
step that rewrote the model pin inside your Stage-1 settings, and reinstalled
the caveman plugin. After you sync the template (the `harness-update` skill)
and re-run Stage 2:

1. **Restore the Stage-1 settings file if an earlier deploy edited it.** Check
   `git -C ~/linuxploitacious diff -- claude/.claude/settings.json`. If the only
   change is the `"model"` line, restore it with
   `git -C ~/linuxploitacious checkout -- claude/.claude/settings.json`, then
   `git -C ~/linuxploitacious pull --ff-only`. If the diff holds edits of your
   own, keep them and fix only the `"model"` line by hand: `checkout` discards
   every local change to that file.
2. **Run the gate.** `bash ~/OPS/.claude-config/bin/verify-ops.sh` should end
   with `0 fail`. A FAIL from check 15 or 15b names the file and the id to
   change; on the Stage-1 file, pull linuxploitacious rather than editing it.
3. **Optional cleanup.** The old probe's state files are inert:
   `rm -f ~/.local/state/ops/model-probe-*`.
4. **Carry two fixes into your own rulings.** The 2026-10-18 release changed
   two passages of the then-current `working-preferences.md` (ask with the
   structured question tool where one exists; auto-compaction is on as a
   backstop). Both now live in `CONTEXT/core.md`, which the template sync
   updates, so the migration below covers them: do not copy them by hand.
5. **Decide on the permission defaults.** README "Opinionated by design" now
   discloses what Stage 1 sets; `BOOTSTRAP.md` Round F shows how to keep them
   or switch to normal permission prompts without editing the Stage-1 file.

## Known limits

- **The nightly backup pulls the public skill source.** The backup's project
  stage runs `PROJECTS/sync-check.sh --auto`, which fast-forwards every clean
  clone under `PROJECTS/`, including `PROJECTS/Exploitacious/agent-skills`.
  Deploy never pulls that clone (step 2), but once the backup has pulled an
  upstream change to a mounted skill, `verify-ops.sh` reports one fail,
  `skills mirror DRIFT`, until the mirror is synced, and the next `deploy.sh`
  syncs whatever the backup pulled, reviewed or not. Read what changed
  (`git -C ~/OPS/PROJECTS/Exploitacious/agent-skills log -p` over the new
  commits), then run `~/OPS/.claude-config/bin/skills-vendor.sh sync`.

## What stays out of these scripts

Explicitly NOT handled by Stage 2 (`deploy.sh` / `deploy.ps1`):

- **Level 1 Claude files** (`CLAUDE.md`, `settings.json`, `statusline.sh`):
  these come from linuxploitacious (Stage 1). Editing them inside OPS does
  nothing.
- **OS-level shell config** (`.bashrc`, `.zshrc`, prompts, AI CLI installs):
  Stage 1's responsibility.
- **System packages and host security settings**, including T3's browser
  setup (see "T3 Code hosts").
- **The `ops-verify` timer**: shipped here but enabled manually (see "Hooks
  and the drift gate").
- **Project-scoped skills** inside specific
  `PROJECTS/<org>/<repo>/.claude/skills/` directories: those deploy with each
  project's own workflow.

## Adding a new step to Stage 2

If a new piece of OPS setup needs to run on every host:

1. Add it to **both** `deploy.sh` and `deploy.ps1`, with the same semantics.
2. Make it idempotent (check state before acting; no-op if already correct).
3. Keep it inside `$HOME`, or put it behind `--no-system` / `-NoSystem`.
4. Update this doc's "What Stage 2 does" list, and cover it in
   `.claude-config/bin/tests/`.
5. Test on both OSes.

## Reference

- `.claude-config/deploy.sh`: Linux/macOS Stage 2 entry point.
- `.claude-config/deploy.ps1`: Windows Stage 2 entry point.
- `.claude-config/backup/daily-sync.sh`: backup script invoked by the scheduler.
- `.claude-config/bin/origin-private-check`: the push gate for the backup and memory-init.
- `.claude-config/hooks/`: SessionStart, pre-compact, and guard hooks (registered via the Stage-1 `settings.json`).
- `.claude-config/systemd/`: the `ops-verify` timer and the optional `tmux-main` unit.
- `.claude-config/bin/branch-gc`: merged-branch and worktree cleanup (nightly, pre-compaction, closeout).
- `.claude-config/bin/sandbox-run`: the sandbox destructive-tool tests run in.
- `.claude-config/bin/verify-ops.sh`: the drift gate.
- `.claude-config/bin/claude-root-wrapper.sh`: root permission mode and shared-host lock (Linux).
- `.claude-config/bin/memory-init`, `memory-init.ps1`, `memory-index`: auto-memory git-sync and its index.
- `.claude-config/bin/skills-vendor.sh`, `SKILLS/VENDORED.tsv`: the skill mounts.
- `.claude-config/bin/tests/`: the tests for the above.
- `.github/workflows/gate.yml`: the CI gate (syntax checks, every suite, a fresh-install smoke test with `verify-ops.sh`, a secrets scan); it runs on the template repository only.
- `SKILLS/THIRD_PARTY_NOTICES.md`: the third-party works the skills adapt, and their licenses.
- `SKILLS/README.md`: what gets symlinked into `~/.claude/skills/`.
- [`Exploitacious/linuxploitacious`](https://github.com/Exploitacious/linuxploitacious):
  the public Stage 1 repo (dotfiles + host provisioning).
