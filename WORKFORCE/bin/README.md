# bin/ — Helper Scripts

These scripts wrap the most common coordination actions so agents
(and the Operator) don't have to hand-write atomic file moves and
JSON every time. **Linux-only** — fleet mechanics rely on GNU
coreutils (`stat -c`, `date -d`, `find -printf`), bash 4+
features (`declare -A`, `${var,,}`, `mapfile`), and `flock`. macOS
+ Windows are explicitly NOT supported targets. Windows hosts are
shell + OPS-context experience only; fleet coordination does
not run there.

After deployment, this directory is on `PATH` (wired into your
shellrc by OPS Stage 2 — `~/OPS/.claude-config/deploy.sh` on
Linux/macOS, `deploy.ps1` on Windows). Call by name from anywhere.

---

## Scripts

### `ac-msg`

Send / list / read / archive messages.

```bash
# Send (body via stdin):
echo "PR #72 opened, replaces api_query in WF1" \
  | ac-msg send --from Bravo --to Captain --topic pr-72-opened \
                --priority normal --refs <project-repo>#<pr-number>

# If AC_NAME is set, --from is implicit:
echo "blocker cleared" | AC_NAME=Bravo ac-msg send --to Captain --topic blocker-cleared

# List your inbox:
AC_NAME=Bravo ac-msg list

# Read one message:
AC_NAME=Bravo ac-msg read 2026-05-11T15-12-34Z__Captain__task-assigned

# Archive after processing:
AC_NAME=Bravo ac-msg archive 2026-05-11T15-12-34Z__Captain__task-assigned
```

### `ac-register`

Claim a name + register in manifest. Auto-picks unclaimed name from
`personalities/name-pool.md` if `--name` is omitted.

```bash
# Activate as agent (auto-pick name):
ac-register --role agent --scope <project-scope>
# Prints chosen name (e.g., "Bravo") to stdout — capture into AC_NAME.

# Activate as coordinator:
ac-register --role coordinator
# Fails if another coordinator's last_seen < 5 min ago.

# Release on session end:
ac-register --release Bravo

# Mark stale (coordinator or peer action):
ac-register --stale Echo

# List active agents:
ac-register --list
```

### `ac-status`

Snapshot of multi-agent state. Operator-facing readable output.

```bash
ac-status              # default text view
ac-status --log 50     # last 50 log entries
ac-status --inbox      # also show per-inbox counts
ac-status --json       # JSON dump for piping into jq
```

### `ac-sync`

Pull, commit tracked changes, push. Use at session end (or
periodically) to publish state to the OPS remote so other
machines see it.

```bash
ac-sync               # pull, stage tracked WORKFORCE paths, commit, push
ac-sync --pull        # pull only
ac-sync --push        # commit + push, skip pull
ac-sync --dry-run     # show what would commit
```

Commit message includes hostname and `$AC_NAME` for audit.

### `ac-pulse`

Heartbeat update for your agent/coordinator — `last_seen` +
`status` + optional task/blocker/branch/repo fields, mirrored into
your manifest entry so both stay in sync.

```bash
ac-pulse                                       # touch last_seen only
ac-pulse --status working --task <id>
ac-pulse --status blocked --blocked-on "<list>"
ac-pulse --show                                # cat current pulse
```

### `ac-task`

Task-spec maintenance helpers (subcommands may grow).

```bash
ac-task --auto-close-parents [--dry-run]   # flip parent to awaiting_review once all children are done
ac-task --list-parents
```

### `ac-spawn`

Launches a peer Claude Code agent: opens a tmux window in the
`ClaudeAgents` session and starts a `claude` process in it, then
pastes the activation brief via load-buffer/paste-buffer
(multiline-safe — `send-keys` corrupts on newlines/embedded quotes).

```bash
ac-spawn --scope <tag> --task <id-or-path> [--name <hint>] \
         [--brief <path>] [--config-dir <path>] [--model <alias>] \
         [--no-skip-permissions]
```

### `ac-compact-peer`

Fires `/compact` on a peer's tmux pane from the outside — agents
can't self-fire Claude Code UI commands. Symmetric: Captain↔peer,
peer↔peer.

```bash
ac-compact-peer --target <tmux-pane> --peer-name <name> --reason "<text>"
```

### `ac-mcp-reconnect-peer`

Same idea as `ac-compact-peer` but fires `/mcp` — for reconnecting a
peer's MCP connectors (stale sessionId, Anthropic Proxy errors,
post-deploy refresh) from outside that peer's pane.

```bash
ac-mcp-reconnect-peer --target <tmux-pane> --peer-name <name> --reason "<text>"
```

### `ac-pre-compact`

Refreshes the journal's RESUME ANCHOR (latest verbatim Operator
quote, in-flight task ids, last 5 decisions, timestamp) before
auto-compaction fires. Idempotent; safe to run at any context level.

```bash
ac-pre-compact              # refresh anchor
ac-pre-compact --notify     # also FYI the Operator
```

### `ac-post-compact-check`

Mandatory first action post-compact. Compares the latest
operator-direction quote against the quote embedded in the
journal's RESUME ANCHOR; exit 0 = aligned (prints the alignment-ack
template), exit 1 = stale anchor (HALT, re-run `ac-pre-compact`),
exit 2 = no operator-directions filed yet.

```bash
ac-post-compact-check
```

### `ac-reorient`

Post-compact + session-start re-anchor. Prints the re-read order,
fleet pulse ages + stale flags, your inbox + open tasks, and your
journal's RESUME ANCHOR — everything needed to re-anchor in under
2 minutes. Wired into the `SessionStart` hook so it fires
automatically, including on post-compaction resume.

```bash
ac-reorient              # auto-detect name from $AC_NAME or _coordinator.json
ac-reorient Captain      # explicit name
```

### `ac-rollup`

Generates a single rollup artifact (done-tasks, decisions, open
queue) instead of typing recap paragraphs — the no-status-narration
rule needs something to point at.

```bash
ac-rollup                       # today, writes to runtime/improvements/<date>__rollup.md
ac-rollup --date 2026-05-12
ac-rollup --stdout
```

### `ac-drift-check`

Nightly kata + doctrine drift detection for the OPS repo itself
— the project-kata six-line check plus doctrine-specific checks
(stale principle counts, dangling line-number refs, etc.).

```bash
ac-drift-check
```

### `ac-backfill-shas`

Scans done-tasks that predate `ac-msg`'s auto-SHA-attach behavior,
greps git log for commits matching the task slug/topic, and appends
a `## Shipped` section with the best matches.

```bash
ac-backfill-shas [--dry-run]
```

### `ac-close-project`

Winds down and closes a `FLEETPROJECTS/<project>/` per
`protocol/project-lifecycle.md`: sanity-checks for in-flight work,
generates `CLOSEOUT.md`, frees agent names, detaches the coordinator
slot, files the closeout decision, optionally archives to
`~/OPS/ARCHIVE/`.

```bash
ac-close-project <slug> [--archive] [--dry-run] [--force]
```

### `ac-cron-body`

Prints the canonical cron-prompt body for a role, sourced from
`protocol/cron-prompt-template.md` — one source of truth, no
copy-paste drift into `CronCreate`.

```bash
ac-cron-body --role agent          # Agent self-pacing body
ac-cron-body --role coordinator    # Coordinator body
ac-cron-body --hash                # SHA256 of the template (drift check)
```

### `ac-memory-init` (+ `ac-memory-init.ps1`)

Initializes Claude Code auto-memory git-sync on a machine: walks
every encoded-cwd memory dir Claude Code has created, moves each
into `~/OPS/.claude-memory/<hostname>-<encoded>/`, symlinks the
original path back. Idempotent — safe to re-run on an
already-set-up machine. `ac-memory-init.ps1` is the Windows
counterpart (same behavior, PowerShell 5.1+, needs Developer Mode
or an admin session for the symlink).

```bash
ac-memory-init
```

### `ac-memory-gc`

Read-only inventory + GC report across all auto-memory pools —
flags STALE (retired-project), EMPTY, and OVER-limit pools. Stages
prune/archive candidates for the Operator; never deletes or moves
anything itself.

```bash
ac-memory-gc
```

### `ac-memory-index` (+ `ac-memory-index.test.sh`)

Regenerates a memory directory's `MEMORY.md` index from each memory
file's frontmatter (`title` + `description`). `MEMORY.md` is a
generated artifact — never hand-edit it. The `.test.sh` companion is
a runnable, self-contained test suite (scratch fixtures in `mktemp`;
never touches a live memory directory).

```bash
ac-memory-index <memory-dir>
ac-memory-index.test.sh        # run the test suite
```

### `claude-wrapper.sh`

Shell function (sourced from your shellrc, not run directly) that
wraps `claude` invocations for safe root/master sharing on one
host: auto-fixes the permission mode when running as root, and
serializes root+master sessions that share a config dir so they
don't race on `.credentials.json` / `.claude.json` / session state.

```bash
source "$HOME/OPS/WORKFORCE/bin/claude-wrapper.sh"
```

---

## Environment variables

| Var | Used by | Purpose |
|---|---|---|
| `AC_ROOT` | all runtime ops | Per-project runtime root. **No default** — must be set explicitly (e.g., `export AC_ROOT=$HOME/OPS/WORKFORCE/FLEETPROJECTS/<project>`). Scripts fail-fast if unset. Prevents cross-project state collisions. |
| `AC_FLEET` | activation + spawn | Shared fleet system root. Default: `~/OPS/WORKFORCE`. Holds personalities/, protocol/, bin/. |
| `AC_NAME` | most | Your agent name. Avoids passing `--from` / `--for` / `--name` everywhere. |
| `AC_SESSION_ID` | `ac-register` | Opaque session id written into manifest. Defaults to `<epoch>-<pid>`. |

A typical agent session sets `AC_NAME` once and exports it:

```bash
AC_NAME=$(ac-register --role agent --scope <project-scope>)
export AC_NAME
echo "I am $AC_NAME"
```

---

## What the scripts do NOT do

- They do not write decision records (that's a content decision —
  agents author them by hand using the format in
  `protocol/decisions.md`).
- They do not draft task specs (Coordinator drafts; agents update
  statuses).
- They do not enforce the irreversible-action gate — that's a
  behavioral rule in `AGENT.md`, not a script-level lock.
- They do not push automatically — `ac-sync` runs when called.

---

## Possible future additions

Not built yet:

- `ac-decide` — scaffold a decision record from template (agents
  currently hand-write these using the format in
  `protocol/decisions.md`).
- Cross-machine notification — push a desktop notification when
  an urgent message lands. Probably overkill, but documented as
  an option.
