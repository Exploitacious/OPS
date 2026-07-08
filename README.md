# OPS

**Operator's Shell** — an opinionated, battle-tested Claude Code harness.

OPS is the configuration layer one operator actually runs Claude Code inside,
extracted as a public template. It is not a starter kit or a demo. It is a
working shell with strong opinions about how an AI coding session should
behave, hardened over months of real use, with the operator's identity stripped
out so you can adopt it as your own.

What it gives you, out of the box:

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
- **A fleet coordination layer.** A full multi-agent system (`WORKFORCE/`):
  Coordinator + Agent personalities, a messaging/lifecycle protocol, and an
  `ac-*` toolbelt for spawning, tasking, and reorienting agents.
- **A skills system.** Portable Claude Code Skills (and their Claude.ai GUI
  Project twins) for the recurring work — delegation, memory pruning, skill
  authoring, file transfer, and more.

## Opinionated by design

OPS ships the author's working configuration, not a set of neutral defaults you
have to assemble yourself. That means:

- **1M-context worker tiers** with a fixed three-way policy (mechanical /
  default / hard-lane) instead of per-task model shopping.
- **Autocompact OFF** — compaction is always a deliberate `/compact`, never a
  surprise mid-task.
- **A full-autonomy posture** — you plan with it up front, then it runs the list
  end to end without re-prompting.

There are no feature flags and no hedging. The philosophy is explained once,
here and in `CONTEXT/`, and after you bootstrap you adjust it to taste — it's
your copy. If a default doesn't fit you, change it; nothing stops you. But the
defaults are chosen on purpose, and they are what makes the harness feel like
one system instead of a pile of settings.

## Spin-up

**OPS is a template repo, not something you clone-and-run in place.** Your copy
becomes your memory and your identity — it will hold your context files, your
project map, your auto-memory. Set it up correctly the first time.

### 1. Create your OWN PRIVATE repo from this template

Use GitHub's **"Use this template"** button, or the CLI:

```bash
gh repo create <you>/<your-name> --template Exploitacious/OPS --private --clone
```

**Never fork this repo** — forks of a public repo cannot be made private, and
**never run your copy public.** Your OPS repo accumulates who you are and what
you're working on. It has to be private.

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

On the first launch in a fresh copy, `CLAUDE.md`'s startup gate finds no
`CONTEXT/.bootstrapped` marker, so instead of the normal session it reads
`BOOTSTRAP.md` and runs the first-launch bootstrap: an interview about who you
are and how you work, plus machine reconnaissance, which together create your
`CONTEXT/` identity files (`about-me.md`, `brand-voice.md`), tune the generic
`working-preferences.md` to your knobs, and drop the marker. The doctrine files
already ship — bootstrap fills in the *who*, not the *how*. On a fresh copy, the
bootstrap *is* the session. After that, OPS knows you, and every session behaves
like the original — it just started out not knowing anything about you.

## What's inside

```
OPS/
├── CLAUDE.md              # how AI sessions work here (startup, activation, standing rules)
├── README.md              # this file — what OPS is + spin-up
├── DEPLOYMENT.md          # the two-stage deploy (linuxploitacious -> deploy.sh)
├── BOOTSTRAP.md           # first-launch interview + machine recon (populates CONTEXT/)
├── LICENSE                # MIT
├── CONTRIBUTING.md        # the porting discipline — how private-harness improvements land here
├── CONTEXT/               # always-loaded doctrine + your identity (read every session)
│   ├── operating-doctrine.md   #   the universal principles (P1-P15) any session follows
│   ├── foreman-charter.md      #   always-on foreman posture (auto-injected at SessionStart)
│   ├── fleet-doctrine.md       #   multi-agent coordination rules (loaded on ACTIVATE)
│   ├── worker-digest.md        #   ~2KB doctrine distillation for spawned sub-agents
│   ├── project-kata.md         #   repo shape + documentation discipline
│   ├── working-preferences.md  #   how you like work run day-to-day (ships generic, tuned by BOOTSTRAP)
│   ├── about-me.md / brand-voice.md   #   the who layer — ship as templates; BOOTSTRAP fills them in
│   └── projects/               #   per-project lessons, loaded only when on that project
├── SKILLS/                # Claude Code Skills + GUI Project twins (symlinked -> ~/.claude/skills/)
├── WORKFORCE/             # the fleet: personalities, protocol, and the ac-* toolbelt
│   ├── personalities/          #   Coordinator + Agent role definitions
│   ├── protocol/               #   messaging, lifecycle, escalation, closeout, lessons/
│   └── bin/                    #   ac-* helpers (spawn, task, msg, reorient, memory-sync, ...)
├── .claude-config/        # Stage 2 deploy + the machinery it does not itself install
│   ├── deploy.sh / deploy.ps1  #   Stage 2 deployer (symlinks, PATH, memory-sync, plugins, ...)
│   ├── hooks/                  #   SessionStart briefing, pre-compact snapshot, secrets/git guards
│   ├── systemd/                #   ops-verify + ops-memory-gc timers (nightly drift gate, weekly GC)
│   ├── agents/ + workflows/    #   sub-agent definitions + multi-lane workflow scripts
│   └── bin/                    #   operator utilities (grabit file transfer, secrets scan, verify)
├── .claude-memory/        # per-machine Claude auto-memory dirs (git-synced via ac-memory-init)
├── .claude-handoffs/      # cross-session / cross-machine handoff batons
├── PROJECTS/              # your working repos (2nd-level subdirs are their own repos, gitignored)
├── DELIVERABLES/          # cross-cutting one-off outputs not tied to a single project
├── ARCHIVE/               # closed-project tarballs (ac-close-project --archive)
└── NOTES/                 # an Obsidian vault for personal knowledge
```

The memory pattern is the load-bearing idea: durable state (doctrine, identity,
project lessons, auto-memory, handoff batons) lives in tracked files, so a fresh
context — after a compaction, a new machine, or a profile switch — recovers by
reading the repo, not by remembering.

## Posture

This is a working shell, published as-is. It's occasionally updated when the
author's own setup changes. There is **no support promise and no SLA.** Issues
are open; treat them as a place to compare notes, not a help desk. It ships MIT,
so reuse the mechanics in your own harness freely — just don't run *this
template's* lineage as a public repo of your own life.

## A note on the name

OPS ("Operator's Shell") is unrelated to Anthropic's "Claude Cowork" desktop
app. Same broad space, different thing — this is a self-hosted configuration
layer for the Claude Code CLI, not a desktop product.

## License

MIT — see [`LICENSE`](LICENSE).
