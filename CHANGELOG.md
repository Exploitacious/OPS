# Changelog

Notable changes to OPS, newest first. Format: the date, then what changed and why it
matters. This file starts fresh at the public release; the harness's private
prehistory is deliberately not part of it.

## 2026-10-19: one always-loaded core, and the fleet retired

OPS booted through a foreman charter and an identity digest that a `claude()`
shell function appended to the system prompt. Only launches typed into an
interactive shell ran that function, so a T3 Code thread, an IDE session, or
`claude -p` started with none of the doctrine. This release replaces that boot
with one always-loaded file, moves the identity layer to files the template
sync never touches, and retires the multi-agent fleet. Existing copies migrate
by hand once: `DEPLOYMENT.md` § "Migrating to the core boot".

- **`CONTEXT/core.md` loads on every launch path.** One generic file, under
  15,360 bytes, with the rules every session and lane needs on every turn:
  role, intake and autonomy, delegation, landing and review, models, writing,
  rhythm, memory routing, and where to look. `deploy.sh` and `deploy.ps1` link
  it into `~/.claude/rules/ops-core.md`, which Claude Code loads as a user
  rule in the terminal, in T3 Code threads, in IDEs, and under `claude -p`.
  The Stage-1 `CLAUDE.md` fallback only asks the model to read the file, so it
  is no longer relied on. The Operator-gated set now includes releases, file
  and branch deletions, overwriting uncommitted work, and replacing a file
  outside the deliverable; secrets are masked by value, never by field name.
- **The doctrine set.** `how-i-work.md` carries P1-P15 under the same titles
  as the maintainer's private harness, so a brief citing "P6 best effort is the
  floor" means the same thing in both, plus the situational rules (git, review
  pickup, T3 Code hosting). `standing-orders.md` holds the Operator's dated
  rulings and overrides the defaults without editing them. `USER.md` and
  `voice.md` are templates with fully synthetic examples; the earlier voice
  samples paraphrased real messages. `AGENTS.md` replaces the root
  `CLAUDE.md`, because a root `CLAUDE.md` makes Claude Code skip every
  `AGENTS.md` below it, including the project repos under `PROJECTS/`.
- **Retired:** `foreman-charter.md`, `boot-digest.md`, `worker-digest.md`,
  `operating-doctrine.md`, `working-preferences.md`, `about-me.md`,
  `brand-voice.md`, `fleet-doctrine.md`, the `WORKFORCE/` fleet (55 files), the
  `foreman-charter.sh` and `remote-session-register.sh` hooks,
  `start-remote-claude.sh`, and the `ops-memory-gc` timer. The `claude()` shim
  is ultracode-only, and a re-deploy heals the old boot shim while keeping a
  Round F permission edit.
- **Template sync.** `harness-update-scan.sh` excludes `USER.md`, `voice.md`,
  `standing-orders.md`, the `work-tracking`, `team`, and `tools` slots, and the
  marker, plus the retired identity names, so a delta scan never lists an
  unmigrated identity file as REMOVED. This landed first, ahead of the renames.
- **BOOTSTRAP** writes the new set: `USER.md`, a `voice.md` starter, and a
  dated standing order for every Operator choice. Round F keeps its text and
  records into `standing-orders.md`; the new Round G sets up T3 Code's headless
  browser on T3 hosts (`sudo <t3> browser setup`), which `DEPLOYMENT.md`
  § "T3 Code hosts" also documents.
- **Remote sessions are hand-run.** Nothing registers a session or brings one
  back at boot; the registry resumes, parks, and revives by name, and `sweep`
  calls a stopped row `GONE`.
- **Tools that outlived the fleet** moved to `.claude-config/bin`:
  `memory-index`, `memory-init`, `memory-init.ps1`, and
  `claude-root-wrapper.sh`, which deploy wires for root only. The wrapper's
  conflict hint uses `pgrep -l`, because `pgrep -af` prints other sessions'
  full command lines.
- **Mounted skills arrive on a fresh install.** Deploy clones the public skill
  source once and runs `skills-vendor.sh sync`; it never pulls an existing
  clone. `skills-vendor.sh` honors `OPS_DIR`, compares file content, and falls
  back to tar where rsync is missing, as on a stock Debian container.
- **Deploy** strips the fleet's PATH and wrapper lines, takes `--no-system`
  (`-NoSystem` on Windows) to skip writes outside `$HOME` for test installs,
  and exits non-zero when a step fails.
- **The drift gate** checks the new boot: 16 fails when the core is missing,
  over budget, or not linked; 1b fails on a root `CLAUDE.md`; 5 counts the
  principles in `how-i-work.md`; 17 and 21b warn on retired hooks and files;
  21 is the `USER.md` canary; 23 requires every identity exclusion.
  `verify-ops.sh` checks another checkout through `OPS_DIR`. New tests:
  `.claude-config/bin/tests/` (memory-index, root wrapper, deploy rc and core
  wiring, skills-vendor) and new `verify-ops-selftest.sh` cases.
- **Skills refreshed.** `grill-me`, `tdd` and `diagnosing-bugs` mount from
  the public agent-skills library alongside the six earlier mounts; deploy
  clones it and runs `skills-vendor.sh sync`. `harness-update`,
  `pre-compact-synthesis`, `session-close`, `session-handoff`, `memory-prune`,
  `operator-voice` and the grabit skills follow the current rest-stop and close
  rules: a session closes only on the Operator's word, and the close stamp is
  now cleared (its redirect was missing, so the `rm` became a `printf`
  argument). New `scripts/inventory` for memory-prune, which exits 1 on a
  missing store so a wrong path cannot read as a clean pool. New generic
  `operating-model` and `stewardship` skills. The `fleet-doctrine` skill is
  removed with the fleet.
- **Automatic pushes go only to a private origin.** `memory-init
  --auto-commit` and the daily backup (`daily-sync.sh`, which the Windows task
  also runs) pushed to wherever origin pointed, so a tryout clone of this
  public template, a copy made public by mistake, or a public fork would have
  published the Operator's memory and notes every day. New
  `.claude-config/bin/origin-private-check` exits 0 only when GitHub (`gh
  api`) reports every push URL of origin private; it refuses the template URL
  in any form (exit 1) and anything it cannot verify (exit 2). Both callers
  still commit, keep the commit local on a refusal, and log the reason and the
  fix; the next backup that passes pushes every held commit. `memory-init.ps1`
  carries the same check. A self-hosted remote opts in per repo with `git
  config ops.pushVerified true`, which never overrides a public answer. Tests:
  `origin-private-check-test.sh`, `daily-sync-test.sh`, and new memory-init
  cases in bash and PowerShell.
- **Skill mounts never delete a folder they did not write.** A manifest row
  replaced whatever sat at `SKILLS/<name>`, so this release's `grill-me`,
  `tdd`, and `diagnosing-bugs` rows would have deleted an existing copy's own
  skill of that name. `skills-vendor.sh` now records a digest of each mirror
  it writes (`SKILLS/.vendored-state.tsv`) and moves any other destination,
  including a hand-edited mirror, to
  `.claude-config/backup/skills-replaced/<name>-<UTC>/` before installing,
  with a `BACKUP` line naming the path; a failed install moves it back.
  Mirrors of the six earlier rows, and mirrors already equal to their source,
  update in place as before.

## 2026-10-18: hotfix release (current models, a gate that passes, deploy stops editing Stage 1)

A fresh install against the current Stage-1 settings pinned retired models,
failed its own drift gate, had its deploy rewrite the shared Stage-1
`settings.json`, and reinstalled a plugin Stage 1 had just retired. This
release fixes those, and discloses the permission defaults Stage 1 sets.
Upgrading an existing copy: `DEPLOYMENT.md` § "Upgrading from a copy older
than 2026-10-18".

- **Model tiers brought current.** Opus 5.5 (`claude-opus-5-5[1m]`) is the
  foreman and the high-criticality lane; Sonnet 5.5 (`claude-sonnet-5-5[1m]`)
  is every lane's default; Haiku 5.5 (`claude-haiku-5-5`, exact id) is allowed
  for cheap reads under 100K tokens; Fable 5.1 is rare. Sonnet 5 and Opus 4.8
  are retired and pinned nowhere; the Opus 5 exact-id ban stands; every Haiku
  except Haiku 5.5 is banned. `CONTEXT/model-roles.md` is rewritten as the one
  table, and the foreman charter, operating doctrine (P12), README, BOOTSTRAP,
  and session briefing follow it. The `ops-worker`, `ops-reviewer`, and
  `ops-auditor` agents pin Sonnet 5.5 (the reviewer notes that a split review
  gate lands in a later release); the two judgment lanes of `harness-audit.js`
  pin Opus 5.5.
- **The drift gate passes a fresh install.** `verify-ops.sh` check 15 matches
  the Opus 5 id at its boundary, so `claude-opus-5-5` no longer trips it, and
  its remediation names the current tiers. New check 15b fails on a retired id
  (Sonnet 5, Opus 4.8) in agents, workflows, skill workflow scripts, or the
  settings files, on any Haiku other than `claude-haiku-5-5`, on the bare
  `haiku` alias as a value, and on an `ANTHROPIC_DEFAULT_HAIKU_MODEL` pin that
  is not exactly `claude-haiku-5-5`. Check 14 now WARNs only when the session
  pin is not the Opus 5.5 foreman. Check 18 no longer counts
  `session-work-init.sh` as a heavy hook: it belongs on resume, which is where
  the current Stage-1 settings run it. New `verify-ops-selftest.sh` drives
  these checks against fixture trees under a throwaway `HOME`.
  Review regressions also cover quoted and template-literal pins, JSON-escaped
  ids, Opus 5 in skill workflows and commands, Haiku provider/context suffixes,
  and a missing Haiku pin in another profile.
- **Deploy never writes the Stage-1 settings.** `deploy.sh` step 8 ran
  `model-probe.sh --refresh`, which rewrote the `"model"` line of
  `~/.claude/settings.json`: a symlink into the user's linuxploitacious
  checkout. It pinned a retired id or one that is not the foreman, and left a
  diff that fails that checkout's next `git pull --ff-only` whenever upstream
  changed the same file. The step is gone. `model-probe.sh` is
  now report-only: it probes each distinct pinned id and prints ok, FAIL, or
  UNSURE, with `--list` for a no-API dry run, and never edits settings. It honors
  `CLAUDE_CONFIG_DIR` and disables user customizations, tools, and transcript
  persistence while keeping subscription authentication. The CLI can update
  its own cache/auth state; policy-managed hooks still apply. New
  `model-probe-selftest.sh` checks those flags against a mock CLI, including
  that the mock leaves `HOME` unchanged. BOOTSTRAP recon reports its result instead of
  "settling the pin".
- **The caveman plugin is retired, not reinstalled.** `deploy.sh` and
  `deploy.ps1` installed caveman, unpinned, from its third-party marketplace
  right after Stage 1 uninstalled it. Both now uninstall caveman and ponytail
  through the CLI, like Stage 1. `DEPLOYMENT.md` verification checks they are
  absent, that the Stage-1 settings file is clean, and that the gate passes.
  Retirement warns and skips declarations whose removal would rewrite
  settings, scopes CLI removals to the user, and reports inventory/removal
  failures. `plugin-retire-selftest.py` checks both deployers against mock and
  local real CLI fixtures with symlinked Stage-1 settings.
- **Permission defaults disclosed and made a choice.** README "Opinionated by
  design" now states what the Stage-1 settings turn on:
  `permissions.defaultMode: "bypassPermissions"`,
  `skipDangerousModePermissionPrompt`, `remoteControlAtStartup`, and
  auto-compaction, and what each means. BOOTSTRAP gains Round F, an explicit
  step to keep those defaults or switch to normal permission prompts (in the
  terminal launch shim, or a managed normal default with bypass disabled),
  with the exact change and without editing the Stage-1 file. Existing allow
  rules and explicit CLI/IDE modes still apply; custom launch settings also
  need the Remote Control opt-out.
- **Questions use the structured question tool again.** The "AskUserQuestion
  is retired" rule is reversed in `CLAUDE.md`, the charter, and
  `working-preferences.md`: ask with the structured question tool where one
  exists, otherwise in numbered prose.
- **Compaction text matches the settings.** "Autocompact OFF" was wrong: the
  Stage-1 settings turn auto-compaction on as a backstop near the end of the
  window (Haiku 5.5 at a 100K window). The rhythm is manual compaction at
  natural breaks, and at about 300K tokens if no break has come.
- **Not in this release.** The larger port (one always-loaded core, the split
  review gate, retiring the fleet, refreshed skills, lane-aware context
  watching) follows separately.

## 2026-09-04: Boot surface rides the system prompt; rest-stop compaction

- **Charter + identity digest ride the cached system prompt.** The `claude()`
  launch shim (`deploy.sh`) now appends `CONTEXT/foreman-charter.md` +
  `CONTEXT/boot-digest.md` via `--append-system-prompt`, pinned with
  `--system-prompt-snapshot on`, so the standing orders LAND whole every launch
  and survive resume/compact verbatim. A SessionStart hook could only print a
  ~2KB preview, silently losing a long charter. `foreman-charter.sh` is retired
  for Claude Code (kept as an adapter seam); remove it from the Stage-1
  SessionStart matcher and split SessionStart into `startup|clear` /
  `resume|compact` groups (see DEPLOYMENT.md "Boot surface").
- **New `CONTEXT/boot-digest.md`**: a slot template (Example Corp flavor, zero
  real facts) for the operator's identity surface: who you work for, the three
  voice registers, people/clients/vendors, stack, doctrine P-pointers, and the
  always-binding standing orders. BOOTSTRAP fills it. Hard-excluded from
  `harness-update` so a template refresh never clobbers a filled copy.
- **The charter got a delete-first pass** (every paragraph an order or its why;
  depth is P-pointers), the Anthropic autonomy block at the head of "Finish the
  job", a don't-draft-twice effort line, and the rest-stop "Milestone rhythm".
  Planning questions move to prose; the AskUserQuestion block leaves CLAUDE.md.
- **`CONTEXT/model-roles.md`**: the model-tier policy (foreman / worker /
  banned, the [1m] ids, the Opus 5 + Haiku bans) as one source the charter and
  CLAUDE.md point at instead of restating.
- **Rest-stop compaction.** `context-watch.sh` gains a calm, boundary-aware
  `readout` mode (UserPromptSubmit): a closed task, a landed push/merge, a
  returned workflow, a >2h gap, or a branch switch pick one of three rest-stop
  texts; the scarcity/pressure vocabulary is scrubbed from every ladder nag. The
  compact cadence broadens to any clean task boundary (operating-doctrine P13 +
  P2, working-preferences § Standing Orders). `compact-cycle.sh` types a
  `PRESERVE` instruction as the `/compact` argument so the compactor keeps
  load-bearing detail.
- **Skill mount mechanism made concrete.** `.claude-config/bin/skills-vendor.sh`
  + `SKILLS/VENDORED.tsv` are now the one mount mechanism the README described;
  seven thin context skills (`operator-voice`, `project-kata`, `projects-map`,
  `machines`, `harness-deploy`, `harness-readme`, `fleet-doctrine`) route to
  `CONTEXT/`; a `design-method` skill ships the frontend-design method (Apache-2.0) with
  a fill-in `brand.md` layer.
- **`verify-ops.sh` gains eight checks** (16-23): boot shim carries both flags
  (FAIL); charter hook unregistered (WARN); source-scoped SessionStart matchers
  (WARN); SessionStart stdout byte budget (FAIL/WARN); anxiety-vocab gate on
  context-watch (FAIL); the boot-digest canary, generalized (missing => FAIL,
  unfilled-on-bootstrapped => FAIL, unfilled-on-fresh => OK); skills mirror in
  sync (DRIFT FAIL / MISSING WARN); boot-digest excluded from harness-update
  (FAIL). `context-watch-selftest.sh` gains full readout + boundary coverage.

## 2026-08-31: Glue-skills v2 refresh; portable skills mounted, not vendored

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

## 2026-08-20: Opus 5 banned; Opus 4.8 is the worker tier

- **Operator directive.** As the fan-out worker, Opus 5 showed
  disproportionate cache-write churn and message round-trips against Opus 4.8
  for equivalent output: self-checking redundantly against a harness that
  already runs its own review and verify lanes, for no quality edge. It spent
  a large share of the usage budget buying nothing.
- **Change.** Opus 4.8 (`claude-opus-4-8[1m]`) is now the default
  build/review/audit worker **and** the fallback foreman. Opus 5
  (`claude-opus-5`) is banned harness-wide, like Haiku. The `[1m]` suffix is
  required on Opus 4.8: unlike Opus 5, 1M is not its default context, so a
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
  (`check_opus5_ban`): FAILs if `claude-opus-5` appears as a spawn pin in
  any agent, workflow, or settings surface. Scoped to pins, not prose, so the
  doctrine can still name the banned id. Mirrors the Haiku tripwire: a rule a
  machine cannot check is a rule that silently rots.

## 2026-07-28: Fable-primary model policy + availability probe

> **Superseded 2026-08-20:** Opus 5 is now BANNED harness-wide; Opus 4.8
> (`claude-opus-4-8[1m]`) is the default build/review/audit worker. Where this
> entry names Opus 5 as the worker tier, read it as history: see the 2026-08-20 entry.

- **The foreman seat is now role-based, not model-based**: the main session
  boots **Fable 5 where the Operator's plan allows it, Opus 4.8 otherwise**,
  and the charter it runs is identical either way. Nothing in the harness
  branches on which one answered. Where Fable is available it is usage-capped,
  so the foreman orchestrates only: briefs, delegation, decisions, reviewing
  worker output in the main thread: and **never spawns itself as a subagent**
  (there is no `fable` worker alias; a Fable worker would burn the scarce tier
  on work Opus 5 does fine).
- **New `bin/model-probe.sh`**: availability is plan-dependent and Operators
  generally don't know their own entitlements, so the harness detects it
  instead of asking. The probe checks whether Fable can actually run on this
  machine and settles the main-session pin accordingly, caching the verdict
  under `~/.local/state/ops` so every later boot reads the answer instead of
  re-probing; `--refresh` re-runs the detection, `--force` overrides the
  verdict when the Operator knows better than the probe. Wired into
  `deploy.sh` (best-effort, non-fatal: a probe that can't reach the API must
  not fail an otherwise-good deploy), into `BOOTSTRAP.md` Stage 0 recon (so
  the first real session boots the right foreman), and into the
  `harness-update` skill's post-sync gates (a sync can change model policy).
- **`ops-worker`, `ops-reviewer`, and `ops-auditor` hard-pinned to
  `claude-opus-5`** by exact id, not the `opus` alias: that alias is the
  *foreman* slot now, and a worker resolving through it would spawn the
  scarce tier. Opus 5 is the default build/review worker and never a foreman:
  as an executor of a precise brief it is excellent, as an orchestrator it
  loses the thread. The two `harness-audit` judgment lanes (chief reviewer,
  completeness critic) moved off the alias for the same reason;
  `ops-investigator` and the routine workflow lanes stay on Sonnet 5.
- **Haiku is banned harness-wide**, enforced as a stage-1 tripwire rather than
  a rule anyone has to remember: `ANTHROPIC_DEFAULT_HAIKU_MODEL` is pinned to
  `claude-sonnet-5`, so anything still requesting the haiku tier silently gets
  Sonnet 5. Never remove that key: removing it resurrects real Haiku. The
  `transcript-mine` scout lane, the last in-repo `haiku` caller, now names
  `sonnet` directly.
- **`session-briefing.sh` reports both model seats**: the `Config:` line
  gained `main=<pin>  ·  fallback(opus)=<alias>` in place of the single
  `opus=` field, and the worker line now reads `Opus 5 default worker ·
  Sonnet 5 light lanes`. Which foreman actually booted is the first thing a
  session needs to know when the answer varies by machine.
- **`verify-ops.sh` gains `check_model_policy`**: the drift gate now fails
  when the pins disagree with this policy (a worker pointed at the alias, a
  haiku reference reintroduced, the tripwire key removed), so the convention
  is machine-enforced instead of doc-enforced.
- (Stage-1 settings pins ship from the deployer repo: it now writes the
  top-level `model` key as `claude-fable-5[1m]` and repoints
  `ANTHROPIC_DEFAULT_OPUS_MODEL` to `claude-opus-4-8[1m]`. Pull the stage-1
  repo too, or update those keys yourself if you maintain your own fork.)

## 2026-07-24: Opus 5 adoption: model tiers, effort rules, deliverable brand kit

> **Superseded 2026-08-20:** the Opus 5 adoption described here was reversed:
> Opus 5 is now BANNED and Opus 4.8 is the worker tier. See the 2026-08-20 entry.

- **Model policy moves to Claude Opus 5**: the main-session boot default and
  the `opus` worker alias both point at the plain `claude-opus-5` id (1M
  context is Opus 5's default AND max, so no `[1m]` suffix). Same $/token as
  Opus 4.8, separate rate-limit bucket, strictly stronger on hard
  coding/agentic lanes. Sonnet 5 stays the default worker
  (`ANTHROPIC_DEFAULT_SONNET_MODEL`), Sonnet 5 200K stays the trivial tier.
  Updated in `CONTEXT/foreman-charter.md`, `CONTEXT/operating-doctrine.md`
  (P12 + changelog), and `SKILLS/agent-delegation/04_foreman_estimation.md`.
  (Stage-1 settings pins ship from the deployer repo: update
  `ANTHROPIC_DEFAULT_OPUS_MODEL` and the top-level `model` key there if you
  maintain your own fork of the stage-1.)
- **Opus 5 behavioral calibration** (from Anthropic's "Prompting Claude
  Opus 5" guide): the charter's delegate-bias language was overshot against
  Opus 4.8's under-delegation: Opus 5 delegates readily, so a spawn-
  discipline block now bounds it (one agent when one suffices; no mid-task
  self-re-check spawns). The **completed-work review sweep is affirmed as a
  standing requirement regardless of model**: Opus 5's self-verification
  trims only duplicate mid-task re-checking, never the end-of-work reviewer
  pass.
- **Effort rules codified**: effort-decreases are the Operator's token-
  saving lever: honored without friction, never auto-restored mid-session,
  never applied autonomously by the AI, and never to review/verify lanes.
  (Opus 5 holds quality unusually well at `low`/`medium`, which is what makes
  an Operator-requested economy pass cheap.)
- **New brand-voice template section: "Client Deliverable Brand Kit"**:
  Opus-class models produce markedly better office documents (.docx/.pptx/
  .xlsx) when handed a concrete brand spec (logo, colors, fonts, section
  order, contact block) instead of "professional and clean." The template
  ships an EXAMPLE block to replace during bootstrap; found as the sole
  confirmed gap in a 16-agent audit of the prompting guide vs this harness.

## 2026-07-22: scheduled 5h-window pings (claude-window-ping.sh)

- **New `bin/claude-window-ping.sh`**: cron-fired dumb pipe that opens the
  Claude 5-hour usage window at Operator-chosen times: one headless
  MCP-stripped `ping` to a brand-new session per configured profile
  (`CC_WINDOW_PING_PROFILES`, space-separated `name=config_dir` pairs,
  default `default=$HOME/.claude`; model via `CC_WINDOW_PING_MODEL`, default
  `sonnet`). Why: when your day has predictable blocks, pre-arming the shared
  window clock means the countdown is already running when you sit down. Runs
  from `$HOME`, outside tmux (ping sessions never enter the reboot-resume
  registry). The crontab is machine-local by design: install lines live in
  the script header and `bin/README.md`.
- **`session-briefing.sh` gains a quiet-when-clean `Ping:` line**: flags a
  failed last ping (per profile, with rc) or a stale one
  (`CC_WINDOW_PING_STALE_HOURS`, default 25h) at next session start; silent
  when the feature isn't installed (no status file) or the last run was clean
  and recent. A silent ping failure means the window never opened and nobody
  was present to notice: the next session's briefing is where it gets seen.
- **Hardened for unattended cron duty (review round):** malformed profile
  pairs are skipped loud (logged + rc=2 status row) instead of silently
  pinging a garbage config dir; whitespace-only config writes a loud
  `config` rc=2 row instead of a fresh-but-empty status the briefing reads
  as clean; the missing-binary path shares the atomic tmp+mv write; a
  non-blocking flock serializes overlapping runs; tmp litter from killed
  runs is swept; per-profile timeout promoted to `CC_WINDOW_PING_TIMEOUT`
  (default 180s). **`claude-window-ping-selftest.sh`** (new) proves all of it
  against a mock binary: profile routing, rc propagation (incl. 124/127),
  malformed/empty config, lock behavior, tmp hygiene: zero real API usage.

## 2026-07-22: context-watch: escalation ladder + mid-turn injection

- **`context-watch.sh` rewritten from a single flat threshold into a 4-tier
  escalation ladder** scaled off `CC_CONTEXT_WINDOW` (default 1M): 65% NOTICE
  (re-nag +75K) / 78% WARNING (+40K) / 86% URGENT (+20K) / 92% CRITICAL (every
  stop). Crossing into a higher tier fires immediately regardless of growth,
  and the message language escalates per tier. Why: one polite nag repeated at
  a flat interval is easy for a deep-in-the-work session to defer until the
  window is gone.
- **New `posttool` mode closes the mega-turn blind spot.** Stop hooks only
  fire between turns: a long tool-calling turn can run from 65% to
  window-death without ever seeing a nag. Registered as a PostToolUse hook
  (matcher `.*`, arg `posttool`) in the Stage 1 `settings.json` template, it
  injects the warning mid-turn via `additionalContext` from 86% (+15K
  throttle, +8K at CRITICAL). **Existing copies:** hook config is
  session-cached and `settings.json` is Stage-1-owned: re-run Stage 1 (or add
  the PostToolUse entry to your `settings.json` by hand) and relaunch
  sessions to arm the mid-turn half; the ladder itself goes live immediately
  since the Stop registration already points at this script.
- **`context-watch-selftest.sh`** locks the ladder invariants (tier fires,
  throttles, escalation-overrides-throttle in BOTH modes, every-stop
  CRITICAL, loop guard, posttool injection + throttles, literal state-field
  integrity across the two write paths, post-compact epoch reset: a
  mid-session /compact shrinks context, and a stale high-water mark would
  otherwise suppress every re-nag below CRITICAL: kill switches, window
  scaling, legacy single-int state upgrade + both legacy overrides). The
  four core guarantees are mutation-verified: each selftest case fails when
  its clause is surgically removed. Fail-open like the hook: no python3 =>
  SKIP.
  Legacy `CC_COMPACT_NAG_TOKENS` / `CC_COMPACT_RENAG_TOKENS` overrides still
  honored (tier 1); `CC_CONTEXT_WATCH=0` kills all modes,
  `CC_CONTEXT_WATCH_POSTTOOL=0` the mid-turn half only.

## 2026-07-17: session-close work-tracking reconciliation gate

- **`session-close` gains a WIP & work-tracking reconciliation step** (new step
  2): before a session tears down, it reconstructs which repos the session
  touched (from a per-session start stamp + compact-time work-log, scoped by git
  delta with automation commits filtered out) and reconciles each unit of work
  against the systems the Operator declares in the new `CONTEXT/work-tracking.md`
 : logging time, advancing a board card, or **drafting the entry text** when no
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
  one-line narrative breadcrumb: so a multi-compact session's whole story
  reaches the eventual close. Pause never touches time or tickets; only
  `session-close` reconciles.
- **`session-briefing.sh`** now sources `hooklib.sh` and carries a backstop that
  flags sessions abandoned without a reconciliation run (their work may be
  unlogged).

## 2026-07-16: doctrine: token cost is not a lever against compliance

- New operating-doctrine ruling (Operator, 2026-07-06, now written down):
  never propose consolidating or trimming the always-loaded doctrine chain
  for token savings: repetition is how agents internalize a non-default
  posture; the harm is repeated contradictions, not repetition, and the
  drift checks exist to prevent exactly those. Compliance-motivated
  restructuring (worker-digest) stays fine; distinct from P12's
  workflow-spend gate.

## 2026-07-16: project-kata: GHCR retention workflow for image-publishing repos

- New kata section: any repo publishing container images to GHCR gets a
  retention workflow at scaffold time (`ghcr-cleanup.yml`, manual-first,
  `dry_run` defaulting to true, keep-last-N, `exclude-tags` for
  `latest`/`prod`/sha pins): plus the two platform gotchas learned live
  (`workflow_dispatch` only fires from the default branch; guessed package
  names 404).

## 2026-07-16: flush-debt follow-up: stub-phrased entries no longer suppressed

- `secrets-guard.sh`: the routing nudge previously stayed quiet for entries
  phrased like stubs (`folded to` / `canonical entry lives` / `pointer stub`).
  Under charter § Eviction stubs shouldn't exist: a legacy stub is flush
  debt that belongs in the queue, so the suppression is removed and such
  entries now get nudged + queued for the closeout flush.

## 2026-07-16: closeout/memory wave: memory is a write cache, arming-order gate

One-PR wave ported from a private harness under the CONTRIBUTING extraction
discipline (patterns rewritten, identity scrubbed, denylist at zero hits).

- **Memory eviction lifecycle.** `foreman-charter.md` § "Eviction: memory is
  a write cache, not an archive": auto-memory holds the working set plus a
  small set of standing facts; the long-term store is the repo (lessons
  files, docs), the cold archive is the git-synced mirror: deleting an entry
  is never data loss. Terminal projects purge their entries (fold into the
  lessons file, then delete: no stubs); `MEMORY.md` gets a ~16KB soft budget
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
  means DO NOT ARM: the automation removes the Operator's keystrokes, never
  the synthesis.
- **Also in the wave.** Migration-closeout checklist (the four vectors that
  make a fresh agent regenerate a removed pattern) in `pre-compact-synthesis`;
  the Workflow `args` trap (hardcode one-shot inputs; args can arrive
  undefined/stringified) in `agent-delegation/05_dynamic_workflows.md`;
  memory-index regeneration discipline in `memory-prune`.

## 2026-07-15: backport wave: compact automation, session-persistence hardening, portable hooks

Five-PR wave ported from a private harness under the CONTRIBUTING extraction
discipline (patterns rewritten, identity scrubbed, denylist at zero hits).

- **Automated compact cycle.** `bin/compact-cycle.sh`: a deterministic bash
  compactor in a detached tmux session: waits for the target Claude pane to go
  idle, types `/compact`, watches completion, types the resume baton, and
  self-destructs; on error/timeout it never resumes (the session stays paused
  with synthesis on disk). `hooks/context-watch.sh` (Stop hook) nags the
  ritual from REAL context tokens (transcript `usage` entries), growth-
  throttled. `pre-compact-synthesis` gains the self-compact exit: automated
  is the default in tmux; manual only when the Operator claims `/compact`.
- **Session-persistence single-owner doctrine.** The registry system is the
  only thing allowed to (re)create Claude sessions. `tmux-main.service`
  rewritten from Type=forking + Restart=on-failure (server-death cascade →
  restart → resurrection storm) to oneshot + RemainAfterExit + KillMode=process.
  Registry staleness `sweep`, case-collision guard in the auto-register hook,
  and every tmux `-t` target exact-matched (`=Name` / `=Name:`: bare names
  unique-prefix-match; `kill-session -t Dev` can kill `Dev2`).
- **Portable hooks.** `hooks/hooklib.sh` `hook_field` (jq-first, python
  fallback, fail-closed) replaces inline `python3 -c` extraction across the
  guard hooks; `guard-selftest.sh` proves the guards actually block.
- **Deploy + docs.** `deploy.ps1` profile seam (`profile.local.ps1`, never
  `$PROFILE`), dynamic backup task (static XML retired), verify gate updates;
  DEPLOYMENT.md corrected to match `deploy.ps1` reality.
- **Workforce docs.** Memory-sync doctrine lessons, `ac-memory-init.ps1`
  exit-code contract restored, project-kata delta.

## 2026-07-08: session-close skill

- `SKILLS/session-close/`: the third session ending. Pause = closeout +
  `/compact` (pre-compact-synthesis); move = session-handoff; **close** =
  full closeout synthesis, an archive-vs-forget decision, a receipt, then
  the session removes itself from the reboot registry and kills its own
  tmux. History is never deleted; archived sessions revive on demand.

## 2026-07-08: Session lifecycle: profiles, auto-register, template sync

- **Profile-aware reboot-resume.** The remote-sessions registry gains an
  optional 4th column (`CONFIG_DIR`): sessions running a secondary Claude
  Code profile (`CLAUDE_CONFIG_DIR=...`) now resume from their own
  transcript store instead of silently starting fresh. 3-column rows keep
  working untouched.
- **Auto-registration.** New SessionStart hook
  (`.claude-config/hooks/remote-session-register.sh`): any Claude session
  that starts inside tmux self-registers for reboot-resume: hand-launched
  sessions included, not just skill-created ones. Archived names stay
  parked; opt out with `RC_AUTOREGISTER=0`.
- **`harness-update` skill + scan script.** The safe update path from the
  OPS template into your private copy: fetch-only upstream remote,
  classified delta (NEW / UPDATE / CONFLICT / IDENTICAL) against a
  last-synced marker, identity surfaces hard-excluded in both directions,
  conflicts never auto-apply.

## 2026-07-08: Remote-controlled sessions (community PR #1)

- `.claude-config/remote-sessions/` + the `remote-session` skill: always-on
  Claude Code sessions in tmux, driven from another device via
  `claude --remote-control`, persisted in a registry and **resumed with full
  conversation history after a reboot** (@reboot cron + stable session ids).
  Archive/revive tooling parks sessions without losing history. Contributed
  by @kontrolflow: the first port from a sibling private harness.

## 2026-07-07: Contribution discipline

- `CONTRIBUTING.md`: contributions here are typically extractions from a
  contributor's own private harness, so the extraction discipline (port
  patterns, never paste files; denylist self-scrub; run the gates) is the
  contribution gate. Includes a verbatim porting brief to hand an AI doing
  the merge.
- `main` is now PR-protected: review required, no direct pushes, no force
  pushes.

## 2026-07-07: Initial public release

- OPS v1: foreman-by-default orchestration doctrine (P1-P15 + charter),
  git-synced file-based memory, session-survival discipline (pre-compact
  synthesis, handoff batons, post-compact re-orientation), the WORKFORCE
  fleet layer, six portable skills, two-stage deploy, and the first-launch
  `BOOTSTRAP.md` interview.
- Extracted file-by-file from a private harness with fresh git history;
  gated by an adversarial leak scan, a coherence review, a fresh-user
  cold-read audit, and the repo's own `verify-ops.sh` before the first
  commit.
