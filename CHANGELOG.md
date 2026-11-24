# Changelog

Notable changes to OPS, newest first. Format: the date, then what changed and why it
matters. This file starts fresh at the public release; the harness's private
prehistory is deliberately not part of it.

## 2026-11-24: shared systems answer to their owners

- **`core.md` says a teammate's go is not a design ruling on a system they do not own.** On a team
  box the Operator is the person the copy serves, so a build that person approved passed every
  check even when it cut across the direction of an organization repo owned by someone else (an
  alert-pipeline change built in the wrong workflow, then closed unmerged after a full session).
  Now a new path, component or overlapping mechanism in a system the Operator does not own needs
  its owner's answer first, and that case counts as a genuine fork.

## 2026-11-18: a key-safe client, a caller-bound waiter, the model-fallback flag, and honest suites

- **`mcp-http-call.py` redacts before it clips.** Five error paths sliced server text first and
  scrubbed after, so a key that straddled the cut survived as a prefix. Every piece of server
  text the client shows (error bodies, tool answers, the call preview, `list` output) now has
  every form of the key redacted (raw, and JSON-escaped once or twice), then each line break
  escaped so it stays on one line, and only then is it clipped.
- **Terminal refusals in `await-approval`, opt-in.** A server that binds each request to the
  credential that made it answers "not this caller" when the waiter polls with another key, and
  the waiter used to retry that five times as a gateway blip. A copy that lists those codes in
  the new `terminal_refusals` config ends the wait on the first such answer (exit 2,
  `state=<code>`), naming the connector, where its key came from and at most the last four
  characters, and never offers another key. A refusal is read only from structured fields (the
  envelope before its result) or from the one `NOTE:` line the client prints for it; quoted text
  never counts. The client captures the key source and suffix when it loads the credential,
  so a rotation during a poll leaves the provenance accurate. A kind's new `key_connector`
  limits the `~/.claude.json` fallback to that one entry, so one kind never lends its key to
  another. Omitted or empty `terminal_refusals` keeps
  the old behavior. The client and the waiter must ship and roll back together.
- **`hooks/model-fallback-watch.sh`, new.** When Claude Code moves a refused request to another
  model, the hook flags it once at Stop so the agent tells the Operator which work ran on the
  fallback model. It restarts a scan on a replaced transcript and repairs an unfinished ledger
  row under the lock. The Stage-1 settings already register it behind `test -x`, so a copy picks it
  up with this release. `MODEL_FALLBACK_WATCH=0` turns it off.
- **The briefing's effort line** reported the first `effortLevel` anywhere in the settings file,
  which since the Stage-1 per-model levels can be another model's. It now follows Claude Code's
  own order (env, launch flag, the saved level for this model, the model default) and labels the
  source.
- **"Did not run" is never green.** Five suites printed SKIP and exited 0 when a prerequisite was
  missing; they now exit 77 with the reason, which CI and the contributing loop count as a failure.
- **Resume text**: a DO NOT or HOLD line in a snapshot is verified against what it cites before it
  is treated as settled.
- **Remote sessions**: pane-level tmux commands target `=NAME:` instead of `=NAME`; on tmux 3.6 the
  bare form missed the pane, so the launch line was dropped and a bare shell was left. The launcher
  waits (about 5 s at most) for the new pane and reports failed tmux commands with a nonzero exit.
## 2026-11-18: effort defaults, Fable 5.2 as the second mind, and the November doctrine pass

The template's doctrine caught up with the shared Stage-1 settings and the owner's November
rulings. Where the docs said one thing and the settings did another, the settings were right.

- **Effort defaults.** `CONTEXT/core.md`, `CONTEXT/model-roles.md` and `README.md` said effort
  was `xhigh` on every model, held by a `CLAUDE_CODE_EFFORT_LEVEL` variable. The Stage-1
  settings have saved one level per model since 2026-11-16 (`high` on Opus 5.5, Sonnet 5.5 and
  Haiku 5.5, `medium` on Fable 5.2) and set no variable, because the variable outranks every
  pick, T3's picker included. The docs now say so, give Claude Code's resolution order and what
  follows for T3 threads, `delegate_task` children and native lanes, and state that the levels
  are defaults the foreman raises or lowers per lane. A Stage-1 checkout from before that date
  keeps the old values until it is updated.
- **Fable 5.2, the second mind.** Fable 5.1 (`claude-fable-5-1`, "rare") becomes Fable 5.2
  (`claude-fable-5-2`), an optional consult the foreman calls at three moments: before a
  multi-lane plan or options go out, after a miss, and for security design and conclusions.
  Advice to verify, never a reviewer or a volume worker. Its list price and the wider
  safety-refusal fallback on Fable requests are recorded in `model-roles.md`.
- **Foreman rules** (`CONTEXT/foreman.md`, still under the 8,192-byte hook limit): close loops
  in the session instead of scheduling them; a written plan review before a risky or big
  build; low-impact review findings go to Follow-ups, high ones are always fixed; every ID the
  Operator reads carries its display name and a link. Two lines that pointed at retired
  closeout skills are gone; `session-end` does that work.
- **Core** (`CONTEXT/core.md`): terse chat never drops context the Operator needs to act; what
  counts as an outward-facing send; deletes that come to the Operator are the irreversible
  ones outside a stated ruling; a fix's test is shown failing without the fix first.
- **Principles** (`CONTEXT/how-i-work.md`): the close-loops rule with its why; plan review in
  Review pickup; what a lane cannot know unless its brief says so; test count and coverage are
  never targets; a recorded real response or a dated probe for reads, parsers, error
  classifiers and security controls.
- **`AGENTS.md`**: the shared-checkout and kill-by-pattern hazards, and an "Every surface" list
  (both deployers, copies, Stage-1, T3 versions, tests, docs and the way back).
- **`ops-worker`**: an ordinary obstacle is diagnosed and worked through, and a fix shows its
  test failing first.
- **`harness` skill**: the missing `session-end finish` step (without it the closeout stamp
  never moves), the `--repo` candidates, the open asks, the close listing, and what
  `session-end` never does.

## 2026-11-18: the harness skill says how to get a file to the person

The `harness` skill's one line on `grabit` becomes a short section that picks the route by
need: show it in the thread when they only need to read it; `grabit` over Tailscale when it
must land on their computer, naming the machine with `--to` because a T3 thread has no SSH
connection for grabit to detect it from; `--serve` for large or many files; and, when
Tailscale is signed out or none of their devices is online, a link to the path in T3 rather
than another route. Receiving is covered too (an image attached in T3 is a saved path;
`grabit --queue` for a file they Taildropped).

## 2026-11-18: memory saves only what has no other home

The save rule changes from "write memory as you learn" to "memory holds only a trap with no
other home". A measurement of the memory pools found most entries repeated a doctrine line,
a repo doc or a client fact that already had a home, and pools on several boxes grew past
their caps with nobody pruning. Rulings, repo facts and client facts now go to their homes
at write time; the pool keeps the traps nothing else records. `CONTEXT/core.md` (Memory and
where knowledge goes) and the `harness` skill's closing steps say so.

## 2026-11-17: one `harness` skill replaces six

`active-minutes` bills to the nearest hundredth of an hour again (40 minutes shows 0.67 h), the owner's ruling the same day; the truncation added earlier today is reverted, so every copy reads the same.

The owner's test for a skill: it holds only what a capable agent with a fresh context could
not know (facts, house rulings, traps), and the machinery lives in hooks and scripts. With
`session-end` doing the mechanical steps of every ending, the three session skills and three
other template skills were mostly procedure. One `harness` skill, the same page on every box,
now carries the facts about the box and T3 Code.

- **Added `SKILLS/harness/`**: how a thread pauses, moves and closes (`session-end`, the
  compact line and the harness-token condition, the baton, the settle route, billing only when
  a ticket was worked), talking to the Operator, waiting, helper agents, the second-vendor
  review, and the box's guards and commands. The inline-page starter, worked example and
  palette moved with it to `SKILLS/harness/assets/` and `references/palette.md`; the T3
  frame rules (fluid width, render height, the saved-page link, theme injection) are a comment
  at the top of the starter. `tests/t3-html-render-test.py` reads the new path and now fails
  if either page is missing instead of passing with nothing checked.
- **Removed** `pre-compact-synthesis`, `session-close`, `session-handoff`, `grabit`,
  `t3-html-render` and `harness-update`. Facts that pass the test and that no command prints
  moved beside their commands: `bin/README.md` (session-end: archiving stamps by hand, the
  leftover-stamp judgment, cleanup traps, a close outside T3; compact-cycle: the manual
  `/compact` per host and its preservation text; a new `harness-update-scan.sh` section:
  classes, marker, exclusions, older and renamed copies, apply only on the Operator's word;
  grabit: receiving), `remote-sessions/README.md` ("Closing a session from inside it": the
  single name capture and the tmux traps) and `.claude-handoffs/README.md` (the flow through
  `session-end move`, the colon-free archive name, consuming a baton). Procedure the commands
  now run is dropped. A template sync never deletes, so an older copy keeps the six folders
  until its owner removes them; `SKILLS/README.md` names them so the skills-index check stays
  quiet, and `DEPLOYMENT.md` ("Leftovers from the six retired skills") says what to keep.
- **Fixed `grabit --serve-off`**: it ran `tailscale serve reset`, which removes every serve
  handler on the box and once took a box's T3 endpoint (and its phone app) offline. `--serve`
  now mounts under `/grabit` on port 443, never the root, and `--serve-off` turns off only
  that path, warning when the turn-off is refused. New `tests/grabit-test.sh` (stub
  `tailscale` and `sudo`) fails if reset is ever invoked.
- **Repointed** every hook, command and doc that named the six: `context-watch.sh` route text
  now says "run session-end pause and finish what it lists (the harness skill)" (text only),
  `session-end` prints where the by-hand archive and the tmux close are documented and, on a
  pause, that the compact line needs the box's T3 harness token, `handoff-check.sh` and the
  briefing's leftover-stamp line no longer name a skill, and `CONTEXT/core.md` "Where to look"
  routes pause, move and close to the `harness` skill and `session-end`.

## 2026-11-17: the skill mounts retire

The template mounted no skills once `SKILLS/VENDORED.tsv` lost its last row, yet the
deployers still carried the step that cloned the public `agent-skills` repo and synced
mirrors from it. The mechanism goes: the template
ships its own harness skills in `SKILLS/`, and an organization's shared skills are
delivered separately by that organization.

- **Removed**: `.claude-config/bin/skills-vendor.sh`, `SKILLS/VENDORED.tsv`, and the
  suites `tests/skills-vendor-test.sh` and `tests/deploy-skills-mount-test.sh`.
- **`deploy.sh` and `deploy.ps1`** no longer clone a skill source or sync mirrors, and
  no longer record a `skills-mount` failure. `deploy.sh` keeps its step numbers (step 2
  is now a note), because the docs and the session briefing cite steps 7 and 8;
  `deploy.ps1` renumbers its last two steps.
- **`verify-ops.sh`**: check 22 (mirror drift) is retired, its number left free;
  `skills-vendor.sh` leaves the destructive-tool list of check 24; checks 4 and 9b no
  longer read a manifest. The self-test and `deploy-windows-test.ps1` lose their
  mount cases; CI no longer installs rsync, which only the mount tests used.
- **An existing copy keeps its leftovers**, since neither deploy nor a template sync
  deletes files: the clone under `PROJECTS/`, the mirrored `SKILLS/<name>/` folders,
  `SKILLS/.vendored-state.tsv`, and any interrupted staging under `SKILLS/.vendor.*/`.
  `DEPLOYMENT.md`, "Leftovers from the skill mounts", says how to inspect them and
  preserve local work before optional removal. Staging remains gitignored so the
  daily backup does not commit it, and `verify-ops.sh` warns that the clone is
  missing from `projects-map.md` until it is gone.


## 2026-11-17: one command starts every thread ending

Pause, move and close each assembled their mechanical steps by hand from prose in three
skills, and a close assembled by hand skipped steps. `bin/session-end` runs them the same
way every time and prints what is left for the agent to judge.

- **`bin/session-end <pause|move|close>`**: snapshots git read-only, starts `branch-gc
  --apply` on the thread's repos (only those the PreCompact hook would hand to branch-gc, with
  its timeout numbers), rebuilds this directory's memory index, lints with `verify-ops.sh
  --quiet` when the thread touched `.claude-config/` or `SKILLS/`, lists the thread's open
  asks, and prints the remainder: lessons, documents, the resume note, the memory entries
  touched in the thread's window, the compact line, the baton path, or for a close the
  measured time as evidence, the objects the thread created (listed, never removed) and the
  settle route (T3's own settle tool, `t3-api.sh settle-when-idle` only as the fallback). It
  never commits, pushes, edits a ticket, logs time, writes a baton, compacts or settles. Lint
  FAILs are findings, not a failed run, because on a shared box most of them are other
  sessions'. `--dry-run` writes nothing.
  A zero lint exit still requires a clean gate summary; empty or contradictory output fails
  the receipt instead of allowing `finish` to stamp it.
- **`session-end finish [--logged N | --declined REASON]`**: after knowledge capture, advances
  `last-closeout` only when the run was real and nothing failed, and after a close moves this
  thread's two billing stamps into a fresh `~/.claude-compact-cycle/reaped/` directory by
  rename, never by copy and delete, so a late append cannot be lost. Only a T3 per-thread key
  is archived; a shared-cwd or tmux key is refused.
- **Scope**: Claude sessions only, the main thread only (a T3-delegated lane is refused, and
  `hooks/git-guard.sh` blocks a run other than `--dry-run` from a payload with an `agent_id`,
  under either `GIT_GUARD=off` hatch too, including rtk proxies and quoted executable paths;
  a dry-run flag inside a path argument, comment or redirection is not an exemption), Linux only.
- **`memory-index --pool-for [--cwd DIR] [--ops DIR]`**: prints the pool the digest would show
  and creates nothing; exit 4 means no pool.
- **Tests**: `bin/tests/session-end-test.py` (63 cases, sandboxed, every tool a recording stub,
  a sentinel tree that must survive every case), 22 new probes in `hooks/guard-selftest.sh`,
  and a `--pool-for` case in `bin/tests/memory-index-test.sh`. `verify-ops.sh` lists
  `session-end` as a destructive tool and its suite as a sandbox suite (check 24).

## 2026-11-17: the asks register and the active-minutes measure

Two small commands, both Python standard library only, each with a sandboxed suite that
CI picks up by glob.

- **`bin/asks`**: the per-thread register of what is waiting on the box's owner. A thread
  writes `asks add "<question>"` with an optional recommendation, default and deadline, and
  `asks list --all` shows every thread's open asks in one place. Console asks (steps only a
  person can do in a vendor's web console) carry their steps and paste text. State lives in
  `${OPS_STATE_DIR:-~/.local/state/ops}/asks/`. A secret-shaped value is refused, the same ask
  re-added updates instead of duplicating, and resolved asks are pruned after 14 days while
  their next numbers are retained. An unreadable register stops pruning and new adds before
  they change any asks. It is POSIX only: without `fcntl` it prints one line and exits 1.
  `asks list` and the
  `session-end` command read the register. Why: an Operator with several threads open had
  to poll each one for what it was waiting on.
- **`bin/active-minutes`**: working minutes from a Claude Code transcript, for billing a
  thread's time to a ticket. Pauses of 30 minutes or less count; longer gaps are classified
  from their evidence and listed with the cause, so a hold or an overnight stop is never billed
  silently. It is generic by option: `--time-tool NAME` names the ticketing system's time-entry
  tool for the hook mode (default any tool ending in `time_manage`), and `--zone NAME` sets the
  display zone (default `$TZ`, then the machine's zone, then UTC), converted per timestamp so a
  daylight-saving change cannot shift a printed window. A named zone with no zone database
  prints one line and exits 2.
  The billing display truncates decimal hours instead of rounding up, and a time-create call
  without a ticket or with an explicit error result does not reset the unlogged window.
- **Tests**: `bin/tests/asks-test.py` and `bin/tests/active-minutes-test.py`, unittest, no
  pytest. The second exits non-zero on a failure and a case proves it cannot pass without
  running a test. `asks-test.py` starts with the sandbox guard; the secret-refusal case builds
  its private-key header from parts so `secrets-scan.sh` and gitleaks see no key. Both are
  documented in `bin/README.md`.

## 2026-11-17: skills hold facts, not procedure; twelve template skills retire

The owner cut the skill set with one test: a skill holds only what a capable agent with
a fresh context could not know (this copy's systems, house standards), never procedure.
Rules moved into doctrine, repo facts into the docs beside the code, and steps into
scripts. Why: most skills restated what a current model already does, and every
description costs listing space a live skill needs.

### Skills

- **Removed from `SKILLS/`**: `grabit-screenshots`, `remote-session`, `projects-map`,
  `harness-deploy`, `harness-readme`, `design-method`, `operating-model`, `stewardship`,
  `machines`, `project-kata`, `memory-prune` and `operator-voice`. The context files
  the thin ones pointed at stay, and the core's "Where to look" table names them
  directly. `memory-prune`'s inventory and its test go with it; the thread that closes
  prunes the memory it touched.
- **`SKILLS/VENDORED.tsv` ships no rows.** Its nine rows mounted the public
  `Exploitacious/agent-skills` set (`delegation-sizing`, `briefing-subagents`,
  `worktree-isolation`, `verifying-delegated-output`, `dynamic-workflows`,
  `meta-skill-creator`, `grill-me`, `tdd`, `diagnosing-bugs`). A shared skill lives in
  exactly one repo, and a template copy of a same-named skill blocks the shared one.
  The mount mechanism itself (`skills-vendor.sh`, the deploy clone step) is unchanged
  here.
- `pre-compact-synthesis`, `session-close`, `session-handoff`, `grabit`,
  `t3-html-render` and `harness-update` stay for now. `grabit` now carries the receive
  facts `grabit-screenshots` held.

### Doctrine

- **`CONTEXT/core.md`**: the header says skills hold facts, not procedure. New lines:
  tell an empty read from a failed one before a step that deletes, closes or prunes on
  absence; the `ponytail:` shortcut tag (older copies used `shortcut:`); every id
  carries its name and a link; a row that changes money or a client record says which
  values were read and which inferred; anything longer than a chat reply gets the
  AI-tells catalog; writing as a person follows that person's own voice file; this
  writing style is the template's default and each copy's owner may change theirs; the
  skill-routing test (a client fact to the documentation system, a repo fact to the
  repo, a behavior rule to doctrine, a mechanical step to a script or tool, and only
  the rest becomes a skill); and the self-built-tools line, which replaces the
  pointer to `stewardship`.
- **`CONTEXT/ai-tells.md`** (new): the AI-tells catalog, kept whole as a doctrine
  reference with its upstream MIT notice (it was `operating-model`'s
  `references/patterns.md`).
- **`CONTEXT/foreman.md`**: intake interviews a request in rounds until no decision is
  open (replacing the `grill-me` pointer); the delegation skills' pointer goes to P8
  and P12.
- **`CONTEXT/how-i-work.md`**: the intake, delegation and brief lines lose their skill
  pointers; P5 names the catalog; "Client documents that ask for decisions"
  (decisions last), which `operator-voice` carried, is now a template default under
  "Output and files".
- **`CONTEXT/voice.md`** (template) says how it is used without a skill.

### Docs and checks

- `README.md`, `SKILLS/README.md`, `SKILLS/THIRD_PARTY_NOTICES.md` (now one source),
  `BOOTSTRAP.md`, `DEPLOYMENT.md`, `CONTRIBUTING.md`, `.claude-memory/README.md`,
  `.claude-config/bin/README.md`, `.claude-config/remote-sessions/README.md` (which
  takes the facts the `remote-session` skill held) and the `harness-audit` workflow no
  longer name the removed skills.
- `verify-ops.sh` memory warnings and the `memory-index` pool-cap warning say "prune
  the pool" instead of naming `memory-prune`. `ci-gate-test.py` checks a shipped
  workflow script in place of the removed `audit_workflow.js`. `wf-resume-test.sh` drops
  its case for a mounted `dynamic-workflows` prelude, which always skipped once nothing
  mounts it.


## 2026-11-17: a T3 thread on a box with a harness token compacts itself

A T3 thread on a box with a harness token compacts itself; everything else stays manual.
This reverses the 2026-10-19 line "No session self-compacts" for that one case. That entry
retired a tmux typer that could not tell a finished compaction from a failed one; the new
cycle asks T3 itself, through its orchestration API, whether the compaction it requested
completed, and sends the resume baton only then. Why: a long autonomous T3 thread had to
wait for the Operator to type `/compact` at every rest stop, and the API now carries the
proof the old typer lacked.

### Scripts

- **`bin/t3-api.sh`**, with **`bin/lib/t3_api_v2.py`** and **`bin/lib/t3_ws.py`**: the
  T3 orchestration client. It speaks T3 0.1.0's protocol 2 (writes are one
  `dispatchCommand` over a WebSocket) and the older protocol 1, refuses an HTML or
  non-JSON answer (exit 6), refuses `archive` and raw `dispatch` on protocol 2 (exit 7),
  and settles a thread only when it is idle, queued runs, pending requests and
  background work included (exit 9). Its guards refuse a slash text other than an exact
  `/compact` and any message to an archived thread (exit 10). The token stays in its
  file and a request header: never argv, output or logs.
- **`bin/compact-cycle.sh`**: waits for the thread to go idle, sends `/compact`, waits
  for T3 to report that exact request's compaction complete, then sends the baton
  (queued behind any run the compaction woke). Any failure sends nothing more and
  keeps the baton. Known limit: the target must be a top-level thread; a T3 delegated
  child thread stops with `ERR_TARGET` (exit 3).

### Hooks

- **`context-watch.sh` names the cycle only where it can work**: a T3 session (not a
  tmux pane) on Linux whose box has both scripts and a readable, non-empty token file
  (`~/.config/ops/t3-harness.token`, `OPS_T3_TOKEN_FILE`). Its nags then say: synthesis,
  write the baton, run `compact-cycle.sh` on this thread, end the turn; while a fresh
  baton for the thread exists it stays silent. Everywhere else (no token, not T3,
  Windows, a script missing, a delegated child thread) the route is unchanged, the
  Operator's `/compact`, and no compactor command is named: a command that can only
  exit 3 for want of a token would turn the nag into a loop.

### Setup and tests

- **The token is per box and not issued by deploy.** `DEPLOYMENT.md`, "T3 Code hosts",
  has the issue command (scopes `orchestration:read` and `orchestration:operate`), the
  path, owner and mode, and how to turn the route off (remove the file). Unverified:
  that those two scopes cover `thread.settle` on a freshly issued token.
- **Three suites, sandboxed and loopback only**: `t3-api-test.sh`,
  `t3-api-v2-safety-test.py` and `compact-cycle-t3-test.sh` run against stubs and the
  recorded frames in `bin/tests/fixtures/t3-v2/`. Each starts with the sandbox guard and
  refuses to run unless loopback is its only interface and T3 Code's default port
  refuses; `verify-ops.sh` check 24 now lists them in `OPS_SANDBOX_SUITES`, and its
  self-test fixture carries them. `context-watch-selftest.sh` replaces the case that
  failed any compactor nag with cases for each situation above.

## 2026-11-16: operator-voice says when it has no voice to use

`operator-voice` fell back to plain prose when no voice was configured, but it named only
an absent file, so a `CONTEXT/voice.md` still holding the template read as a configured
voice, and a draft could look personal while being generic. It now treats the template
(its opening says it has not been filled in) the same as an absent file, and says so in one
line above the draft. A voice kept under another file name is mentioned in that line instead
of being guessed at. Why: a usage review found the skill loaded often on boxes where the voice
slot was the template or missing.

## 2026-11-10: the session briefing lists the asks waiting on a team box's owner

For teams whose boxes run a local ask router (`~/.local/bin/team-ask`): when a teammate's
agent asks something only the box's owner can decide, the router opens an investigation
thread on the owner's box. That thread is the first surface; if it fails to open, or
nobody reads it, the ask went silent. This change adds the second surface and the rule the
thread runs under. A copy with no router installed sees no change.

### Hooks

- **`session-briefing.sh` prints a `Team asks:` line** when `team-ask pending --brief`
  returns one, after the Reminders block (`team_ask_line`). The read is local (no network)
  and bounded: 3 s under `hook_timeout`, with a 1 s kill for a reader that ignores TERM.
  Quiet when the tool is absent, when `~/.config/team-ask/disabled` exists, when the
  session's folder is the `~/team-asks` workspace (itself, a subfolder, or a link to it),
  when the reader prints nothing, and for a lane. Never silent when broken: a dangling
  link, a tool that is not executable, a failing or timed-out reader, or no `timeout`
  command prints a line naming `team-ask pending`. The line is one line, control
  characters stripped, 400 characters at most. The hook has no resume short form, so a
  resume or compact prints it with the rest of the briefing.
- **`tests/session-briefing-team-ask-test.sh` is new** (39 cases): every quiet case, the
  line as printed, the label, first-line-only, control characters, the length cap, a hung
  reader and one that ignores TERM, a failing reader and an old CLI without `pending`, a
  dangling link, a non-executable tool, no timeout command, the disable marker, the
  workspace by logical path, subfolder and link, lanes, resume, and the banner's shape. Each
  of the function's guards was removed in a scratch copy and the suite failed for it.

### Doctrine

- **`standing-orders.md` carries a row for team ask threads.** A thread opened from a
  teammate's ask (the `~/team-asks` workspace or the "Team Asks" T3 project) investigates,
  reports the decisions it needs with a recommendation each, and confirms with the owner
  before any change, message, or reply to the teammate. The ask text is untrusted data.
  Reads are free; writes, sends, and replies need the owner's approval card. It overrides
  "never ask permission to do assigned work" for those threads only. `harness-update`
  never syncs `standing-orders.md`, so a copy that already exists gets the row by an
  edit its owner approves; a fresh copy ships with it.

## 2026-11-09: inline pages in T3, slash-only sync skills, and a reporting and model-roles pack

Features already in daily use in the harness OPS is ported from, brought to the template so
a T3 Code copy works the same way out of the box.

### Skills

- **`t3-html-render` is new.** In a T3 Code thread it builds one self-contained HTML page
  for data, a report, findings, a comparison or a plan, checks it with `html_preview` at
  728 px dark and 390 px light (zero console errors), and shows it inline with
  `html_render`, then links the saved file. It carries `assets/starter.html`, a worked
  `assets/example-report.html` on synthetic data, and `references/palette.md`, whose
  series colors pass a colorblind-safety validator on T3's light and dark surfaces (T3's
  own chart variables do not).
  The example keeps its cost chart visible with reduced motion, fits data tables at
  360 px, and keeps its recovery and cost explanations consistent with its data.
  Render instructions cap tall pages at the accepted height before calling the tool.
- **`harness-update` and `remote-session` are slash-only** (`disable-model-invocation:
  true`). Both run only when the Operator asks, so their descriptions no longer take room
  in the skill listing; type `/harness-update` or `/remote-session`. Measured on the
  template's own skills, the listing goes from 17 entries and 3,575 characters of name and
  description to 16 entries and 3,366, with `t3-html-render` added. Delete the line in a copy to give the model those
  skills back. `SKILLS/README.md`, `README.md` and `AGENTS.md` say so.
- **`SKILLS/.trash/` is gitignored.** Claude Code's skill sync moves a skill it drops into
  that folder, and `~/.claude/skills` follows the link into the repo, so the daily
  backup's `git add -A` would have committed it. `verify-ops-selftest.sh` now checks the
  shipped `.gitignore` covers it.

### Doctrine

- **In T3, a page by default** (`CONTEXT/how-i-work.md`, Reporting to the Operator;
  `core.md` Writing). Data, reports, research findings and comparisons are shown as an
  inline page without asking first, on the turns where a picture reads faster than prose.
  It replaces "offer a page and wait for a yes", which held a format the reader wants by
  default behind a question; outside T3, where no inline page exists, the offer stays.
  BOOTSTRAP Round E offers the choice.
- **Reporting.** At most two or three questions in a decision report, in prose rather
  than a decision table; the agent takes and logs the other calls. When the next move is
  the Operator's, the reply carries the whole procedure inline, never a pointer to a file.
- **Verify after any deploy** (Quality standards): read the change back and exercise the
  changed path; a third-party update you take is a deploy too.
- **Lanes and resources are used freely with a clear purpose** (P11, `core.md` Intake).
  Spend with no purpose still goes to the Operator, and "one capable lane beats three"
  stays the cost rule.
- **Lanes never run `session-close`** (`core.md` Rhythm): a lane inherits the foreman's
  session id, so a close run from a lane settles the foreman's session.
- **T3 wake-ups** (Hosted inside T3 Code): timers stay under about 115 minutes; a wake
  further out, or one that must fire with no turn active, goes through T3's
  `schedule_task`, with structured schedule shapes, UTC `nextRunAt`, and native
  one-off triggers when available (a repeating-task fallback deletes itself).
- **`model-roles.md`.** Opus 5.5's price and the API behavior that touches the harness;
  Sonnet 5.5's catalog figures and its overturn condition; Haiku 5.5's 100K price step,
  where it runs and where it never does, how Stage-1 holds the 100K ceiling and what
  would break it; Fable's cost in plain figures; and the T3 Code picker settings
  (`customModels`, `hiddenModels`).
  Catalog facts carry dated primary sources; Sonnet's API effort default is `high`,
  while Claude Code's is `medium`.

## 2026-11-07: foreman doctrine split out, lane-aware boots, a memory loader, stricter guards, and a deploy that offers instead of removing

Every lane paid on every turn for core rules that bound only the main thread, lanes kept
tripping the same few shell refusals, and a copy on the current Stage-1 settings (which
turn Claude Code's native auto-memory off) started each session with no memory loaded at
all. This release splits the foreman's rules into their own file, teaches the boot hooks
which session is a lane, ships the memory loader those settings expect, adds a conflict
marker warning and closes several parser fail-opens in the git guard, and writes down the
rule that the template adds and offers but never takes away what a copy's owner chose. Upgrading a
copy older than this release: `DEPLOYMENT.md`, "Upgrading from a copy older than
2026-11-07".

### Doctrine

- **`CONTEXT/foreman.md` is new, and `core.md` is smaller.** `core.md` keeps what binds
  every session and lane (role, landing, models, writing, memory routing, where to look)
  and drops to about 11 KB. Intake, reporting, orchestration, review and merge, model
  choice, rhythm and context-file ownership moved to `foreman.md` (at most 8,192 bytes),
  which the new `foreman-context.sh` hook prints into foreman sessions only, at start,
  resume, clear and compact. A lane never receives it. If the block is missing, `core.md`
  tells a main thread to read the file itself.
- **The template and a copy's owner** (`CONTEXT/how-i-work.md`). A template change that
  would delete, cap or block an owner's content (a plugin, a memory pool's size, a retired
  skill, a hook, a model pin, a remote, a backup) ships as a warning or an offer, never a
  FAIL, a block or an automatic removal. Only an unsafe thing is overruled, and the rule
  names each one: a literal credential in a tracked file, a push of private content to a
  public origin, and the git guard's brakes on destructive git commands. One stated
  exception: the drift gate still FAILs on a banned or retired model id (checks 15 and
  15b), and that FAIL edits nothing.
- **Principles.** A written time comes from the clock (P3). Two credential shortcuts are
  out (P6): sourcing or evaluating a decrypted file into the shell, and shredding a fresh
  credential in an unconditional cleanup tail.
- **Models** (`CONTEXT/model-roles.md`). A refutation pass defaults to the Sonnet auditor,
  with Opus 5.5 kept for a high-criticality claim set and the reason in the brief. Nobody
  is required to have Fable. Pins are the owner's: deploy and `harness-update` never edit
  them, and the gate's FAIL on a banned or retired id edits nothing.
- `PROJECTS/projects-map.md` gains an optional, generic ticket-workspace row.

### Lanes

- **`bin/lane-class`** answers `foreman`, `t3-lane` or `agent-lane` for a hook payload in
  well under 300 ms, and anything it cannot resolve is `foreman`. `OPS_LANE_CLASS` forces
  an answer.
- **`hooks/lane-rules.sh`** gives every lane six shell rules at start (SubagentStart, and
  SessionStart for a T3 lane): wait with `await` instead of sleep-then-check, one simple
  command per call in an isolated worktree, no kill by pattern, the tool is `Bash`,
  re-select a deferred tool after a compaction, and check a variable path before `rm -rf`.
  The `ops-worker`, `ops-investigator` and `ops-auditor` agents carry the same block, and
  `tests/lane-rules-test.sh` fails when the copies differ.
- **`bin/await`** waits for a command, a PID or a file inside one ordinary call (exit 0,
  or 124 at the deadline). **`bin/safe-pkill`** and **`safe-pgrep`** leave the caller's own
  process chain out of the match; `safe-pkill --install-shims` places them over `pkill`
  and `pgrep` only when you run it by hand, and deploy never does.
- **Quieter hooks for lanes.** `context-watch.sh` says nothing on Stop or in its readout to
  a lane and gives a T3 lane its own 60% and 80% lines; `session-briefing.sh` prints one
  line for a lane and starts nothing. The briefing also names a parked or behind main
  checkout of the current project. Large tool responses cannot silence the context
  warning by overflowing an environment variable.
- **Per-thread work keys under T3 Code.** The work key is `t3-<session id>`, stable across
  compaction and resume, so two threads in one directory keep separate stamps and work
  logs.
- **Behavior change: leftover session stamps are judged by evidence.** The scan runs
  detached from the boot path, at most every 30 minutes, and flags a leftover stamp only
  when real commits landed in its window; an idle leftover no longer reads as abandoned
  work. A failed history read reports an error and keeps the previous flags. It never
  removes or moves a stamp. Empty (including index-only), throwaway and T3 scratch memory
  pools are no longer called unadopted.

### Memory

- **`hooks/memory-digest.sh` loads the pools when native auto-memory is off.** With
  `autoMemoryEnabled: false` (the current Stage-1 settings) Claude Code loads no memory, so
  until now such a copy started every session without one. The hook prints a digest of
  this directory's pool and the root pool's cross-project entries at start, resume, clear
  and compact: at most 9,000 characters, pinned entries first, then user and feedback
  entries, then the rest, names only past the budget. With native auto-memory on it prints
  nothing; `MEMORY_DIGEST=1` or `0` forces it.
- **`hooks/memory-hint.sh`** adds up to three relevant memory lines to a prompt that
  strongly matches them, and stays silent for harness messages and lanes. A failure is one
  line in `${OPS_STATE_DIR:-~/.local/state/ops}/memory-hint.log`.
- **`bin/memory-index`** gains `--digest`, `--hint`, `--find` and `--digest-fit`. A pool
  over 60 entries draws a warning and nothing else. **`memory-init`** makes no pool for a
  scratch directory or an empty memory dir, and `memory-init --set-host-key <key>` lets a
  second machine or login share the first one's pools (`~/.config/ops/memory-host`, one
  strict rule shared by three readers).
- `verify-ops` check 6 measures whether each pool fits the digest and 6b counts entries;
  both WARN, and FAIL only when the indexer cannot run. Pool `MEMORY.md` indexes merge with
  the union driver, so two machines sharing a pool no longer stop a rebase.
- The `memory-prune` skill gains a deletion rule (nothing whose content has not landed
  elsewhere is evicted without sign-off) and its inventory reports an unreadable pool as
  UNMEASURED instead of EMPTY.

### Compaction and reports

- **Deferred tools come back after a compaction.** `pre-compact.sh` records the deferred
  tools used since the last compaction, and `post-compact-resume.sh` lists them, most
  recent first, to re-select one at a time just before use.
- **`hooks/report-lint.sh`** (Stop) blocks a foreman's final message once when it asks the
  Operator more than three things, carries a decision table, or names things only by ID,
  and asks for an ask card instead. `REPORT_LINT=0` turns it off; `REPORT_LINT_MAX_ASKS`
  and `REPORT_LINT_TICKET_RE` tune it.
- **`hooks/askuser-cancel.sh`** tells the agent that a question card cancelled by an
  arriving message is not the Operator's answer. `ASKUSER_CANCEL=0` turns it off.
- `pre-compact-synthesis` gains the ask card (its rules in `ask-card.md`), a wake for every
  timed promise, clock-stamped anchors and a cleanup step; `self-compact-cycle.md` treats
  the completion record alone as proof of a compact. `session-close` cleans up after
  itself and cross-checks the repos it touched from the session transcript.

### Guards

- **git-guard warns when a commit would record merge conflict markers**, checking the
  staged diff plus whatever the same call stages, with `--amend` and the `--continue`
  forms. It never blocks the commit: a commit is the owner's content, and a marker is a
  mistake to fix, not a danger. The warning, or a note that the check could not finish,
  reaches Claude as PreToolUse context. It skips the check without Python 3, and
  `GIT_GUARD=off` skips it for one command.
- **The push gate's parser reads more shell.** A NUL or escape inside `$'...'`, `git` split
  by quotes or backslashes, and a `case` inside `$(...)` each let a push from a copy pass
  unchecked before; all are refused now.
- **secrets-guard blocks a write it cannot scan** (no JSON parser, unreadable input, a
  field it cannot extract) instead of allowing it. `secrets-scan.sh` exits 2 when grep
  could not scan a line, read a file or finish a directory walk, and `verify-ops` check 8
  reports that apart from a found secret.
- `guard-selftest.sh --quick` runs the core probes; `deploy.ps1` uses it and says the
  probes are running first, and Git Bash skips the link-based probes. The self-test builds
  its fake private-key header at run time, so CI's history scan reads no key block in it;
  `.gitleaksignore` lists the one earlier commit that wrote the header out.

### Tools

- **`bin/mcp-http-call.py`** is a standard-library MCP-over-HTTP client (list, call, batch;
  one session per run), with the endpoint and key variable from configuration. It refuses
  redirects and any URL that is not http or https. **`bin/await-approval`** is a
  configuration-driven waiter built on it. The waiter preserves refusals when unwrapping
  a status record and masks credentials and URLs in every result field. A batch marks a
  gateway failure or unreadable reply as an unknown write outcome, requiring a readback
  before retrying. Failed permission changes refuse output rather than silently leaving
  a less restrictive file mode, and on Windows, where mode bits are not an owner-only
  ACL, an out file is refused before any call is sent (printing the result still works).
- **`bin/wf-resume`** lists a workflow's lanes that never returned, in local time
  (`WF_RESUME_TZ`).

### Deploy and gates

- **Behavior change: deploy no longer uninstalls the caveman and ponytail plugins.** Step 9
  reports each one it finds and prints the command that removes it; keeping one is the
  owner's call. A plugin declared in `settings.json` is pointed at Stage 1.
- `verify-ops` check 9b WARNs on a `SKILL.md` over 16 KB or with a line over 1,500
  characters, and check 5 no longer reads a tracker project number as a principle
  citation.
- CI and the local test loop now also run hook suites named `hooks/*-test.py`.
- Skills: notes on how a mount is pinned and how to trim the skill listing, a narrower
  `grabit` trigger, a decisions-last order for client documents in `operator-voice`, and
  ticket threads that file a tool defect instead of fixing it in `stewardship`.

## 2026-11-06: a copy with no git remote keeps its nightly job

The 2026-11-05 change below stopped deploy from scheduling the nightly job on a copy with
no `origin` remote, which also cost that copy the job's nightly project pull and
`branch-gc --apply`. The job is scheduled on every copy again, and `daily-sync.sh` is now
the one place that decides what a copy with no origin does: it commits the day's work as
always, then logs `OPS: INFO no origin remote: the day's commit is kept locally; nothing
pulled or pushed` (or `no local changes to commit` on a clean day) instead of an error, and
the project and branch-gc stages run as on any copy. "No origin" is read from the local
config (`git remote` lists no `origin`), so an origin that exists but cannot be reached is
still a failed pull and an `ERROR`, and a `git remote` that fails is an `ERROR` too. The
session briefing reads the INFO line as `Backup:  local only (no origin remote)`, neither a
failure nor quiet; an `ERROR` or `WARN` in the same run still wins. `deploy.sh` and
`deploy.ps1` no longer look at the remotes, so their no-remote messages are gone; a copy
deployed on 2026-11-05 without an origin gets its job back on the next `deploy.sh` run. Kept
from that change: its deploy test harnesses (now asserting the job is scheduled with and
without an origin, and that the cron and task blocks run no git) and the `deploy.sh --help`
fix. Tests: `daily-sync-test.sh` (no origin, dirty and clean days, a remote named
`upstream`, an unreachable origin, an origin with only a push URL, a failing `git remote`),
`deploy-cron-test.sh`, `deploy-windows-test.ps1` and `session-briefing-backup-test.sh`.

## 2026-11-05: a copy with no git remote does not schedule the nightly backup

Superseded by the 2026-11-06 entry above: the job is scheduled on every copy again.

OPS works without GitHub, but deploy installed the nightly backup on every run. With no
`origin` remote its OPS stage logged `'origin' does not appear to be a git repository` each
night, and the session briefing then showed `Backup: ... did not finish clean` in every
session. `deploy.sh` and `deploy.ps1` now schedule the job (the user cron entry, the `OPS
Daily Backup` task) only when the OPS repo has an `origin` remote. With none they print `No
git remote: the nightly backup is not scheduled. Add a GitHub remote (DEPLOYMENT.md), then
rerun deploy.` and go on; that is not a failure. An entry or task that already exists is
never touched (a warning names the fix when there is no remote), and `daily-sync.sh` is
unchanged, so a copy with a remote that cannot push still reports loudly. Note that the job
also runs the nightly project pull and `branch-gc --apply`: a copy with no remote runs those
by hand (README, "The daily backup"). `tests/deploy-cron-test.sh` covers deploy.sh (origin:
installed once; none, another remote name or no repository: nothing written and the line
printed; an existing entry byte-identical with and without an origin), and
`tests/deploy-windows-test.ps1` covers the same rules for the scheduled task. `deploy.sh
--help` also prints its last two header lines again.

## 2026-11-05: synced org skills stay out of your OPS repo

Claude Code syncs claude.ai org and Anthropic skills into `~/.claude/skills/synced`, and
`deploy.sh` links `~/.claude/skills` to `SKILLS/`, so those skills landed in `SKILLS/synced/`.
Nothing ignored them, and the daily backup's `git add -A` committed them to each owner's OPS
repo. `.gitignore` now ignores `SKILLS/synced/`. `verify-ops` check 9 skips that directory in
the README index and WARNs, with the untrack command, when a copy is already committed
(ignoring a path does not untrack files already in the repo). `verify-ops-selftest` case 26
covers all three.

## 2026-10-19: one always-loaded core, private-only pushes, lane-aware hooks, the sandbox, and a CI gate

OPS booted through a foreman charter and an identity digest that a `claude()`
shell function appended to the system prompt. Only launches typed into an
interactive shell ran that function, so a T3 Code thread, an IDE session, or
`claude -p` started with none of the doctrine. The hooks assumed one 1M window
for every caller and still told sessions to self-compact through a tmux typer
that cannot exist under T3 Code. OPS also had no rule on where destructive
tests run, no landing tooling, and no CI. This release replaces the boot
with one always-loaded file, moves the identity layer to files the template
sync never touches, retires the multi-agent fleet, keeps every automatic push
on a private origin, ports the lane-aware hooks, branch cleanup, sandbox and
review split from the maintainer's private harness, and closes with a docs
pass, third-party notices and a CI gate. Existing copies migrate by hand once:
`DEPLOYMENT.md` § "Migrating to the core boot".

### Boot and doctrine

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

### Hooks and compaction

- **Lanes are sized by their own model.** `context-watch.sh` treats a hook call
  carrying `agent_id` as a sub-agent lane: it reads the lane's own transcript,
  sizes the window from the lane's model (1M for the current Opus, Sonnet and
  Fable ids, 200K for the 4.6 and Haiku 4.5 ids, one 95K backstop under Haiku
  5.5's 100K ceiling), and speaks only mid-turn, a reminder at 60% and a
  wrap-up at 80%. Before, every lane got the main session's ladder read from
  the main transcript, so a lane of a busy foreman was told to compact at once.
  The agent definitions carry the lane return contract.
- **No session self-compacts.** `bin/compact-cycle.sh` is deleted: it typed
  `/compact` into a tmux pane and could not tell a finished compaction from a
  failed one. Every nag now routes to `pre-compact-synthesis` and then the
  Operator's `/compact`; sessions in tmux or herdr are run by hand.

### Pushes stay on a private origin

Your copy holds your memory and notes, so every push of it meets one gate.

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
- **The push gate needs its own verdict, not just exit 0.** `daily-sync.sh`
  and `memory-init` counted exit 0 from `bash origin-private-check` as
  verified, and an empty file or one cut off after its function definitions
  also exits 0, so an interrupted update or a full disk turned the gate into a
  pass. Both now also require the gate's last line to be its `private`
  verdict, and `memory-init.ps1` checks its twin's reason the same way. The
  gate normalizes a URL before the template check (surrounding whitespace and
  quotes trimmed, host and path percent-decoded, repeated slashes and dot
  segments collapsed, a trailing dot dropped from the host or the ssh
  HostName): those forms read as unparseable, which the `ops.pushVerified`
  opt-in turned into a pass while git still reached the template. A push URL
  list with no usable entry (a lone CR) exits 2 even with the opt-in; it
  printed an empty `private:` and exited 0. A `gh` answer is compared without
  case, as the PowerShell twin does. New cases in
  `origin-private-check-test.sh`, `daily-sync-test.sh`, `memory-init-test.sh`
  and `memory-init-windows-test.ps1`.
- **Agents push memory and batons only to a private origin.** The
  pre-compact-synthesis and session-handoff skills run `origin-private-check`
  before their additive-sync push, the same gate `memory-init` and the daily
  backup use.
- **Agent pushes of the OPS copy go through the push gate.** The skills and
  `AGENTS.md` told agents to commit and push batons, the memory mirror and
  trunk work, and only prose asked them to run `origin-private-check` first,
  so a copy with a public origin could be published by any session that
  skipped a step. `hooks/git-guard.sh` now resolves the repo each `git push`
  acts on (the cwd, `cd`, `git -C`, `--git-dir`, `env`/`rtk`/`sudo` prefixes,
  `bash -c`, `eval`, git aliases) and, for a repo whose root holds
  `.claude-config/bin/origin-private-check`, blocks the push unless that gate
  proves origin private and the push goes to origin. Pushes in other repos,
  such as the project clones, are untouched; `GIT_GUARD=off` still lifts it.
  Without Python 3 it checks every directory the command names instead. The
  session-handoff, session-close and self-compact docs, the handoff README,
  `AGENTS.md` and `core.md` now say so. New `guard-selftest.sh` cases.
- **A redirect after a push is not its remote.** The push gate read the
  first word after `git push` as the remote, so `git push 2>&1`, `1>&2`,
  `>&2`, `&>/dev/null` and the like were blocked on a verified-private copy
  ("goes to '2', not origin"). Redirections and their fd numbers are now
  dropped before the arguments are read. New `guard-selftest.sh` cases run
  each form against a private copy (allowed) and the template (blocked).
- **The push gate refuses settings that move a push.** `git -c
  remote.origin.pushurl=...` (or `remote.pushDefault`, `url.*.pushInsteadOf`,
  `push.*`, `branch.<b>.remote` or `.pushRemote`, the same through
  `--config-env` or `GIT_CONFIG_*`) sent a push elsewhere while the gate
  checked only the configured origin. On an OPS copy such a push is now
  blocked with the setting named, as is a push in the same command as a
  change to where pushes go (`git remote set-url`, `git config remote.*`,
  `git config ops.pushVerified`), whose verdict would be stale.
- **The hook never runs code the command chose.** Its alias lookup ran `git`
  with the command's own environment, so `PATH=<dir>:$PATH git <word>` or an
  `LD_PRELOAD` made the hook execute a binary or library before the command
  was allowed. The lookup now uses the `git` on the hook's own PATH, with the
  hook's environment, and reads only `git config --get`.
- **More push forms reach the gate.** `--git-dir`, `GIT_DIR` (also exported
  earlier in the command) and `--work-tree` resolve to the repo git acts on,
  not the cwd; here-strings, `... | bash` and `cat <<EOF | bash` are parsed
  as scripts; `$(...)` and backticks are parsed inside double quotes too;
  `git send-pack`, `http-push`, `subtree push` and `lfs push` on an OPS copy
  are blocked; `rtk run|err|summary|test|bypass|proxy` are unwrapped;
  `bash --norc -c` and `--rcfile` no longer hide the `-c` body; `cd -`, `cd`
  chains and variables assigned in the command resolve; `git -C` resolves
  symlinks physically, as git does; a linked worktree whose checkout lacks
  the gate uses its main copy's gate.
- **The fallback fails safe.** Without Python 3, on a command that cannot
  be tokenized, or when a directory cannot be resolved (a loop variable, an
  `xargs -I{}` placeholder), the hook now reads the raw command with its
  quotes: a push or send-pack word, or one of the copy's push aliases, runs
  the gate of every OPS copy the command touches. It used to match only
  `git` at a command position in the quote-stripped text, so `bash -c`,
  `eval`, `timeout`, `xargs`, `{ }` and `if` forms pushed unchecked.
- **The push gate's limits are written down.** The hook header and
  `DEPLOYMENT.md` say what it is: a seatbelt for normal agent pushes, not a
  sandbox. Exotic wrappers (`setsid`, `find -exec`, `ssh`, `python -c`) and
  scripts run from a file are not parsed; the real protection is a private
  origin. `CONTRIBUTING.md` explains that the template's own checkout is an
  OPS copy with a public origin, so a contributor pushes a PR branch with
  `GIT_GUARD=off git push origin <branch>` after checking it carries no
  private content.
- **The gate answers inside the hook's time.** `origin-private-check` gave
  `gh` 30 s, the same 30 s the harness gives the git-guard hook, so a hung
  `gh` timed the hook out before the agent saw why. `gh` now gets 10 s. New
  case in `origin-private-check-test.sh`.

### Backups

- **The daily backup never moves the Operator's work.** `daily-sync.sh`
  stashed the tree, pulled, then popped: a run killed between stash and pop
  (a cron timeout, a reboot) left the work in a stash that later runs never
  mentioned, and stash and pop dropped empty directories and reset file
  modes on every dirty day. It now commits the day's work where it stands,
  then runs `git pull --rebase --no-autostash`; a failed pull aborts the
  rebase so the local commit and the tree stay exactly as they were, and is
  logged as an ERROR. A rebase over a remote that moved re-creates the day's
  files at default modes (git keeps only the exec bit), so their permission
  bits are recorded before the pull and put back after it. A rebase left in
  progress is reported, never committed on top of. New cases in
  `daily-sync-test.sh`: the tree byte for byte (modes and empty directories)
  after an unreachable origin, a conflicting rebase and a killed run, no
  stash ever created, and modes kept through a rebase.
- **Backups that cannot happen say so.** The daily backup checks its commit:
  a failed commit (no git identity, a hook) or a failed stash is logged as an
  ERROR with the fix, and nothing is pushed or reported as backed up; before,
  the log claimed a backup that did not exist. A new memory pool gets a
  `.gitkeep`, because the backup's `git stash -u` dropped the empty directory
  and left the memory link dangling; `memory-init` also recreates a pool an
  earlier backup removed, and commits only the pool path. A failed crontab
  install now fails the deploy.
- **A failed backup pull puts the work back.** When `git pull --rebase`
  failed (offline, no credentials under cron), `daily-sync.sh` returned with
  the Operator's uncommitted and untracked work still in its stash, so the
  files vanished from the tree, the mounted skills went missing, and later
  runs saw a clean tree and never restored them. It now aborts a rebase the
  pull left half-done, pops the stash with its index so the tree is exactly
  as before, logs the failure as an ERROR with git's reason, and commits and
  pushes nothing that run; a pop that conflicts still names the stash. New
  cases in `daily-sync-test.sh`.
- **Backups that fail are visible.** The session briefing's `Backup:` line
  repeats the last nightly run's OPS-stage errors and skipped pushes, since
  `daily-sync.sh` exits 0 and nothing read its log. An origin with no branch
  of that name yet is now a first push; before, its pull failed every night
  and nothing was ever backed up.

### Skills and mounts

- **Mounted skills arrive on a fresh install.** Deploy clones the public skill
  source once and runs `skills-vendor.sh sync`; it never pulls an existing
  clone. `skills-vendor.sh` honors `OPS_DIR`, compares file content, and falls
  back to tar where rsync is missing, as on a stock Debian container.
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
- **Skill mounts never delete a folder they did not write.** A manifest row
  replaced whatever sat at `SKILLS/<name>`, so this release's `grill-me`,
  `tdd`, and `diagnosing-bugs` rows would have deleted an existing copy's own
  skill of that name. `skills-vendor.sh` now records a digest of each mirror
  it writes (`SKILLS/.vendored-state.tsv`) and moves any other destination,
  including a hand-edited mirror, to
  `.claude-config/backup/skills-replaced/<name>-<UTC>/` before installing,
  with a `BACKUP` line naming the path; a failed install moves it back.
  Mirrors already equal to their source update in place as before.
- **Skill mounts keep every folder they cannot prove they wrote, and swap
  mirrors in whole.** `skills-vendor.sh` treated an unrecorded folder under
  one of the six names that mounted before the record existed as its own
  mirror, so a user's own or hand-edited `meta-skill-creator` (or any of the
  six) was overwritten in place with no backup. An unrecorded folder that
  differs from its source is now moved aside like any other; one equal to its
  source still updates in place. The rsync engine synced straight into the
  mirror, so a failed or interrupted rsync left it half-updated, and the next
  sync then moved it aside with its GUI-local files; both engines now build
  the mirror in a temp dir and swap it in, keeping the old one on any
  failure. The `BACKUP` line is printed as soon as a folder is moved aside,
  so a later failure still says where it went. New cases in
  `skills-vendor-test.sh`.
- **Skill mounts swap on macOS.** `skills-vendor.sh` swapped each mirror in
  with `mv -T`, which only GNU mv has, so on macOS and BSD every swap failed
  and even a fresh install exited 3. Both renames now target a name that does
  not exist, which plain `mv` handles the same everywhere. New case with a
  `mv` that rejects `-T`.
- **Interrupted mounts clean up after themselves.** A run cut off mid-copy
  left `SKILLS/.vendor.XXXXXX` behind, and the daily backup committed it.
  A sync now removes those staging dirs first (only that exact name shape),
  after moving back a mirror a kill left aside between the two renames, so
  its GUI-local files return with it (a `RESTORED` line); a leftover it
  cannot place goes to the backup dir. `.gitignore` lists
  `SKILLS/.vendor.*/`. New cases.
- **Windows deploy shows a moved skill folder.** `deploy.ps1` captured the
  sync's output and printed it only on failure, so a successful sync that
  moved the Operator's own skill aside said nothing. It now prints the
  `BACKUP` and `RESTORED` lines on success too. New case in
  `deploy-windows-test.ps1`, whose fixture script is now written with LF
  line endings so the test also passes on a fresh (CRLF) checkout.
- **A restored skill folder says so.** When an install failed and the
  folder went back to its place, the earlier `BACKUP` line still named a
  backup path that no longer existed. A `RESTORED` line on stdout now says
  the folder is back where it was. New case.
- **macOS deploy and a steadier skill sync.** Deploy publishes the cloned
  skill source with a plain rename onto a free name, not GNU-only `mv -Tn`,
  which failed every macOS deploy before the skills even synced. The rsync
  engine ignores time-only itemize lines when deciding UNCHANGED, so a mirror
  whose directory time moved no longer flips between SYNCED and UNCHANGED; a
  mode or content change still syncs.

### Template sync

- **Template sync.** `harness-update-scan.sh` excludes `USER.md`, `voice.md`,
  `standing-orders.md`, the `work-tracking`, `team`, and `tools` slots, and the
  marker, plus the retired identity names, so a delta scan never lists an
  unmigrated identity file as REMOVED. This landed first, ahead of the renames.
- **Template sync for older copies.** `harness-update-scan.sh` is self-contained
  by contract (it finds its root from the working directory and loads no helper
  file), so a copy that predates it runs it straight from the template; the
  harness-update skill gains "Updating a copy that predates this skill" with the
  commands. The template's history was rewritten on 2026-10-19 to remove a
  private name from one old commit, so a `last_synced` marker written before
  then names a commit the template no longer has: the scan now translates it to
  its rewritten twin (same tree) and stays in delta mode instead of falling back
  to a first-sync compare. New `harness-update-scan-test.sh`.
- **Template sync delivers renamed and executable files.**
  `harness-update-scan.sh` read `git diff --name-status` with git's default
  rename detection, so a renamed file came back as one line holding two paths
  and dropped out of the delta: never NEW, its old path never REMOVED, and the
  next sync commit moved `last_synced` past it for good (against the public
  main of 2026-10-19 that lost `memory-init` and four more files). The delta
  now runs with `--no-renames`, so a rename is a REMOVED plus a NEW.
  `--apply-safe` sets each file's mode from the upstream tree entry: NEW files
  were written at the umask mode, so `memory-init` arrived non-executable and
  the migration's re-deploy failed. A marker whose last line has no trailing
  newline is read again; before, its `last_synced` was dropped and the scan
  fell back to a first-sync compare without a warning. New cases in
  `harness-update-scan-test.sh`.
- **Template sync writes only into an OPS copy.** `harness-update-scan.sh`
  scans the repo of the working directory, and the harness-update skill ran
  it by absolute path, so from a project clone it added the `ops-template`
  remote there and `--apply-safe` copied the whole template into it. It now
  refuses (`ERR_NOREPO`, nothing written) unless the repo has `BOOTSTRAP.md`
  or `.claude-config/`, and prints the `cd` to run from; the skill's
  commands run as `(cd ~/OPS && ...)`. New case in
  `harness-update-scan-test.sh`.
- **Template sync sees modes.** Files were compared by blob alone, so an
  upstream `chmod +x` with the same content was never applied, and a script
  an earlier scan wrote without its exec bit (which then failed deploy's
  `memory-init` check) read as IDENTICAL forever. Files now compare as (mode,
  blob): a mode-only change is an UPDATE when the local mode is still the
  last-synced one, and any other exec-bit difference is a new MODE line, with
  the `chmod` to run, in delta and first-sync scans alike. New cases.
- **Template sync sets modes under any umask.** `chmod +x`/`-x` with no
  `who` is filtered by the umask, so under 027 clearing the bit left group
  or other bits set and the scan exited 6 after writing the file. It now
  uses `chmod a+x`/`a-x`. New case under umask 027.
- **Template symlinks arrive as symlinks.** A mode 120000 entry was written
  as a regular file holding the link target. It is now created with
  `ln -s`. Each applied file is built beside its destination and renamed
  into place, so a local symlink is replaced rather than written through,
  and the scan can update itself while it runs. A local path that cannot be
  hashed is a CONFLICT, never NEW. New case.

### Deploy and the drift gate

- **Deploy** strips the fleet's PATH and wrapper lines, takes `--no-system`
  (`-NoSystem` on Windows) to skip writes outside `$HOME` for test installs,
  and exits non-zero when a step fails.
- **Deploy checks the git identity.** A fresh Debian user has no git
  identity (an empty GECOS name, no FQDN for an email), so memory-init's
  commit, the daily backup and every agent commit failed while `deploy.sh`
  printed "Deploy complete." `deploy.sh` and `deploy.ps1` now ask `git var`
  for the author and committer identity before memory-init runs and, when
  either is missing, print the two `git config --global` commands and fail
  the deploy (`git-identity`). `memory-init` and `memory-init.ps1` show
  git's own stderr for a failed commit instead of hiding it behind a
  "(hook/signing?)" guess. New cases in `memory-init-test.sh` and
  `memory-init-windows-test.ps1`.
- **The drift gate** checks the new boot: 16 fails when the core is missing,
  over budget, or not linked; 1b fails on a root `CLAUDE.md`; 5 counts the
  principles in `how-i-work.md`; 17 and 21b warn on retired hooks and files;
  21 is the `USER.md` canary; 23 requires every identity exclusion.
  `verify-ops.sh` checks another checkout through `OPS_DIR`. New tests:
  `.claude-config/bin/tests/` (memory-index, root wrapper, deploy rc and core
  wiring, skills-vendor) and new `verify-ops-selftest.sh` cases.

### Landing and review

- **`branch-gc`** removes local branches a merged PR provably carried and
  parks their worktrees in a 7-day trash it can restore from; it fails closed
  on any doubt. It runs nightly from `daily-sync.sh`, from the PreCompact hook
  for the cwd repo (detached; skipped when the payload names a sub-agent),
  and at closeout.
- **The review split.** The open-ended `ops-reviewer` lane is retired. Code
  where a miss is expensive goes to a second vendor's model
  (`bin/second-vendor-review` is the optional hand-off), or with none to an
  Opus 5.5 refutation lane plus the Operator's own read; other code gets a
  Sonnet 5.5 refutation lane; docs and decisions land on verification.
  `how-i-work.md` carries the refutation brief shape.
- **`second-vendor-review` never runs a reviewer without its cap.** With no
  `timeout` or `gtimeout` on PATH (stock macOS) it skipped `--timeout` in
  silence, so a hung reviewer blocked forever and a slow one was written up as
  a review. It now exits 3 before any git work and names the fix
  (`brew install coreutils`); `gtimeout` alone is enough.
- **Ported:** `bin/transcript-usage.py` (token profile from transcripts) with
  a test.

### Destructive tests and the sandbox

- **Destructive tests run in a sandbox.** `bin/sandbox-run` (bubblewrap: a
  read-only root, a fresh home and `/tmp`, nothing writable by default) plus
  a guard every suite that runs branch-gc, pre-compact, memory-init, deploy or
  skills-vendor now starts with; outside the sandbox those suites exit 97.
  `verify-ops.sh` check 24 fails an unguarded one. Why: in the private harness
  an unsandboxed mutation sweep wiped most of a home directory.
- **`guard-selftest.sh` counts every failure.** Its rtk probes read their
  JSON through a pipe, which ran each probe in a subshell: a failing rtk guard
  printed FAIL and the selftest still exited 0 with "ALL GUARDS ENFORCE", the
  exit code `deploy.ps1` acts on. They read a here-string now, and
  `tests/guard-selftest-test.sh` inverts one guard verdict per probe site and
  checks the exit code and the count.

### Fixes and hardening from review

- **Fixes:** every git-guard check now sees through an `rtk` prefix (from a
  project repo, `rtk git push --force`, `rtk git branch -D` and the other
  rtk forms of a blocked command all passed); `harness-update-scan.sh` exits 7
  when git cannot list the delta, instead of reporting a clean empty one;
  deploy's failure summary mentions the core only when the core rule failed;
  the pre-compact-synthesis skill states the push gate's verdict rule;
  `verify-ops.sh` check 25 warns on a memory link whose pool is gone.
- **Review hardening of the sandbox and the reviewer hand-off.** `sandbox-run` passes only an allowlisted set of open
  file descriptors into bubblewrap: an inherited descriptor (fd 255 included)
  let a suite write to the host behind the read-only mounts. `second-vendor-review`
  writes its packet and result to private, unique paths published atomically,
  stops when the digest cannot be read, and no longer records the reviewer
  command, whose inline assignments could carry a credential. New
  `sandbox-run-fd-test.py`, which runs outside the sandbox like `sandbox-run-test.sh`.
- **Review hardening of the push gate, template sync, skill sync and backup.** git-guard closes push bypasses through config
  includes, inherited alias settings and alias options. The template scanner
  refuses any path whose parent is a symlink, so it cannot write outside the
  copy or onto an excluded identity file. Skill sync serializes concurrent
  runs, records the content it staged, and backs up a mirror it cannot place
  instead of deleting it. The daily backup keeps every tracked file's
  permissions across a pull.

### Docs, notices and CI
- **No em dashes.** The 139 em dashes still in tracked text (16 files: the
  `CONTEXT/` templates and the project kata, comments in hooks, scripts and
  self-tests, the design brand template, and two READMEs) are rewritten with
  colons, commas, semicolons or parentheses; no en dashes were present. Code
  changed only in comments and printed text (the handoff banner, the
  self-tests' result lines, `sync-check.sh`'s messages, the `ops-verify` unit
  description), and no test greps any of those strings.
- **The docs match the code.** README gains the requirements (git with an
  identity, a signed-in `gh`, `python3`, `jq`, and git 2.45 and GNU coreutils
  9.5 for branch cleanup), the T3 Code path, and sections on what deploy does,
  the push gate and its limits, the daily backup, skill mounts, template sync,
  and how to check a copy; its list of what the git guard blocks now includes a
  bare `tmux kill-server` and an unverified push. DEPLOYMENT said the trust
  anchor lives in `~/.claude/.claude.json`; deploy writes `~/.claude.json`,
  beside the directory. It also called a failed skill clone a warning, though
  that fails the deploy (`skills-mount`). It gains the exact outputs of its
  verification commands, a recipe for testing a deploy under a throwaway `HOME`
  (its clone's push URL is set to `/dev/null`: a new `HOME` hides neither your
  `gh` login nor your SSH keys, so a clone of a private origin would otherwise
  get deploy's `feat(memory): seed` commit pushed to the real origin), and a
  corrected count of the machinery deploy does not wire. CONTRIBUTING
  gains the private-term rule (your list of private terms never goes in a file,
  a commit message or a PR), a section on where destructive tests run and why,
  and the `GIT_GUARD=off` rule for a PR branch. Its suite loop printed `FAILED`
  but always exited 0, because its last command was an `echo`; the command now
  counts failures and ends with a test of the count, so a red run exits
  non-zero, and it runs the self-tests and the PowerShell suites too. It also
  no longer implies that `verify-ops.sh` on a bare checkout means anything: the
  gate reads host state from `$HOME`, so a machine with no deployed OPS needs
  the throwaway-`HOME` run. AGENTS carries the same caveat, and BOOTSTRAP's recon
  gains a git-identity probe. README and DEPLOYMENT also say that `branch-gc`
  needs git 2.45 or newer and GNU coreutils 9.5 or newer: on Ubuntu 24.04 (git
  2.43, coreutils 9.4) it skips every repository, or cannot move a worktree to
  the trash because `mv --update=none-fail` is new in 9.5, and the nightly
  backup logs it.
- **A workflow script that did not parse.** The `context-coherence` lane prompt
  in `.claude-config/workflows/harness-audit.js` had no closing backtick, so
  the file was a syntax error; `node --check` on Node 24 had been reporting it
  clean. The backtick is restored. The new `syntax` job catches this class, and
  CONTRIBUTING and AGENTS now say how to check a workflow script.
- **Third-party notices.** `SKILLS/THIRD_PARTY_NOTICES.md` lists every work the
  skills adapt, with its author, license, what OPS took and where the full
  license text lives: the `grill-me`, `tdd` and `diagnosing-bugs` skills from
  mattpocock/skills (MIT), the writing model `meta-skill-creator` names from
  the same repository, the communication defaults adapted from i-have-adhd
  (MIT), the AI-tell catalog adapted from cursor/plugins `unslop` (MIT), and
  the design method adapted from anthropics/skills `frontend-design`
  (Apache-2.0, whose license text OPS did not carry before and now reproduces).
- **A CI gate.** `.github/workflows/gate.yml` runs on every push and pull
  request, with no secrets, so a fork's pull request gets the same run, on the
  `ubuntu-26.04` image (24.04's coreutils 9.4 cannot run `branch-gc`, and
  `ubuntu-latest` still means 24.04). Four jobs: `syntax` (`bash -n`, a
  JavaScript parse, `python3 -m py_compile` and a PowerShell parse over every
  tracked script, found by extension or `#!` line; an empty list fails the job;
  a workflow script, any `.js` whose first statement is `export const meta`, a
  skill's included, is parsed as the async function body it runs as, and any
  other `.js` in explicit CommonJS, then module, mode, because plain `node
  --check` rejects workflow scripts on Node 18 and, on newer Node, reports no
  error for a broken one; `bin/tests/ci-gate-test.py` runs that step over every
  tracked `.js` and a set of broken and valid fixtures), `suites` (every suite under `bin/tests/`, the
  `*-selftest` scripts and the two PowerShell suites, the destructive ones
  inside `sandbox-run`; the job installs bubblewrap, zsh and rsync and upgrades
  an older git, because `branch-gc` needs 2.45), `smoke` (a fresh install in a
  throwaway `HOME` with the current Stage-1 settings, a git identity and
  `deploy.sh --no-system` run twice, then `verify-ops.sh`), and `secrets`
  (gitleaks over the full history, from a binary pinned by SHA-256 because the
  official action wants a license key for organization repositories, then OPS's
  own `secrets-scan.sh`). Actions are pinned by commit. Every job is skipped
  outside the template repository, so private copies made from the template do
  not spend runner minutes on every daily backup push. Not covered: Windows and
  macOS hosts, and the Claude Code CLI.
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
