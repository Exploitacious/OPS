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
  PreToolUse hooks: a git guard (hook bypass, force-push, history rewrites,
  remote branch deletes, and recursive deletes of a few protected roots) and a
  secrets guard (literal credentials written into memory and lessons files).
  They are narrow guards, not a sandbox: anything else runs.
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
(`DEPLOYMENT.md`, "The push gate").

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

### 3. Open Claude Code in the repo and let it bootstrap

On the first launch in a fresh copy, the gate in `AGENTS.md` (also named in
`CONTEXT/core.md`) finds no `CONTEXT/.bootstrapped` marker, so instead of a
normal session it runs `BOOTSTRAP.md`: an interview about who you are and how
you work, plus machine reconnaissance. Together they write your identity
(`CONTEXT/USER.md`), a starter voice profile (`CONTEXT/voice.md`), your rulings
(`CONTEXT/standing-orders.md`), and the work-tracking, team, and tools slots,
then drop the marker. The doctrine already ships; bootstrap fills in the *who*,
never the *how*. On a fresh copy, the bootstrap *is* the session. Under T3 Code,
open a thread on the `~/OPS` project and say "run the bootstrap"; T3 Code hosts
also get a one-time browser setup step (`DEPLOYMENT.md` § "T3 Code hosts").

## What's inside

```
OPS/
├── AGENTS.md              # how sessions work in this repo (the first-launch gate, build/test/land)
├── README.md              # this file: what OPS is + spin-up
├── DEPLOYMENT.md          # the two-stage deploy (linuxploitacious -> deploy.sh), migration, T3 hosts
├── BOOTSTRAP.md           # first-launch interview + machine recon (writes your identity files)
├── LICENSE                # MIT
├── CONTRIBUTING.md        # the porting discipline: how private-harness improvements land here
├── CONTEXT/               # core.md always loaded; everything else on demand
│   ├── core.md                 #   the always-loaded rules (linked into ~/.claude/rules/ops-core.md)
│   ├── how-i-work.md           #   principles P1-P15 + situational rules (the why behind core.md)
│   ├── model-roles.md          #   the model-tier policy, one source
│   ├── project-kata.md         #   repo shape + documentation discipline
│   ├── slots.md                #   context-slot registry (voice, team, tools, work-tracking, doctrine)
│   ├── USER.md / voice.md / standing-orders.md   #   your identity, voice, rulings: templates BOOTSTRAP fills, never synced
│   ├── work-tracking.md / team.md / tools.md / doctrine.md   #   the context slots
│   └── projects/               #   per-project lessons, loaded only when on that project
├── SKILLS/                # Claude Code Skills + GUI Project twins (symlinked -> ~/.claude/skills/)
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

MIT; see [`LICENSE`](LICENSE).
