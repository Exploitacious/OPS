# Changelog

Notable changes to OPS, newest first. Format: date — what changed and why it
matters. This file starts fresh at the public release; the harness's private
prehistory is deliberately not part of it.

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
