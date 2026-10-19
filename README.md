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
- **A skills system.** Local Claude Code Skills (and their Claude.ai GUI Project
  twins) for the recurring work that binds to OPS's own hooks and layout — memory
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
  (`working-preferences.md` Standing Orders). Haiku 5.5 gets a 100K
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
├── CONTEXT/               # doctrine + your identity (the boot digest rides the system prompt; the rest load on demand)
│   ├── operating-doctrine.md   #   the universal principles (P1-P15) any session follows
│   ├── foreman-charter.md      #   always-on foreman posture (rides the cached system prompt via the launch shim)
│   ├── boot-digest.md          #   identity slot template — rides the system prompt with the charter; BOOTSTRAP fills it
│   ├── model-roles.md          #   the model-tier policy (foreman / lanes / retired / banned), one source
│   ├── slots.md                #   context-slot registry (voice, team, tools, work-tracking, doctrine)
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
│   ├── deploy.sh / deploy.ps1  #   Stage 2 deployer (symlinks, PATH, memory-sync, plugin retirement, ...)
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

## Boot surface

What rides your system prompt, and why. A SessionStart hook can only print a
short preview to the model (hook stdout above ~8KB is truncated to a ~2KB
preview), so the old "inject the charter through a hook" approach silently lost
most of a long charter. OPS instead rides the boot surface through the cached
system prompt: the `claude()` launch shim (written by `deploy.sh` into the
untracked `~/.<shell>rc.local` seam) appends the whole `CONTEXT/foreman-charter.md`
plus `CONTEXT/boot-digest.md` via `--append-system-prompt`, pinned with
`--system-prompt-snapshot on` so it lands whole every launch and survives resume
and compact verbatim. The session briefing prints a `Boot:` line with the
content sha, so you can see the exact version that booted. `foreman-charter.sh`
is retired for Claude Code because of this (it stays only as an adapter seam for
a non-Claude-Code agent).

For a forker, this means:

- **Author your digest.** `CONTEXT/boot-digest.md` ships as a slot template
  (the "Example Corp" flavor, like `about-me.md`). Replace every EXAMPLE line
  with your own facts and remove the `BOOT-DIGEST-TEMPLATE: unfilled` canary
  line at the top; BOOTSTRAP does this on first launch. It is hard-excluded from
  `harness-update`, so a template refresh never clobbers your filled copy.
- **Context loads on demand.** With the digest grounding every session, the full
  `about-me.md` / `working-preferences.md` / `operating-doctrine.md` load only
  when a task needs them, routed by the thin context skills (`operator-voice`,
  `harness-readme`, `harness-deploy`, `project-kata`, `projects-map`, `machines`,
  `fleet-doctrine`).
- **Rest-stop cadence.** Compaction is a rest stop, not a scarcity response.
  `context-watch.sh`'s readout is calm and boundary-aware (a closed task, a
  landed push/merge, a branch switch, a >2h gap), and the compact cadence is a
  shipped standing order (`working-preferences.md` § Standing Orders).
- **Mount portable skills.** `.claude-config/bin/skills-vendor.sh` +
  `SKILLS/VENDORED.tsv` mirror the shared skill source into `SKILLS/`; see
  `SKILLS/README.md`.
- **The drift gate checks it.** `verify-ops.sh` fails if the shim loses a boot
  flag, if the digest is missing or still the unfilled template on a bootstrapped
  copy, if `context-watch` grows scarcity vocabulary, or if the digest is not
  excluded from `harness-update`.

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
