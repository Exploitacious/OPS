# Changelog

Notable changes to OPS, newest first. Format: date — what changed and why it
matters. This file starts fresh at the public release; the harness's private
prehistory is deliberately not part of it.

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
  invariants; new shared `hooklib.sh` provides the portable
  `work_session_key` / JSON helpers the hooks depend on.
- **`pre-compact.sh`** now appends a mechanical work-log segment per compact, and
  **`pre-compact-synthesis`** gains a "pause vs close" disambiguation plus a
  one-line narrative breadcrumb — so a multi-compact session's whole story
  reaches the eventual close. Pause never touches time or tickets; only
  `session-close` reconciles.
- **`session-briefing.sh`** now sources `hooklib.sh` and carries a backstop that
  flags sessions abandoned without a reconciliation run (their work may be
  unlogged).

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
