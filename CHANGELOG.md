# Changelog

Notable changes to OPS, newest first. Format: date — what changed and why it
matters. This file starts fresh at the public release; the harness's private
prehistory is deliberately not part of it.

## 2026-08-31 — Glue-skills v2 refresh; portable skills mounted, not vendored

- **Skills refreshed.** The local glue skills were ported to their v2 form:
  `grabit` (now the SEND direction), a new `grabit-screenshots` (the RECEIVE
  direction), `harness-update`, `memory-prune` (six-home taxonomy + a hardened
  `audit_workflow.js` that refuses to guess the memory dir), `pre-compact-synthesis`
  (split into `closeout-hygiene.md` + `self-compact-cycle.md`), `session-handoff`
  and `session-close` (each split into `mechanics.md`, plus `teardown.md` for
  the close), and a `remote-session` refresh scoped to the shipped script suite.
- **Portable skills are mounted, not vendored.** `agent-delegation` and
  `meta-skill-creator` were removed from `SKILLS/`. Portable technique skills now
  live in one shared source and every copy mounts them, instead of each copy
  carrying a drifting fork. Default source: `Exploitacious/agent-skills`; an org
  or private source mounts alongside. `SKILLS/README.md` and this README document
  the model.
- **Context slots.** `CONTEXT/` gained the slot registry (`slots.md`) plus the
  `voice.md`, `team.md`, `tools.md`, and `doctrine.md` slots, joining the existing
  `work-tracking.md`. Each names its degrade-when-absent, so a portable skill can
  reference a well-known slot and still run on a copy that hasn't filled it in.

## 2026-08-20 — Opus 5 banned; Opus 4.8 is the worker tier

- **Operator directive.** As the fan-out worker, Opus 5 showed
  disproportionate cache-write churn and message round-trips against Opus 4.8
  for equivalent output — self-checking redundantly against a harness that
  already runs its own review and verify lanes, for no quality edge. It spent
  a large share of the usage budget buying nothing.
- **Change.** Opus 4.8 (`claude-opus-4-8[1m]`) is now the default
  build/review/audit worker **and** the fallback foreman. Opus 5
  (`claude-opus-5`) is banned harness-wide, like Haiku. The `[1m]` suffix is
  required on Opus 4.8 — unlike Opus 5, 1M is not its default context, so a
  bare id silently books a 200K worker.
- **Pins flipped:** `.claude-config/agents/ops-{worker,reviewer,auditor}.md`
  frontmatter, and both judgment lanes (chief reviewer, completeness critic)
  in `.claude-config/workflows/harness-audit.js`. `ops-investigator` and the
  routine workflow lanes stay on Sonnet 5; rotation is now Opus 4.8 ↔
  Sonnet 5.
- **Doctrine synced:** `CONTEXT/foreman-charter.md` tier block,
  `CONTEXT/operating-doctrine.md` P12 tiering bullet + a dated entry,
  `SKILLS/agent-delegation/{SKILL.md,04_foreman_estimation.md}`, and the
  worker line in `.claude-config/hooks/session-briefing.sh`.
- **Machine enforcement:** `verify-ops.sh` gains check 15
  (`check_opus5_ban`) — FAILs if `claude-opus-5` appears as a spawn pin in
  any agent, workflow, or settings surface. Scoped to pins, not prose, so the
  doctrine can still name the banned id. Mirrors the Haiku tripwire: a rule a
  machine cannot check is a rule that silently rots.

## 2026-07-28 — Fable-primary model policy + availability probe

> **Superseded 2026-08-20:** Opus 5 is now BANNED harness-wide; Opus 4.8
> (`claude-opus-4-8[1m]`) is the default build/review/audit worker. Where this
> entry names Opus 5 as the worker tier, read it as history — see the 2026-08-20 entry.

- **The foreman seat is now role-based, not model-based** — the main session
  boots **Fable 5 where the Operator's plan allows it, Opus 4.8 otherwise**,
  and the charter it runs is identical either way. Nothing in the harness
  branches on which one answered. Where Fable is available it is usage-capped,
  so the foreman orchestrates only — briefs, delegation, decisions, reviewing
  worker output in the main thread — and **never spawns itself as a subagent**
  (there is no `fable` worker alias; a Fable worker would burn the scarce tier
  on work Opus 5 does fine).
- **New `bin/model-probe.sh`** — availability is plan-dependent and Operators
  generally don't know their own entitlements, so the harness detects it
  instead of asking. The probe checks whether Fable can actually run on this
  machine and settles the main-session pin accordingly, caching the verdict
  under `~/.local/state/ops` so every later boot reads the answer instead of
  re-probing; `--refresh` re-runs the detection, `--force` overrides the
  verdict when the Operator knows better than the probe. Wired into
  `deploy.sh` (best-effort, non-fatal — a probe that can't reach the API must
  not fail an otherwise-good deploy), into `BOOTSTRAP.md` Stage 0 recon (so
  the first real session boots the right foreman), and into the
  `harness-update` skill's post-sync gates (a sync can change model policy).
- **`ops-worker`, `ops-reviewer`, and `ops-auditor` hard-pinned to
  `claude-opus-5`** by exact id, not the `opus` alias — that alias is the
  *foreman* slot now, and a worker resolving through it would spawn the
  scarce tier. Opus 5 is the default build/review worker and never a foreman:
  as an executor of a precise brief it is excellent, as an orchestrator it
  loses the thread. The two `harness-audit` judgment lanes (chief reviewer,
  completeness critic) moved off the alias for the same reason;
  `ops-investigator` and the routine workflow lanes stay on Sonnet 5.
- **Haiku is banned harness-wide**, enforced as a stage-1 tripwire rather than
  a rule anyone has to remember: `ANTHROPIC_DEFAULT_HAIKU_MODEL` is pinned to
  `claude-sonnet-5`, so anything still requesting the haiku tier silently gets
  Sonnet 5. Never remove that key — removing it resurrects real Haiku. The
  `transcript-mine` scout lane, the last in-repo `haiku` caller, now names
  `sonnet` directly.
- **`session-briefing.sh` reports both model seats** — the `Config:` line
  gained `main=<pin>  ·  fallback(opus)=<alias>` in place of the single
  `opus=` field, and the worker line now reads `Opus 5 default worker ·
  Sonnet 5 light lanes`. Which foreman actually booted is the first thing a
  session needs to know when the answer varies by machine.
- **`verify-ops.sh` gains `check_model_policy`** — the drift gate now fails
  when the pins disagree with this policy (a worker pointed at the alias, a
  haiku reference reintroduced, the tripwire key removed), so the convention
  is machine-enforced instead of doc-enforced.
- (Stage-1 settings pins ship from the deployer repo: it now writes the
  top-level `model` key as `claude-fable-5[1m]` and repoints
  `ANTHROPIC_DEFAULT_OPUS_MODEL` to `claude-opus-4-8[1m]`. Pull the stage-1
  repo too, or update those keys yourself if you maintain your own fork.)

## 2026-07-24 — Opus 5 adoption: model tiers, effort rules, deliverable brand kit

> **Superseded 2026-08-20:** the Opus 5 adoption described here was reversed —
> Opus 5 is now BANNED and Opus 4.8 is the worker tier. See the 2026-08-20 entry.

- **Model policy moves to Claude Opus 5** — the main-session boot default and
  the `opus` worker alias both point at the plain `claude-opus-5` id (1M
  context is Opus 5's default AND max, so no `[1m]` suffix). Same $/token as
  Opus 4.8, separate rate-limit bucket, strictly stronger on hard
  coding/agentic lanes. Sonnet 5 stays the default worker
  (`ANTHROPIC_DEFAULT_SONNET_MODEL`), Sonnet 5 200K stays the trivial tier.
  Updated in `CONTEXT/foreman-charter.md`, `CONTEXT/operating-doctrine.md`
  (P12 + changelog), and `SKILLS/agent-delegation/04_foreman_estimation.md`.
  (Stage-1 settings pins ship from the deployer repo — update
  `ANTHROPIC_DEFAULT_OPUS_MODEL` and the top-level `model` key there if you
  maintain your own fork of the stage-1.)
- **Opus 5 behavioral calibration** (from Anthropic's "Prompting Claude
  Opus 5" guide): the charter's delegate-bias language was overshot against
  Opus 4.8's under-delegation — Opus 5 delegates readily, so a spawn-
  discipline block now bounds it (one agent when one suffices; no mid-task
  self-re-check spawns). The **completed-work review sweep is affirmed as a
  standing requirement regardless of model** — Opus 5's self-verification
  trims only duplicate mid-task re-checking, never the end-of-work reviewer
  pass.
- **Effort rules codified** — effort-decreases are the Operator's token-
  saving lever: honored without friction, never auto-restored mid-session,
  never applied autonomously by the AI, and never to review/verify lanes.
  (Opus 5 holds quality unusually well at `low`/`medium`, which is what makes
  an Operator-requested economy pass cheap.)
- **New brand-voice template section: "Client Deliverable Brand Kit"** —
  Opus-class models produce markedly better office documents (.docx/.pptx/
  .xlsx) when handed a concrete brand spec (logo, colors, fonts, section
  order, contact block) instead of "professional and clean." The template
  ships an EXAMPLE block to replace during bootstrap; found as the sole
  confirmed gap in a 16-agent audit of the prompting guide vs this harness.

## 2026-07-22 — scheduled 5h-window pings (claude-window-ping.sh)

- **New `bin/claude-window-ping.sh`** — cron-fired dumb pipe that opens the
  Claude 5-hour usage window at Operator-chosen times: one headless
  MCP-stripped `ping` to a brand-new session per configured profile
  (`CC_WINDOW_PING_PROFILES`, space-separated `name=config_dir` pairs,
  default `default=$HOME/.claude`; model via `CC_WINDOW_PING_MODEL`, default
  `sonnet`). Why: when your day has predictable blocks, pre-arming the shared
  window clock means the countdown is already running when you sit down. Runs
  from `$HOME`, outside tmux (ping sessions never enter the reboot-resume
  registry). The crontab is machine-local by design — install lines live in
  the script header and `bin/README.md`.
- **`session-briefing.sh` gains a quiet-when-clean `Ping:` line** — flags a
  failed last ping (per profile, with rc) or a stale one
  (`CC_WINDOW_PING_STALE_HOURS`, default 25h) at next session start; silent
  when the feature isn't installed (no status file) or the last run was clean
  and recent. A silent ping failure means the window never opened and nobody
  was present to notice — the next session's briefing is where it gets seen.
- **Hardened for unattended cron duty (review round):** malformed profile
  pairs are skipped loud (logged + rc=2 status row) instead of silently
  pinging a garbage config dir; whitespace-only config writes a loud
  `config` rc=2 row instead of a fresh-but-empty status the briefing reads
  as clean; the missing-binary path shares the atomic tmp+mv write; a
  non-blocking flock serializes overlapping runs; tmp litter from killed
  runs is swept; per-profile timeout promoted to `CC_WINDOW_PING_TIMEOUT`
  (default 180s). **`claude-window-ping-selftest.sh`** (new) proves all of it
  against a mock binary — profile routing, rc propagation (incl. 124/127),
  malformed/empty config, lock behavior, tmp hygiene — zero real API usage.

## 2026-07-22 — context-watch: escalation ladder + mid-turn injection

- **`context-watch.sh` rewritten from a single flat threshold into a 4-tier
  escalation ladder** scaled off `CC_CONTEXT_WINDOW` (default 1M): 65% NOTICE
  (re-nag +75K) / 78% WARNING (+40K) / 86% URGENT (+20K) / 92% CRITICAL (every
  stop). Crossing into a higher tier fires immediately regardless of growth,
  and the message language escalates per tier. Why: one polite nag repeated at
  a flat interval is easy for a deep-in-the-work session to defer until the
  window is gone.
- **New `posttool` mode closes the mega-turn blind spot.** Stop hooks only
  fire between turns — a long tool-calling turn can run from 65% to
  window-death without ever seeing a nag. Registered as a PostToolUse hook
  (matcher `.*`, arg `posttool`) in the Stage 1 `settings.json` template, it
  injects the warning mid-turn via `additionalContext` from 86% (+15K
  throttle, +8K at CRITICAL). **Existing copies:** hook config is
  session-cached and `settings.json` is Stage-1-owned — re-run Stage 1 (or add
  the PostToolUse entry to your `settings.json` by hand) and relaunch
  sessions to arm the mid-turn half; the ladder itself goes live immediately
  since the Stop registration already points at this script.
- **`context-watch-selftest.sh`** locks the ladder invariants (tier fires,
  throttles, escalation-overrides-throttle in BOTH modes, every-stop
  CRITICAL, loop guard, posttool injection + throttles, literal state-field
  integrity across the two write paths, post-compact epoch reset — a
  mid-session /compact shrinks context, and a stale high-water mark would
  otherwise suppress every re-nag below CRITICAL — kill switches, window
  scaling, legacy single-int state upgrade + both legacy overrides). The
  four core guarantees are mutation-verified: each selftest case fails when
  its clause is surgically removed. Fail-open like the hook: no python3 =>
  SKIP.
  Legacy `CC_COMPACT_NAG_TOKENS` / `CC_COMPACT_RENAG_TOKENS` overrides still
  honored (tier 1); `CC_CONTEXT_WATCH=0` kills all modes,
  `CC_CONTEXT_WATCH_POSTTOOL=0` the mid-turn half only.

## 2026-07-17 — session-close work-tracking reconciliation gate

- **`session-close` gains a WIP & work-tracking reconciliation step** (new step
  2): before a session tears down, it reconstructs which repos the session
  touched (from a per-session start stamp + compact-time work-log, scoped by git
  delta with automation commits filtered out) and reconciles each unit of work
  against the systems the Operator declares in the new `CONTEXT/work-tracking.md`
  — logging time, advancing a board card, or **drafting the entry text** when no
  tool is wired. Config-driven and additive: an unconfigured OPS still
  reconciles by drafting and reminding. It hardcodes no ticketing, time, or
  board system.
- **New SessionStart hook `session-work-init.sh`** stamps
  `~/.claude-compact-cycle/session-start-<KEY>` once per session
  (write-if-absent, survives compacts/resumes) so the gate can bound a session's
  span even when it never compacts. `session-work-selftest.sh` locks the stamp
  invariants; the shared `hooklib.sh` gains the portable `work_session_key`
  helper the new hooks depend on.
- **`pre-compact.sh`** now appends a mechanical work-log segment per compact, and
  **`pre-compact-synthesis`** gains a "pause vs close" disambiguation plus a
  one-line narrative breadcrumb — so a multi-compact session's whole story
  reaches the eventual close. Pause never touches time or tickets; only
  `session-close` reconciles.
- **`session-briefing.sh`** now sources `hooklib.sh` and carries a backstop that
  flags sessions abandoned without a reconciliation run (their work may be
  unlogged).

## 2026-07-16 — doctrine: token cost is not a lever against compliance

- New operating-doctrine ruling (Operator, 2026-07-06, now written down):
  never propose consolidating or trimming the always-loaded doctrine chain
  for token savings — repetition is how agents internalize a non-default
  posture; the harm is repeated contradictions, not repetition, and the
  drift checks exist to prevent exactly those. Compliance-motivated
  restructuring (worker-digest) stays fine; distinct from P12's
  workflow-spend gate.

## 2026-07-16 — project-kata: GHCR retention workflow for image-publishing repos

- New kata section: any repo publishing container images to GHCR gets a
  retention workflow at scaffold time (`ghcr-cleanup.yml`, manual-first,
  `dry_run` defaulting to true, keep-last-N, `exclude-tags` for
  `latest`/`prod`/sha pins) — plus the two platform gotchas learned live
  (`workflow_dispatch` only fires from the default branch; guessed package
  names 404).

## 2026-07-16 — flush-debt follow-up: stub-phrased entries no longer suppressed

- `secrets-guard.sh`: the routing nudge previously stayed quiet for entries
  phrased like stubs (`folded to` / `canonical entry lives` / `pointer stub`).
  Under charter § Eviction stubs shouldn't exist — a legacy stub is flush
  debt that belongs in the queue, so the suppression is removed and such
  entries now get nudged + queued for the closeout flush.

## 2026-07-16 — closeout/memory wave: memory is a write cache, arming-order gate

One-PR wave ported from a private harness under the CONTRIBUTING extraction
discipline (patterns rewritten, identity scrubbed, denylist at zero hits).

- **Memory eviction lifecycle.** `foreman-charter.md` § "Eviction — memory is
  a write cache, not an archive": auto-memory holds the working set plus a
  small set of standing facts; the long-term store is the repo (lessons
  files, docs), the cold archive is the git-synced mirror — deleting an entry
  is never data loss. Terminal projects purge their entries (fold into the
  lessons file, then delete — no stubs); `MEMORY.md` gets a ~16KB soft budget
  under the ~24.4KB platform truncation ceiling.
- **Closeout flush gate.** `pre-compact-synthesis` hygiene step 2 becomes a
  three-part gate: this session's entries plus the write-time flush queue
  (`secrets-guard.sh` now appends flagged entries to
  `~/.claude-compact-cycle/memory-flush-queue`), terminal-project purge, and
  budget eviction. `session-briefing.sh` memory health goes two-tier (flush
  debt at 16KB vs platform ceiling at 24KB); `session-close` purges the
  closing project's cache lines; `memory-prune` is repositioned as the
  quarterly deep audit, not routine maintenance.
- **Arming-order gate.** The self-compact cycle may only be armed after the
  four artifacts are green, docs-reflect-reality has passed, and a conscious
  knowledge-capture completeness check (the `transcript-mine` workflow since
  the last-closeout stamp, on long/autonomous sessions). Anything unresolved
  means DO NOT ARM — the automation removes the Operator's keystrokes, never
  the synthesis.
- **Also in the wave.** Migration-closeout checklist (the four vectors that
  make a fresh agent regenerate a removed pattern) in `pre-compact-synthesis`;
  the Workflow `args` trap (hardcode one-shot inputs; args can arrive
  undefined/stringified) in `agent-delegation/05_dynamic_workflows.md`;
  memory-index regeneration discipline in `memory-prune`.

## 2026-07-15 — backport wave: compact automation, session-persistence hardening, portable hooks

Five-PR wave ported from a private harness under the CONTRIBUTING extraction
discipline (patterns rewritten, identity scrubbed, denylist at zero hits).

- **Automated compact cycle.** `bin/compact-cycle.sh` — a deterministic bash
  compactor in a detached tmux session: waits for the target Claude pane to go
  idle, types `/compact`, watches completion, types the resume baton, and
  self-destructs; on error/timeout it never resumes (the session stays paused
  with synthesis on disk). `hooks/context-watch.sh` (Stop hook) nags the
  ritual from REAL context tokens (transcript `usage` entries), growth-
  throttled. `pre-compact-synthesis` gains the self-compact exit — automated
  is the default in tmux; manual only when the Operator claims `/compact`.
- **Session-persistence single-owner doctrine.** The registry system is the
  only thing allowed to (re)create Claude sessions. `tmux-main.service`
  rewritten from Type=forking + Restart=on-failure (server-death cascade →
  restart → resurrection storm) to oneshot + RemainAfterExit + KillMode=process.
  Registry staleness `sweep`, case-collision guard in the auto-register hook,
  and every tmux `-t` target exact-matched (`=Name` / `=Name:` — bare names
  unique-prefix-match; `kill-session -t Dev` can kill `Dev2`).
- **Portable hooks.** `hooks/hooklib.sh` `hook_field` (jq-first, python
  fallback, fail-closed) replaces inline `python3 -c` extraction across the
  guard hooks; `guard-selftest.sh` proves the guards actually block.
- **Deploy + docs.** `deploy.ps1` profile seam (`profile.local.ps1`, never
  `$PROFILE`), dynamic backup task (static XML retired), verify gate updates;
  DEPLOYMENT.md corrected to match `deploy.ps1` reality.
- **Workforce docs.** Memory-sync doctrine lessons, `ac-memory-init.ps1`
  exit-code contract restored, project-kata delta.

## 2026-07-08 — session-close skill

- `SKILLS/session-close/`: the third session ending. Pause = closeout +
  `/compact` (pre-compact-synthesis); move = session-handoff; **close** =
  full closeout synthesis, an archive-vs-forget decision, a receipt, then
  the session removes itself from the reboot registry and kills its own
  tmux. History is never deleted; archived sessions revive on demand.

## 2026-07-08 — Session lifecycle: profiles, auto-register, template sync

- **Profile-aware reboot-resume.** The remote-sessions registry gains an
  optional 4th column (`CONFIG_DIR`): sessions running a secondary Claude
  Code profile (`CLAUDE_CONFIG_DIR=...`) now resume from their own
  transcript store instead of silently starting fresh. 3-column rows keep
  working untouched.
- **Auto-registration.** New SessionStart hook
  (`.claude-config/hooks/remote-session-register.sh`): any Claude session
  that starts inside tmux self-registers for reboot-resume — hand-launched
  sessions included, not just skill-created ones. Archived names stay
  parked; opt out with `RC_AUTOREGISTER=0`.
- **`harness-update` skill + scan script.** The safe update path from the
  OPS template into your private copy: fetch-only upstream remote,
  classified delta (NEW / UPDATE / CONFLICT / IDENTICAL) against a
  last-synced marker, identity surfaces hard-excluded in both directions,
  conflicts never auto-apply.

## 2026-07-08 — Remote-controlled sessions (community PR #1)

- `.claude-config/remote-sessions/` + the `remote-session` skill: always-on
  Claude Code sessions in tmux, driven from another device via
  `claude --remote-control`, persisted in a registry and **resumed with full
  conversation history after a reboot** (@reboot cron + stable session ids).
  Archive/revive tooling parks sessions without losing history. Contributed
  by @kontrolflow — the first port from a sibling private harness.

## 2026-07-07 — Contribution discipline

- `CONTRIBUTING.md`: contributions here are typically extractions from a
  contributor's own private harness, so the extraction discipline (port
  patterns, never paste files; denylist self-scrub; run the gates) is the
  contribution gate. Includes a verbatim porting brief to hand an AI doing
  the merge.
- `main` is now PR-protected: review required, no direct pushes, no force
  pushes.

## 2026-07-07 — Initial public release

- OPS v1: foreman-by-default orchestration doctrine (P1–P15 + charter),
  git-synced file-based memory, session-survival discipline (pre-compact
  synthesis, handoff batons, post-compact re-orientation), the WORKFORCE
  fleet layer, six portable skills, two-stage deploy, and the first-launch
  `BOOTSTRAP.md` interview.
- Extracted file-by-file from a private harness with fresh git history;
  gated by an adversarial leak scan, a coherence review, a fresh-user
  cold-read audit, and the repo's own `verify-ops.sh` before the first
  commit.
