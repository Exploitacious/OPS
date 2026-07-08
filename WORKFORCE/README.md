# WORKFORCE — Multi-Agent Coordination

This is the coordination layer for running multiple Claude Code sessions
in parallel on the same workspace. Operator (you) drives. Agents do
the work. An optional Coordinator routes between you and the agents.

**Linux-only.** Fleet mechanics rely on GNU coreutils + bash 4+ +
`flock`. Windows hosts run OPS for shell/context experience only
and do NOT participate in the fleet. macOS is not a supported target.

**Layout (2026-05-12+):**

```
WORKFORCE/
├── personalities/         ← shared doctrine (AGENT.md, COORDINATOR.md, ...)
├── protocol/              ← shared protocol (messaging, lifecycle, ...)
├── bin/                   ← ac-* helper scripts
├── README.md              ← this file
└── FLEETPROJECTS/<name>/  ← per-project runtime (gitignored, machine-local)
    └── runtime/{manifest.d,tasks,decisions,archive,inbox,journal,...}
```

**Tracked in git:** everything except the per-project subdirs under
`FLEETPROJECTS/`. The fleet system (personalities, protocol, bin,
README) is identical across machines. Per-project state is local
per machine.

**Historic / retired workforces** that may exist as gitignored
directories under `FLEETPROJECTS/` on this machine — none of them
should be confused with active fleet doctrine; their lessons (if
any) live in `CONTEXT/projects/<project>-lessons.md`. Example shape,
once you've run a few projects through the fleet:

- `invoice-sync-pipeline/` — a past integration pipeline (Captain +
  Bravo + Charlie). Lessons in
  `CONTEXT/projects/invoice-sync-pipeline-lessons.md`.
- `vendor-api-mcp/` — a short-lived MCP coordination effort for one
  vendor integration. No lessons file authored (decisions folded
  into the MCP repo itself).
- `fleet-doctrine-experiments/` — cross-cutting fleet-doctrine
  experiments, e.g. a memory-sync doctrine that became a Stage 2
  bootstrap step. Closed; doctrine ideas absorbed upstream.

A fresh agent activating into a workforce should ONLY operate
inside the `FLEETPROJECTS/<project>/` directory the Coordinator
assigns. Other gitignored runtime dirs on the machine are not
your concern.

**Project binding rule (HARD):** Bin scripts require `AC_ROOT` to be
set explicitly — no default project. The Coordinator assigns the
project path when spawning or briefing each agent. Agents confirm
the assignment before running any runtime ops. This prevents
cross-project state collisions when multiple projects are in
flight simultaneously.

```bash
# Coordinator briefs agent in spawn message:
export AC_FLEET=$HOME/OPS/WORKFORCE
export AC_ROOT=$HOME/OPS/WORKFORCE/FLEETPROJECTS/<project>

# Then runtime ops work:
$AC_FLEET/bin/ac-register --role agent --scope <tag>
$AC_FLEET/bin/ac-pulse --status working
```

If you're reading this because you forgot how this works, the next
section is your refresher. Everything else in this directory is for
the agents to absorb at activation time.

---

## Operator's reference (start here)

### What this gives you

- Run 2+ Claude Code sessions at the same time on different repos
  (or different parts of the same repo) and have them coordinate
  changes, hand off work, and surface blockers without you nudging
  every step.
- A consistent "who am I, what's the protocol" bootstrap for every
  agent so you don't end up with sessions calling each other "companion"
  and getting confused.
- A single conversation channel (the Coordinator, when you spawn one)
  that rolls up status across all agents so you don't have to context-
  switch between 3 terminals to know where things stand.
- A machine-local audit trail (decisions, archived messages, task
  specs) for whichever machine is actively running the fleet — see
  "What's tracked in git, what isn't" below for the boundary.
  Cross-machine continuity for the Operator's broader work rides
  OPS's actually-tracked docs (`CONTEXT/`) and auto-memory, not
  the fleet runtime itself.

### How a session starts

Open a Claude Code session as normal. Type **`ACTIVATE AGENT`** or
**`ACTIVATE COORDINATOR`** anywhere in your first message. The agent
will:

1. Read its personality file (`personalities/AGENT.md` or
   `personalities/COORDINATOR.md`).
2. Read the current `manifest.d/` to see who else is active.
3. Claim a unique name from `personalities/name-pool.md`.
4. Register itself in `manifest.d/<name>.json`.
5. Greet you (and the Coordinator if one exists) with a one-line
   status: who it is, what scope, what's pending.

If you don't type either trigger, the session runs as a normal
Claude Code session using OPS's standard `CLAUDE.md` instructions.
Activation is opt-in.

### When to use a Coordinator

| Agent count | Recommendation |
|---|---|
| 1 active session | No coordinator. Just talk to the agent. |
| 2 active sessions | Optional. Skip if the two are working independent scopes. Spawn one if their work overlaps (shared schema, shared infra). |
| 3+ active sessions | Spawn one. You should not be the router. |

To spawn one, open a fresh Claude Code session and type
`ACTIVATE COORDINATOR` in your first message. One Coordinator at a
time — if a second tries to claim the role, it gets demoted to a
regular agent and is told who the active Coordinator is.

### How you talk to the system

**Solo agent:** Talk to the agent directly. Same as any Claude Code
session.

**Multi-agent without Coordinator:** Talk to whichever agent is
working on the thing in front of you. They'll cross-message each
other via `runtime/inbox/` for handoffs.

**Multi-agent with Coordinator:** Talk to the Coordinator. Give it
the goal. It writes the task spec, assigns agents, tracks progress,
rolls up status back to you. You don't need to know which agent has
which subtask — ask the Coordinator.

### Your role (the Operator)

- **Final reviewer + decision-maker.** Agents do not merge to main,
  deploy to prod, force-push, or run destructive DB ops without your
  approval. The personality files enforce this.
- **Direction setter.** You and the Coordinator (or first agent) have
  one deep conversation about the goal. After that, agents drive
  execution. You step back in when:
  - Scope ambiguity is logged in a task spec (`status: needs-direction`).
  - An agent escalates to you via `priority: urgent` message in
    `runtime/inbox/operator/` (you check this directory between
    sessions, or the Coordinator surfaces it).
  - You want a status check.
- **You decide when it's safe to deploy.** Agents will not assume
  it's safe to ship just because the diff looks clean. They wait for
  your green light on anything irreversible.

### How to check status without spawning anything

```bash
# Quick listing of who's active and what they're doing
ls ~/OPS/WORKFORCE/FLEETPROJECTS/<project>/runtime/manifest.d/

# Per-agent state
cat ~/OPS/WORKFORCE/FLEETPROJECTS/<project>/runtime/manifest.d/Bravo.json

# Open tasks
ls ~/OPS/WORKFORCE/FLEETPROJECTS/<project>/runtime/tasks/

# Recent messages in your inbox
ls ~/OPS/WORKFORCE/FLEETPROJECTS/<project>/runtime/inbox/operator/

# Recent inter-agent activity
tail -20 ~/OPS/WORKFORCE/FLEETPROJECTS/<project>/runtime/log.jsonl
```

A helper script (`bin/ac-status`) wraps these in Pass 2.

### How to retire a stuck session

If an agent crashes or you close its terminal without graceful exit:

1. Their `manifest.d/<name>.json` will go stale (`last_seen` older
   than 30 min).
2. Either the Coordinator or any other active agent can mark them
   `status: stale` and free their name back into the pool.
3. If a task was assigned to them, it goes back to `status: unassigned`.
4. Their journal file (`runtime/journal/<name>.md`) survives so you
   can read what they were thinking.

If you want to forcibly clear: delete `manifest.d/<name>.json`. The
name is now free.

### How to clear EVERYTHING and start fresh

```bash
# Caution: this wipes all active state. Decision log + archive survive.
rm ~/OPS/WORKFORCE/FLEETPROJECTS/<project>/runtime/manifest.d/*.json
rm ~/OPS/WORKFORCE/FLEETPROJECTS/<project>/runtime/pulse/*.json
rm -rf ~/OPS/WORKFORCE/FLEETPROJECTS/<project>/runtime/inbox/*
```

Tasks, decisions, archived messages, and the event log are not
touched. Those are the audit trail.

### What's tracked in git, what isn't

**Tracked (in the OPS repo, pushable to your private GitHub):**
- The fleet system itself: `personalities/`, `protocol/`, `bin/`,
  this README. Identical doctrine + tooling across every machine.

**Not tracked — gitignored, machine-local** (everything under a
project's `FLEETPROJECTS/<project>/runtime/`):
- Manifest (`manifest.d/`)
- Tasks (`tasks/`)
- Decisions (`decisions/`)
- Archived messages (`archive/`)
- Event log (`log.jsonl`)
- Live inbox/outbox (`inbox/`, `outbox/`)
- Pulse heartbeats (`pulse/`)
- Agent journals (`journal/`)
- Tmp staging (`tmp/`)

Every one of those lives under `FLEETPROJECTS/*/`, which is 100%
gitignored — it's the audit trail for THIS machine's fleet activity,
not a synced ledger. If you're on a second machine and an agent on
the first is mid-task, `git pull` gets you fleet-system (doctrine +
tooling) updates, not the first machine's manifest, tasks,
decisions, or inbox — none of that ever leaves its disk. Continuity
across machines rides OPS's tracked docs (`CONTEXT/`) and
auto-memory instead — see "Cross-machine workflow" below.

### Cross-machine workflow

Fleet mechanics are Linux-only (see the top of this file) — a
Windows machine doesn't run agents at all, so there's no
Linux-fleet-state to hand off to a Windows fleet-state. The
practical cross-machine case is Linux-to-Linux (laptop today,
homelab tomorrow), and even then: per-project `runtime/` is
machine-local and gitignored, so `git pull` on the second machine
gets fleet-system (doctrine + tooling) updates only — not the first
machine's manifest, tasks, decisions, or archive. Those stay on the
first machine's disk.

If you need to hand a project off to a fresh machine:

- Treat the old machine's agents as gone — they can't be reached or
  resumed remotely. Start clean on the new machine, new names from
  the pool.
- Continuity comes from what OPS actually tracks: `CONTEXT/`
  docs and auto-memory. If a decision or lesson from the old
  machine's fleet run needs to survive the handoff, promote it into
  `CONTEXT/projects/<project>-lessons.md` or a memory entry before
  switching — the fleet runtime itself will not carry it for you.

The continuity is the promoted lessons + decisions record you
choose to carry forward, not the agent identities or the runtime
state.

### Safety rails

These are encoded in the personality files. Listed here so you know
the boundaries the agents respect:

1. **No irreversible actions without Operator approval.** Merging to
   `main`/`master`, force-pushing, deploying to prod, dropping DB
   tables, deleting branches — agent must ask.
2. **No bypassing pre-commit hooks** (`--no-verify`, `--no-gpg-sign`)
   without you saying so.
3. **No secrets to the coordination dir.** Pulse files, messages,
   tasks — none of these contain credentials. Hard rule, no
   exceptions.
4. **Conflict between agents goes through decision records, not
   relitigation.** Once a decision is written in `runtime/decisions/`,
   it's settled until you override it.
5. **Caveman mode does not apply to Coordinator → Operator
   communication.** Clarity > brevity when direction is being set.

### Troubleshooting

**"Two agents claimed the same name."** Shouldn't happen — registration
checks `manifest.d/` for the name first. If it does, the second one to
write wins (last write to `manifest.d/<name>.json` overwrites the
first). Manually fix by editing one of the JSONs to a different
unclaimed name and updating any in-flight message references.

**"Coordinator says all agents are stale but I'm sitting in a session
right now."** Your agent didn't update its pulse. Tell it
"refresh pulse" or it'll catch up on its next major action.

**"An agent is stuck waiting on something."** Check
`runtime/tasks/<id>.md` for the blocker. Either resolve the blocker
yourself or tell the agent to pivot to another task — agents won't
auto-pivot unless explicitly told.

**"I want to talk to a specific agent directly, not through the
Coordinator."** Just open a session and tell that agent's name and
scope: "You're Bravo. You handle n8n." The agent will register, see
the Coordinator, and proceed.

---

## File layout (reference)

```
WORKFORCE/
├── README.md                       # this file
├── personalities/                  # shared doctrine (tracked, identical across machines)
│   ├── AGENT.md                    #   absorbed on ACTIVATE AGENT
│   ├── COORDINATOR.md              #   absorbed on ACTIVATE COORDINATOR
│   ├── name-pool.md                #   leadership titles (Coord) + NATO phonetic (Agent)
│   └── captain-standing-orders.md  #   cumulative Operator expectations
├── protocol/                       # shared protocol (tracked, identical across machines)
│   ├── messaging.md                #   message format + atomicity rules
│   ├── lifecycle.md                #   join/leave/handoff/idle/pause
│   ├── escalation.md               #   when to ping Operator
│   └── decisions.md                #   decision record format
├── bin/                            # ac-* helper scripts (tracked)
└── FLEETPROJECTS/<project>/        # per-project runtime (GITIGNORED — machine-local)
    └── runtime/
        ├── manifest.d/             #   who's active
        ├── tasks/                  #   operator-issued task specs
        ├── decisions/              #   architectural decisions
        ├── archive/<name>/         #   processed messages
        ├── log.jsonl               #   event log
        ├── inbox/<name>/           #   pending messages
        ├── outbox/                 #   composing
        ├── pulse/<name>.json       #   heartbeat
        ├── journal/<name>.md       #   WIP reasoning (CAN GROW LARGE)
        └── tmp/                    #   atomic staging
```

**Tracked vs gitignored:** The fleet system (personalities, protocol,
bin, README) is tracked — identical doctrine + tooling across every
machine. The per-project runtime under `FLEETPROJECTS/<project>/` is
**gitignored** — it's the machine-local audit trail, not synced. This
prevents large journals + pulse churn from bloating the repo.

---

## Terminology

| Term | Meaning |
|---|---|
| **Operator** | The Operator (human, you). Final reviewer + decision-maker. Pulled in only for scope/direction clarity. |
| **Coordinator** | Optional Claude agent acting as foreman. Routes Operator intent → tasks → agents. Leadership-title names (Captain, Marshal, Commander, Chief, …) per fleet-doctrine F3. |
| **Agent** | Worker Claude. Does the coding/testing/deploy. NATO phonetic name + scope tag (e.g., `Bravo[n8n]`). |
| **Manifest** | The registry of who's active. One JSON file per agent in `manifest.d/`. |
| **Pulse** | Heartbeat written by an agent at session start, before major actions, and before exit. Gitignored. |
| **Task** | A unit of operator-issued work, with status, blockers, and assignee. Lives in `runtime/tasks/`. |
| **Decision** | A settled architectural call. Lives in `runtime/decisions/`. Not relitigated. |
| **Journal** | Per-agent WIP reasoning. Gitignored. Coordinator can read; not surfaced to Operator unless asked. |
| **Activation** | The act of typing `ACTIVATE AGENT` or `ACTIVATE COORDINATOR` in a fresh session. Triggers the bootstrap. |

---

## Living document

The Operator owns this file. Agents propose changes via a
`task: protocol-change` task spec. Operator reviews + approves.
Agents do not edit `README.md` or files under `personalities/` or
`protocol/` without the Operator's explicit sign-off.

Last updated: 2026-07-06 (Doc-truth sweep — fixed an internal
contradiction: this file's "Tracked in git" summary near the top
was already correct (everything except `FLEETPROJECTS/*`), but the
"What's tracked in git, what isn't" and "Cross-machine workflow"
sections below it wrongly claimed manifest/tasks/decisions/archive/
log sync via `git pull`. Verified: `FLEETPROJECTS/*/` is 100%
gitignored — those sections now say so and reframe cross-machine
continuity as riding `CONTEXT/` docs + memory, not fleet runtime.)

Last updated: 2026-05-18 (file-layout dedup; leadership-title naming
canonicalized; AC_ROOT contract reaffirmed).
