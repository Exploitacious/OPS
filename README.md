# OPS

**Operator's Shell**: an opinionated, battle-tested Claude Code harness.

OPS is the configuration layer one operator actually runs Claude Code inside,
extracted as a public template. It is not a starter kit or a demo. It is a
working shell with strong opinions about how an AI coding session should
behave, hardened over months of real use, with the operator's identity stripped
out so you can adopt it as your own.

What it gives you, out of the box:

- **One always-loaded core.** `CONTEXT/core.md` is the rule set every session
  and every lane carries, on every launch path: terminal, T3 Code, IDE, and
  `claude -p`. Everything else loads on demand.
- **Foreman-by-default orchestration.** Every session boots as a foreman, not a
  solo engineer. Plan hard up front, then delegate parallelizable work to
  worktree-isolated sub-agents and review their diffs. The posture, the brief
  template, the quality gates, and the estimation math all ship with it.
- **Persistent, file-based memory.** Knowledge lives in tracked files on disk,
  not in a context window that dies on compaction. Auto-memory is git-synced
  across every machine you run OPS on.
- **Session-survival discipline.** Compaction is a pause, not death. Pre-compact
  synthesis, cross-session handoff batons, and post-compact re-orientation hooks
  keep durable state on disk *before* a `/compact` runs, so a fresh context can
  self-recover from files alone.
- **A skills system.** Local Claude Code Skills (and their Claude.ai GUI Project
  twins) for the recurring work that binds to OPS's own hooks and layout: memory
  pruning, pre-compact synthesis, session lifecycle, file transfer, and more. The
  portable technique skills (delegation, skill authoring) aren't vendored here:
  OPS *mounts* them from a shared skill source rather than carrying a copy that
  drifts. The default source is
  [`Exploitacious/agent-skills`](https://github.com/Exploitacious/agent-skills);
  an org or private source mounts alongside it. See `SKILLS/README.md`.

## Opinionated by design

OPS ships the author's working configuration, not a set of neutral defaults you
have to assemble yourself. That means:

- **Fixed model tiers** instead of per-task model shopping: Opus 5.5 is the
  foreman, Sonnet 5.5 every sub-agent's default, Opus 5.5 again for
  high-criticality lanes, Haiku 5.5 for cheap bounded reads, Fable 5.1 rarely.
  Effort is `xhigh` everywhere. `CONTEXT/model-roles.md` is the policy.
- **A full-autonomy posture**: you plan with it up front, then it runs the list
  end to end without re-prompting.

There are no feature flags and no hedging. The philosophy is explained once,
here and in `CONTEXT/`, and after you bootstrap you adjust it to taste; it's
your copy. If a default doesn't fit you, change it; nothing stops you. But the
defaults are chosen on purpose, and they are what makes the harness feel like
one system instead of a pile of settings.

### What the Stage-1 settings turn on

The recommended install (linuxploitacious, Stage 1) links its `settings.json`
into `~/.claude/` for every profile. Read this before your first session,
because these defaults decide what Claude Code may do without asking you:

- **`permissions.defaultMode: "bypassPermissions"`.** Every session starts in
  bypass mode: Claude Code runs every tool call, including shell commands, file
  edits and deletes, and network requests, without a permission prompt. Only
  `deny` rules and hooks still stop a call. OPS's own brakes are two
  PreToolUse hooks: a git guard (commit-hook bypass, force-push, history
  rewrites, remote branch deletes, recursive deletes of a few protected roots,
  a bare `tmux kill-server`, and a push from your OPS copy to an origin it
  cannot prove private) and a secrets guard (literal credentials written into
  memory and lessons files). They are narrow guards, not a sandbox: anything
  else runs.
- **`skipDangerousModePermissionPrompt: true`.** Claude Code normally shows a
  one-time confirmation before a session enters bypass mode; this skips it, so
  nothing warns you at launch.
- **`remoteControlAtStartup: true`.** Every interactive session connects to
  Remote Control at start, so you can watch and drive it from the Claude apps
  signed in to your own claude.ai account. It grants no one else access, but a
  session is reachable from your other devices without you asking for it.
- **Auto-compaction on** (`autoCompactEnabled: true`, `DISABLE_AUTO_COMPACT`
  `"0"`; idle compaction off). It is a backstop near the end of the context
  window; the harness still compacts by hand at natural breaks
  (`CONTEXT/core.md` § "Rhythm and context"). Haiku 5.5 gets a 100K
  compaction window so its lanes stay cheap.

The same file also pins the model tiers above, sets effort to `xhigh`, empties
the commit and PR attribution lines, and turns on push notifications for agent
events. `BOOTSTRAP.md` asks you, as an explicit step, whether to keep the
permission defaults or switch to normal permission prompts, and shows the exact
change. Do not edit the Stage-1 file to change them: it is a tracked file in
your linuxploitacious checkout, so a local edit (including a `/config` or
`/model` save, which writes it) dirties that checkout, and its next
`git pull --ff-only` fails whenever upstream changed the same file.

## Spin-up

**OPS is a template repo, not something you clone-and-run in place.** Your copy
becomes your memory and your identity: it will hold your context files, your
project map, your auto-memory. Set it up correctly the first time.

### Before you start

You need `bash` (the deployer, hooks, and tests are bash; Windows runs them in
Git Bash), and these on the machine:

- **`git`, with an identity set.** Run `git config --global user.name "Your
  Name"` and `git config --global user.email you@example.com`. A fresh account
  often has none, and then every commit fails: the memory sync's, the daily
  backup's, and every agent's. Deploy asks `git var` for the author and
  committer identity and, when either is missing, prints those two commands and
  finishes with a failure named `git-identity` (`DEPLOYMENT.md`, step 7). Use
  git 2.45 or newer: branch cleanup reads `git rev-parse --show-ref-format` and,
  on an older git (Ubuntu 24.04 ships 2.43), skips every repository and logs the
  skip; the rest of OPS works either way.
- **`gh`, signed in (`gh auth login`).** The private-origin check and branch
  cleanup ask GitHub through it. Without a signed-in `gh`, the automatic pushes
  stay local and branch cleanup removes nothing.
- **`python3` and `jq`.** Deploy seeds the trust anchor with Python, and the
  hooks and the drift gate read JSON with `jq`.
- **Claude Code.** Deploy only looks for the CLI to retire two old plugins; if
  it is missing, deploy warns and goes on.
- **Optional: `bubblewrap` (`bwrap`).** Only the destructive-tool test suites
  need it (`CONTRIBUTING.md`).

### 1. Create your OWN PRIVATE repo from this template

Use GitHub's **"Use this template"** button, or the CLI:

```bash
gh repo create <you>/<your-name> --template Exploitacious/OPS --private --clone
```

**Never fork this repo**: forks of a public repo cannot be made private, and
**never run your copy public.** Your OPS repo accumulates who you are and what
you're working on. It has to be private. The automatic pushes (the daily
backup and memory-init) check this first: they commit locally but push only
when `gh` confirms origin is a private GitHub repo, and they refuse the public
template itself, so a tryout clone never publishes your notes
(`DEPLOYMENT.md`, "What Stage 2 does" step 8, "The push gate").

### 2. Deploy it on your machine

Two paths, pick one:

- **Via linuxploitacious (recommended).** The host-provisioning installer at
  [`Exploitacious/linuxploitacious`](https://github.com/Exploitacious/linuxploitacious)
  has an `AI Harness` option in `shellSetup.sh` that clones your private copy
  (it needs `gh` auth so it can see a private repo), then wires everything. If
  you don't have a copy yet, it offers to create one from this template.
- **Manually.** Clone your private repo to `~/OPS`, then run the Stage 2
  deployer:

  ```bash
  git clone git@github.com:<you>/<your-name>.git ~/OPS
  bash ~/OPS/.claude-config/deploy.sh          # Linux / macOS
  # Windows PowerShell:  & "$HOME\OPS\.claude-config\deploy.ps1"
  ```

Both paths are idempotent. Full procedure, both stages, both OSes: see
[`DEPLOYMENT.md`](DEPLOYMENT.md).

**On a T3 Code host.** T3 Code runs Claude Code as a provider thread, with no
shell function in the launch, and OPS's boot does not need one: deploy links
the core into `~/.claude/rules/`, which Claude Code loads for a T3 thread as it
does in a terminal (`DEPLOYMENT.md`, "How the core loads"). Two steps are
specific to T3:

1. In T3 Code, add `~/OPS` as a project and open a thread on it. The first
   thread finds no bootstrap marker and runs `BOOTSTRAP.md` (step 3).
2. Run T3's browser setup once per host. T3's page previews and browser tools
   run a headless Chrome that needs system libraries and, on Ubuntu 23.10 and
   later, an AppArmor profile:

   ```bash
   t3="$(ls -1d ~/.t3/runtime/versions/*/t3 | sort -V | tail -1)"
   sudo "$t3" browser setup
   ```

   Deploy prints a pointer to this command when it finds a T3 runtime and
   never runs it, because it needs sudo. BOOTSTRAP Round G offers to run it with
   your yes. Run it again after a T3 upgrade if the browser tools stop working.

T3 sets each thread's permission mode from its own settings, so the terminal
option in BOOTSTRAP Round F does not reach T3 threads; the managed-settings
option does (`DEPLOYMENT.md`, "T3 Code hosts").

### 3. Open Claude Code in the repo and let it bootstrap

On the first launch in a fresh copy, the gate in `AGENTS.md` (also named in
`CONTEXT/core.md`) finds no `CONTEXT/.bootstrapped` marker, so instead of a
normal session it runs `BOOTSTRAP.md`: an interview about who you are and how
you work, plus machine reconnaissance. Together they write your identity
(`CONTEXT/USER.md`), a starter voice profile (`CONTEXT/voice.md`), your rulings
(`CONTEXT/standing-orders.md`), and the work-tracking, team, and tools slots,
then drop the marker. The doctrine already ships; bootstrap fills in the *who*,
never the *how*. On a fresh copy, the bootstrap *is* the session, in a
terminal or in a T3 Code thread alike: the gate lives in `AGENTS.md`, which a
session in this repo reads, so you do not have to ask for it.

## What deploy does

`deploy.sh` (Linux and macOS) and `deploy.ps1` (Windows) are Stage 2. Both are
idempotent and safe to re-run after any pull. On Linux, in order:

1. Link `~/.claude/{skills,commands,agents,workflows}` to the matching OPS
   directories, backing up any real directory already there.
2. Mount the shared skills (see "Skill mounts").
3. Link the always-loaded core into `~/.claude/rules/ops-core.md`.
4. Strip the retired fleet's PATH and wrapper lines from your shell rc files
   (whole-line matches only; anything you wrote stays).
5. Wire `claude-root-wrapper.sh` into root's shell rc files when passwordless
   sudo exists. It adds `--permission-mode auto` when `claude` runs as root
   (Claude Code refuses bypass mode as root) and holds a lock so two users
   sharing one config directory never run at once.
6. Write the ultracode `claude()` shim to the untracked `~/.zshrc.local` and
   `~/.bashrc.local`.
7. Check the git identity, then link each Claude auto-memory directory into
   `.claude-memory/` (`memory-init --auto-commit`).
8. Install the daily backup cron entry.
9. Retire the caveman and ponytail plugins through the `claude plugin` CLI.
10. Mark `$HOME` trusted in `~/.claude.json`, so the repos under it raise no
    folder-trust prompt.

Deploy never writes `~/.claude/settings.json`, because Stage 1 owns it. A step
it cannot finish prints a `[XX]` line, the others still run, and the script
exits non-zero. `--no-system` (`-NoSystem` on Windows) skips every write outside
your home directory (root's rc files, the crontab entry, the scheduled task),
for a test install under a throwaway `HOME`. Windows runs a shorter pipeline;
`DEPLOYMENT.md` lists both.

## The push gate and its limits

Your copy holds your memory, context, and notes, so two rules keep it off a
public repo.

- **The unattended pushes** (`memory-init --auto-commit` during deploy, and the
  daily backup) run `.claude-config/bin/origin-private-check` first. It exits 0
  only when GitHub, asked through `gh api`, reports every push URL of `origin`
  private. A public origin (the `Exploitacious/OPS` template itself, a public
  fork, a copy made public by mistake) or one it cannot verify (`gh` missing or
  signed out, offline, a host other than github.com) keeps the commit local;
  the output or the backup log names the reason and the fix, and the next run
  that passes pushes every held commit. On your own git server, which `gh`
  cannot ask, confirm the repo is private and run `git -C ~/OPS config
  ops.pushVerified true`. That opt-in covers only what cannot be verified and
  never overrides a public answer.
- **Agent pushes** meet the same gate. The `git-guard.sh` hook runs it before
  an agent's `git push` from an OPS copy and blocks a push it cannot verify,
  one to a remote other than `origin`, and one carrying a `-c` setting that
  could move it.

The limits: the hook is a seatbelt for the pushes an agent makes while
following normal instructions, not a sandbox. Exotic wrappers (`setsid`,
`find -exec`, `ssh`, `python -c`), a push inside a script file, and commands
built at run time are not parsed; the header of
`.claude-config/hooks/git-guard.sh` lists them. The real protection is a
private origin. `GIT_GUARD=off <command>` lifts the hook for one approved
command; a contributor uses it to push a PR branch (`CONTRIBUTING.md`).

## The daily backup

Deploy installs a user cron entry that runs `.claude-config/backup/daily-sync.sh`
at 09:00 (on Windows, the `OPS Daily Backup` task runs the same script in Git
Bash). Each run:

1. commits the day's changes where they stand, so the tree is never stashed or
   moved;
2. pulls with `--rebase`, and aborts a failed pull so the local commit and the
   files stay exactly as they were;
3. pushes through the private-origin gate above;
4. pulls every project repo under `PROJECTS/` (`sync-check.sh --auto`, which
   skips repos with uncommitted work);
5. runs `branch-gc --apply`, which removes local branches that a merged pull
   request provably carried and parks their worktrees in a 7-day trash.

The script always exits 0, so a failure cannot be seen from the exit code.
It logs to `.claude-config/backup/sync.log` instead, and the session briefing's
`Backup:` line repeats the last run's errors and skipped pushes at the next
boot.

## Skill mounts

Portable technique skills are mounted, not copied. `SKILLS/VENDORED.tsv` lists
nine from [`Exploitacious/agent-skills`](https://github.com/Exploitacious/agent-skills):
`delegation-sizing`, `briefing-subagents`, `worktree-isolation`,
`verifying-delegated-output`, `dynamic-workflows`, `meta-skill-creator`,
`grill-me`, `tdd`, and `diagnosing-bugs`. Deploy clones that repo once under
`PROJECTS/Exploitacious/agent-skills` (it never pulls an existing clone, so a
re-deploy cannot slip in an unreviewed upstream change), then runs
`.claude-config/bin/skills-vendor.sh sync` to mirror each skill into
`SKILLS/<name>/`. Edit a mounted skill at its source repo, never in `SKILLS/`.
`skills-vendor.sh --check` prints `OK`, `DRIFT` (the source changed and the
mirror did not), or `MISSING` (the source is not cloned). The sync never
deletes a folder it did not write: your own skill under a mounted name, or a
hand-edited mirror, moves to `.claude-config/backup/skills-replaced/` first.
Add a row to `VENDORED.tsv` for an org or private source of your own
(`SKILLS/README.md`). Some mounted and local skills adapt third-party work;
[`SKILLS/THIRD_PARTY_NOTICES.md`](SKILLS/THIRD_PARTY_NOTICES.md) lists each
source and its license.

## Template sync

A copy made from the template shares no git history with it, so `git merge` has
no common ancestor. The `harness-update` skill ("update the harness") is the
safe path across that gap, and `.claude-config/bin/harness-update-scan.sh` is
its mechanical half. Run from inside your copy (`cd ~/OPS`), the scan adds an
`ops-template` remote, fetches it, and classifies every file as NEW, UPDATE,
CONFLICT, MODE, REMOVED, or IDENTICAL. By default it reports and touches
nothing. `--apply-safe` copies NEW and UPDATE files only, never a CONFLICT, a
MODE change, a deletion, or a commit. Your identity files (`USER.md`,
`voice.md`, `standing-orders.md`, the `work-tracking`, `team`, and `tools`
slots, `.bootstrapped`, `CONTEXT/projects/`), memory, and handoff surfaces are
excluded in both directions, so a refresh never overwrites who you are. The
marker `.claude-config/ops-upstream-ref` records the last upstream commit
pulled, so the next scan shows only what changed since. The template's CI
workflow (`.github/workflows/gate.yml`) arrives like any other file; it runs
only on the template repository, so delete it from your copy if you like.
Copies older than the 2026-10-19 release also migrate by hand once
(`DEPLOYMENT.md`, "Migrating to the core boot").

## Checking your copy

- **The drift gate:** `bash ~/OPS/.claude-config/bin/verify-ops.sh`
  machine-checks the conventions that used to live only in prose: the core's
  size and link, the model pins, the retired files, the skill mounts, the
  sandbox guards, and more. Exit 0 means no FAIL (a WARN is advice). `--quiet`
  prints only WARN and FAIL lines, and `OPS_DIR=<path>` checks another
  checkout. Its host checks read `$HOME` (the core link, the Stage-1
  settings), so on a machine with no deployed OPS it fails until you deploy. An
  optional user timer runs it nightly, and the session briefing shows the
  result (`DEPLOYMENT.md`, "Hooks and the drift gate").
- **The tests:** every script has a suite under `.claude-config/bin/tests/`, a
  `*-selftest` beside its subject, or a hook self-test. A suite that runs a
  tool that deletes or moves files runs only inside `sandbox-run`.
  `CONTRIBUTING.md` has the commands for all of them.
- **CI:** `.github/workflows/gate.yml` runs the syntax checks, the suites, a
  fresh-install smoke test followed by `verify-ops.sh`, and a secrets scan on
  every push and pull request to the template repository, with no secrets, so
  a fork's pull request gets the same run.

## What's inside

```
OPS/
├── AGENTS.md              # how sessions work in this repo (the first-launch gate, build/test/land)
├── README.md              # this file: what OPS is + spin-up
├── DEPLOYMENT.md          # the two-stage deploy (linuxploitacious -> deploy.sh), migration, T3 hosts
├── BOOTSTRAP.md           # first-launch interview + machine recon (writes your identity files)
├── LICENSE                # MIT
├── CONTRIBUTING.md        # the porting discipline and the gates: how private-harness improvements land here
├── .github/workflows/     # gate.yml: the CI gate (runs on the template repository only)
├── CONTEXT/               # core.md always loaded; everything else on demand
│   ├── core.md                 #   the always-loaded rules (linked into ~/.claude/rules/ops-core.md)
│   ├── how-i-work.md           #   principles P1-P15 + situational rules (the why behind core.md)
│   ├── model-roles.md          #   the model-tier policy, one source
│   ├── project-kata.md         #   repo shape + documentation discipline
│   ├── slots.md                #   context-slot registry (voice, team, tools, work-tracking, doctrine)
│   ├── USER.md / voice.md / standing-orders.md   #   your identity, voice, rulings: templates BOOTSTRAP fills, never synced
│   ├── work-tracking.md / team.md / tools.md / doctrine.md   #   the context slots
│   └── projects/               #   per-project lessons, loaded only when on that project
├── SKILLS/                # Claude Code Skills + GUI Project twins (symlinked -> ~/.claude/skills/); THIRD_PARTY_NOTICES.md
├── .claude-config/        # Stage 2 deploy + the machinery it does not itself install
│   ├── deploy.sh / deploy.ps1  #   Stage 2 deployer (links, core rule, skill mounts, memory sync, ...)
│   ├── hooks/                  #   SessionStart briefing, pre-compact snapshot + branch-gc, context-watch, secrets/git guards
│   ├── systemd/                #   ops-verify timer (nightly drift gate) + optional tmux-main
│   ├── remote-sessions/        #   hand-run tmux sessions you remote-control (see its README)
│   ├── agents/ + workflows/    #   sub-agent definitions + multi-lane workflow scripts
│   └── bin/                    #   memory-index/-init, branch-gc, sandbox-run, verify-ops, skills-vendor, tests/ (and more)
├── .claude-memory/        # per-machine Claude auto-memory dirs (git-synced via bin/memory-init)
├── .claude-handoffs/      # cross-session / cross-machine handoff batons
├── PROJECTS/              # your working repos (2nd-level subdirs are their own repos, gitignored)
├── DELIVERABLES/          # cross-cutting one-off outputs not tied to a single project
├── ARCHIVE/               # machine-local archives kept out of git
└── NOTES/                 # an Obsidian vault for personal knowledge
```

The memory pattern is the load-bearing idea: durable state (doctrine, identity,
project lessons, auto-memory, handoff batons) lives in tracked files, so a fresh
context (after a compaction, a new machine, or a profile switch) recovers by
reading the repo, not by remembering.

## Boot surface

What every session carries, and why. `CONTEXT/core.md` is one file under
15,360 bytes with the rules every session and lane needs on every turn.
`deploy.sh` links it into `~/.claude/rules/ops-core.md`, and Claude Code loads
every user rule file at launch on every launch path, with no prompt: the
terminal, T3 Code threads, IDE extensions, `claude -p`, and the lanes they
spawn. The session briefing's `Boot:` line says whether the link is in place.

This replaces an earlier boot that appended a foreman charter and an identity
digest to the system prompt through a `claude()` shell function. Only launches
typed into an interactive shell ever ran that function, so T3 Code and IDE
sessions booted without doctrine. The `claude()` function remains, but only to
add ultracode to terminal launches.

For a forker, this means:

- **Your identity is not in the boot.** `USER.md`, `voice.md`, and
  `standing-orders.md` load on demand, through the core's "Where to look" table
  and the context skills (`operator-voice`, `harness-readme`, `harness-deploy`,
  `project-kata`, `projects-map`, `machines`). BOOTSTRAP fills them, and
  `harness-update` never syncs them, so a template refresh never clobbers them.
- **Keep the core small and generic.** It is paid on every turn of every
  session and lane, and the template sync updates it. Put your rulings in
  `standing-orders.md`, never in `core.md`.
- **Rest-stop cadence.** Compaction is a rest stop, not a scarcity response:
  compact by hand at natural breaks (core.md § "Rhythm and context");
  auto-compaction is the backstop.
- **Mount portable skills.** `deploy.sh` clones the public skill source and
  runs `.claude-config/bin/skills-vendor.sh sync`; see `SKILLS/README.md`.
- **The drift gate checks it.** `verify-ops.sh` fails if the core is missing,
  over budget, or not linked (check 16), if a root `CLAUDE.md` would hide
  `AGENTS.md` (1b), if `USER.md` is still the template on a bootstrapped copy
  (21), or if `harness-update` stops excluding an identity file (23).

## Posture

This is a working shell, published as-is. It's occasionally updated when the
author's own setup changes. There is **no support promise and no SLA.** Issues
are open; treat them as a place to compare notes, not a help desk. It ships MIT,
so reuse the mechanics in your own harness freely; just don't run *this
template's* lineage as a public repo of your own life.

## A note on the name

OPS ("Operator's Shell") is unrelated to Anthropic's "Claude Cowork" desktop
app. Same broad space, different thing: this is a self-hosted configuration
layer for the Claude Code CLI, not a desktop product.

## License

MIT; see [`LICENSE`](LICENSE). Skills adapted from third-party work keep their
upstream licenses; see
[`SKILLS/THIRD_PARTY_NOTICES.md`](SKILLS/THIRD_PARTY_NOTICES.md).
