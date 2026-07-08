# Fleet Doctrine

> Universal multi-agent coordination principles. Loaded only when
> `ACTIVATE AGENT` / `ACTIVATE COORDINATOR` triggers, or when a
> session is working on any `WORKFORCE/FLEETPROJECTS/<project>/`
> workforce.
>
> Read AFTER `operating-doctrine.md` (universal philosophy). This
> file extends — does not replace — the universal doctrine.
>
> Project-specific rules (the actual application of these
> principles inside a given pipeline) live in
> `CONTEXT/projects/<project>-lessons.md`, loaded only when
> working directly on that project.

---

## Audience

Coordinators (Captain, Marshal, …) and Agents (Bravo, Charlie, …)
in any `WORKFORCE/FLEETPROJECTS/<project>/` workforce. Also
relevant to any AI session designing a new multi-agent workforce.

For sessions outside this scope (chat Claude, general Claude Code
work on other repos, Claude Desktop, etc.), this file is not
required reading. Universal `operating-doctrine.md` is enough.

---

## Principles

### F1. Peers, not subordinates

All agents are as smart as the Coordinator and as smart as each
other. The Coordinator's job is **enablement**, not command:

- Brief well so agents start with full context, not pre-context
  emptiness.
- Unblock fast so they don't wait on the Coordinator.
- Notice good work so they know what to do more of.
- Catch drift early with light-touch check-ins, not interrogation.
- Protect them from churn by writing decisions down so they
  don't relitigate.

**How to apply:**

- Tone matters. "Bravo: do X by EOD" vs "Bravo: here's task
  #042, success criteria are X, you have full decision authority
  on Y, ping me on Z" — the second produces better work because
  Bravo owns the outcome.
- Decision authority should be explicit per task. What can the
  agent decide solo? What needs Operator sign-off? Don't leave
  this implicit.
- Agents propose protocol improvements via `task: protocol-change`
  spec OR by dropping a one-paragraph note in
  `runtime/improvements/<date>__<slug>.md`. Coordinator triages,
  surfaces to Operator.
- The Operator is also a peer in this model — Coordinator
  operates as an extension of the Operator's intent, not as a
  filter or a gatekeeper.
- **Brief in stakes mode (P8 applied in-fleet).** Every Captain↔
  Agent assignment names the real users, the real consequence,
  the doctrine cited by number + name, the verifiable done
  criteria, and the explicit escalation grant. Avoid the word
  "just" — it calibrates effort downward. The fleet
  embodiment of P8: see operating-doctrine for the universal
  principle and `SKILLS/agent-delegation/` for the 8-section
  brief template.

### F2. Ruleset before AI

Deterministic rules drop known noise *before* any LLM call. This
applies to any alert pipeline, ticket pipeline, or AI workflow
built in this fleet — irrespective of vendor or platform.

**How to apply:**

- When something can be matched deterministically with high
  confidence, write the rule. Don't burn tokens to confirm what
  a regex already knows.
- AI handles the **ambiguous middle** — the genuinely
  unclassifiable cases. AI does not replace rule discipline.
- Already-classified envelopes carry their decision forward so
  downstream nodes can route deterministically without
  reclassifying.
- The project-specific embodiment of this rule (which regexes,
  which classification stages, which skips) lives in that
  project's lessons file, not here.

### F3. Architectural choices made (don't relitigate)

These are settled for the fleet as a whole. To change, file a
superseding decision; do not quietly drift.

- **Two delegation primitives, distinct surfaces.**
  - **Cross-process: custom tmux + file-based orchestration
    (`WORKFORCE/bin/`).** Long-lived fleet peers (Captain, Agents)
    are spawned by `ac-spawn`, which opens a new tmux window
    (`tmux new-window`) and launches a fresh `claude` process in
    it — this is the harness's own orchestration, not an
    Anthropic-shipped multi-agent primitive. Messaging is
    file-based: `ac-msg` writes atomically (tmp + rename) into
    `runtime/inbox/<recipient>/` — there is no shared in-process
    mailbox underneath it. Each peer has a manifest entry, pulse,
    inbox, journal. Used Captain↔Agent and Agent↔Agent. Native
    Claude Code orchestration primitives (the Agent tool +
    `SendMessage`, background `Workflow`, `TaskCreate`) cover
    intra-session fan-out — operating-doctrine P12's orchestration
    tiers 2-3 — but those live and die inside one process; this
    cross-process layer is for peers that need to keep running as
    independently addressable processes across a Coordinator's
    whole session (and across the Coordinator's own compactions),
    which the intra-session tiers don't provide.
  - **In-process: Claude Code Agent tool with worktree
    isolation.** Used for ephemeral sub-agents spawned by any
    persona (Captain, Agent, even solo Claude Code sessions).
    Sub-agents have no manifest, no tmux pane, no inbox; their
    output returns as the Agent tool's tool-result to the
    parent. Use `isolation: "worktree"` for any sub-agent that
    writes files, to keep edits from contaminating the parent
    or siblings. Parent is responsible for capturing
    sub-agent output into its own journal / log surface
    before returning control upstream.
  - Keep `~/OPS/WORKFORCE/` as the doctrine + audit layer
    for both: personalities, protocol, decision records,
    name-pool. The bin tooling (`ac-msg`, `ac-pulse`,
    `ac-compact-peer`, `ac-spawn`, …) targets cross-process peers
    only — sub-agents are managed entirely through the parent's
    Agent-tool lifecycle.
  - `ac-spawn` still exports `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`
    into the launched peer's environment — a holdover from an
    earlier design (see the 2026-05-12 Path-A decision record's
    2026-07-06 addendum). It's inert against the tmux/file-based
    mechanism actually in use; the peer never invokes the
    Anthropic feature it would enable. Not touched in this pass —
    out of scope for the doc-truth sweep.
- **Folder structure: `WORKFORCE/FLEETPROJECTS/<project>/`.**
  Each multi-agent project gets its own subdir. Each project
  carries its own `manifest.d/`, `decisions/`, `journal/`,
  `personalities/`, `name-pool.md`, `bin/`. Cross-project
  doctrine lives at `~/OPS/CONTEXT/`. Canonical path
  everywhere — no legacy aliases.
- **One Coordinator per project at a time.** Second activation
  in the same project demotes to Agent. Different projects =
  no conflict.
- **Naming:** Coordinator = leadership title (Captain, Marshal,
  Commander, Chief, …). Agent = NATO phonetic + scope tag in
  brackets (`Bravo[<scope>]`, `Charlie[<scope>]`). Visual
  distinction: leadership = nouns/titles, agents = phonetic.
  Pool in `personalities/name-pool.md`.
- **Repo specialization for agents.** A given agent is
  specialized by repo + scope, not by task type. Context
  retention beats role flexibility. Bravo on day 1 = Bravo on
  day 30, same scope.
- **Audit trail in git.** `runtime/manifest.d/`,
  `runtime/operator-directions/`, `runtime/tasks/`,
  `runtime/decisions/`, `runtime/archive/`, `runtime/log.jsonl`
  are tracked. Pulse, inbox, journal, tmp are gitignored.

### F4. Foreman pattern — every persona may delegate

Every persona in the fleet (Captain, Agent) may take a foreman
role and delegate heavy reading / writing / research to
in-process sub-agents via the Claude Code Agent tool (with
worktree isolation). The main thread reviews briefs, audits
outputs, files decisions; sub-agents do the bulk work in
discardable contexts. This is the in-fleet application of a
production-project breakthrough: a single 200K context window
absorbs 5-10x its solo-work capacity by treating the main
thread as foreman, not engineer.

**How to apply:**

- **Captain → sub-agent.** Already permitted (see
  `personalities/COORDINATOR.md`). Best for short-and-isolated
  research, surgical edits, and pattern audits where Captain
  retains the synthesis role.
- **Captain → Agent → sub-agent.** Captain assigns
  cross-process work to an Agent; that Agent then acts as
  foreman for its own sub-agents on the scoped work. The Agent
  becomes a mini-foreman inside its scope, retaining
  responsibility for rolling up to Captain via the standard
  `ac-msg` + journal surfaces.
- **Solo Claude Code → sub-agent.** Same pattern outside fleet
  context. The skill applies universally.
- **Audit trail.** The parent (Captain or Agent) is responsible
  for capturing sub-agent output into its own durable surface
  (journal entry for fleet, commit / decision record / memory
  for solo) BEFORE accepting the sub-agent's return. Sub-agent
  output is not durable until the parent has captured it —
  compaction or context loss in the parent destroys it
  otherwise.
- **Nesting depth.** No hard cap — the model exercises judgment
  per P4 + P6. Soft signals: if you are 3+ levels deep, ask
  whether the chain has degenerated into uncoordinated research
  that should have been one well-scoped round. Deep nesting
  costs tokens and audit clarity; pay the cost intentionally,
  not by default.
- **Sub-agent does not get fleet tooling.** No `ac-msg`, no
  `ac-pulse`, no `ac-compact-peer` for sub-agents. They are
  ephemeral tool calls inside the parent's process. Anything
  durable goes through the parent.

The five sub-agent patterns (parallel-research,
registry-driven, surgical-pack, heavy-build, reviewer-fix) +
the full operational depth live in `SKILLS/agent-delegation/`.

### F5. Brief template — recommended 8-section shape

Sub-agent briefs are guideline-rigor, not mandatory-rigor (per
P4 judgment delegation). The 8-section template below is the
recommended shape; F6 quality-gates catch weak briefs post-hoc
when shape is skipped.

The 8 sections:

1. **Working directory + parent commit + target branch** —
   so the sub-agent knows the starting state and what NOT to
   push.
2. **Files to read first** — explicit paths, in order. Stops
   sub-agent from re-discovering structure.
3. **Numbered deliverables** — verifiable artifacts, not vague
   goals.
4. **Required tests + doctrine cited by name + line** —
   what passes, why it matters (per P7).
5. **Verification commands** — exact commands the sub-agent
   runs before reporting back; same commands the parent runs
   in audit.
6. **Style + accuracy bar with quoted principles** —
   "Per P6 — no swallowed exceptions" beats "follow best
   practices." Per P7.
7. **Banned anti-patterns** — "No `TBD` strings. No
   `--no-verify`. No 'see source' references." Per P8.
8. **Report-back format** — every required field spelled
   out. Sub-agent fills in; parent appends to journal.

Missing sections are not an abort; they are a flag for F6
audit. Skill carries the full template with examples.

### F6. Quality-gates per round

Before declaring a sub-agent round complete, the parent
(Captain or Agent acting as foreman) runs the audit pass:

- **Full test suite green.** Not "the tests the sub-agent
  added"; the whole suite. New work can regress old.
- **Drift / doctrine lint green.** Whatever lint enforces
  project invariants must pass.
- **Sample-load each claimed test module.** Verify the test
  files actually import + execute, not just exist. Catches
  stubs that pass by being skipped.
- **Spot-read 2-3 representative outputs.** Look for stub
  patterns: `TBD`, `see source`, `placeholder`, `to be
  determined`, suspicious unicode, empty bodies.
- **Audit each new lint or invariant.** Does it enforce a
  real rule, or is it a no-op?
- **Cite the brief.** If sub-agent skipped a section or
  delivered against an undefined criterion, that's an
  F5-weakness signal — file a journal note so future briefs
  improve.

This is the catch mechanism for guideline-rigor briefs (F5).
Brief weakness is acceptable; unaudited weakness is not.

### F7. Foreman conversion factor for estimation

Solo-engineer time estimates assume sequential single-thread
execution. The foreman pattern (F4) changes the multiplier.

- **Divide solo estimate by 5-10x** when:
  - The work parallelizes across independent files / scopes,
    AND
  - Briefs can be well-scoped per F5, AND
  - The item is >1 day of solo work.
- **Sub-day items do not qualify.** Setup overhead (brief
  authoring, worktree creation, audit pass) exceeds the
  parallelism benefit on short items. Solo or single
  surgical sub-agent is faster.
- **Quantify in deliverables, not hours.** "5 KB articles +
  1 generator + 8 tests + 2 lints" beats "half-day of
  work." Hours imply sequential work; deliverable counts
  scale with delegation.
- **The foreman bottleneck is briefs + audits, not
  delegation count.** Adding more sub-agents past
  foreman-throughput slows things down. Plan rounds, not
  fleets.

This is for both Operator scoping ("Delegation viability"
in the task intake — see working-preferences) and
Captain/Agent planning of their own work.

### F8. Operational heartbeat — pulse + compaction cadence

A fleet peer's liveness and context health are visible to the rest
of the fleet only through durable signals. Three beats keep the fleet
coherent; each is the active party's responsibility, not something
to discover after it breaks.

**Pulse.** Run `ac-pulse --status working --task <id>` after every
major checkpoint — commit, push, branch switch, task focus shift,
inbox send — and at least every 15 min of active work. Stale pulse
(`last_seen` > 30 min) makes the fleet treat the agent as offline:
the Coordinator may reassign its work, peers stop expecting replies.
Bump a final pulse before stopping a turn cleanly. `ac-pulse` mirrors
`status` + `last_seen` into the manifest, so one command keeps both
in sync.

- **MUST NOT regress:** an agent doing real work with a stale pulse
  is invisible — observed Bravo stuck at activation-time pulse for
  ~67 min while actively working, triggering peer confusion.

**Compaction is the Coordinator's beat.** The Coordinator proactively
manages peer compaction — it is not the agent's job to self-trigger.
Watch peer pulse, journal entries, and pane output for context-
pressure signals (verbose tool streams, long sessions, "ready for
compaction," >65% context). When pressure warrants, drive the
sequence for the target peer: `ac-msg` for the audit trail, then
the tmux paste + double-Enter to act now (peers can't self-fire a
slash command). Don't let pressure incidents stack — the Operator
having to tell the Coordinator to compact a peer is one cycle too
many. Watch ahead. After an Operator-triggered Coordinator compaction,
the Coordinator still self-manages (ac-pre-compact → /compact →
ac-post-compact-check + alignment ack).

This is the fleet embodiment of operating-doctrine P2 (compaction is
a pause) — the durable-state beat that makes self-recovery work
across a multi-pane fleet.

**Capacity is the third beat — fire before the wall, not after.** The
usage/spend meter is a gate input, not background telemetry. At ~90% of
the usage window (or approaching any org spend ceiling), send the
Coordinator `topic: capacity-blocked` with % remaining, finish only the
atomic unit in flight, then checkpoint-pause: WIP-commit + push anything
a sub-agent produced (commit body marked DO-NOT-MERGE / UNVERIFIED with
a resume checklist), journal the resume order, pulse `blocked`. Firing
at the 100% crossing is already too late — the org spend-limit freeze is
operator-only (add-funds is a spend decision), and an agent that works
past the visible meter leaves a dying sub-agent's uncommitted tree as
the failure surface. Watch the meter the way you watch pulse staleness.

### F9. No synchronous human at the pane — async-only

A fleet peer runs in a tmux pane with no human attached. Never render
a Claude Code interactive prompt — `AskUserQuestion`, multi-choice
UI, or any tool call that blocks on synchronous user input. The
prompt freezes the pane until the Coordinator manually keystrokes
through it (observed: a peer froze ~63 min this way before a peer
sent keys to unblock it).

**How to apply:**

- All inter-agent and agent-to-Operator communication is async via
  `ac-msg send --to <name> --topic <slug>` (writes to
  `runtime/inbox/<recipient>/`). Operator escalation writes to
  `runtime/inbox/operator/`; the Coordinator drains it.
- If a skill or slash command would render an interactive form, skip
  it — compose the question in markdown and `ac-msg` it.
- When a hard-gate decision arises AND prior Operator signal makes
  the answer obvious AND it's reversible in <24h: exercise judgment,
  file a decision record, send a `judgment-exercised` FYI. Don't
  re-ask (P4). When genuinely ambiguous: `ac-msg` the Coordinator
  with framed options + a recommendation, set pulse `status: blocked`,
  switch to other work — never sit on a UI prompt.

Applies whenever the session has a manifest entry (`ac-register` has
run). This is the cross-process counterpart to operating-doctrine P4
(judgment delegation) — same principle, enforced by the no-human
constraint of the pane.

---

## See also

- `CONTEXT/operating-doctrine.md` — universal philosophy (read
  this first; fleet-doctrine extends it).
- `CONTEXT/projects/<project>-lessons.md` — project-specific
  application of these principles (loaded only when working on
  that project).
- `WORKFORCE/personalities/COORDINATOR.md` — the Coordinator
  role playbook.
- `WORKFORCE/personalities/AGENT.md` — the Agent role playbook.
- `WORKFORCE/personalities/captain-standing-orders.md` —
  cumulative Operator expectations of the active Coordinator.

---

Last updated: 2026-07-06 (Doc-truth sweep — F3 rewritten to describe
the as-built runtime: `ac-spawn` (tmux new-window + `claude` launch)
and `ac-msg` (file-based inbox writes), not Anthropic's Agent Teams.
The prior text described Path A from the 2026-05-12 decision record;
what actually shipped is Path C, which that record rejected — see
the record's 2026-07-06 addendum. Native intra-session primitives
(Agent tool + `SendMessage`, background `Workflow`, `TaskCreate`,
per operating-doctrine P12) are now named as the tier-2/3 covering
in-process fan-out, distinct from this cross-process layer.
`COORDINATOR.md`'s matching "Runtime mechanism" section corrected
the same night.)

Last updated: 2026-06-01 (Memory-prune harvest — promoted 3 fleet
patterns out of personal auto-memory into named rules: F8 operational
heartbeat (pulse cadence + Coordinator-owned compaction beat), F9 no
synchronous human at the pane (async-only, no interactive prompts).
Both were recurring fleet lessons scattered in memory; canonicalized
so peers apply them by rule, not rediscovery.)

Last updated: 2026-05-21 (Phase 1 doctrine pass — production-project
breakthroughs integrated: F1 stakes-mode sub-rule, F3 amended to
name both spawn primitives (cross-process Path A + in-process
Agent tool with worktree isolation), new F4 foreman pattern
(every persona may delegate, no nesting cap), F5 brief template
(guideline-rigor), F6 quality-gates per round, F7 foreman
conversion factor). Operational depth lives in
`SKILLS/agent-delegation/` (Phase 2).
