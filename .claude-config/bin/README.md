# `.claude-config/bin/`: operator utilities

Small, tracked helper scripts that ship with OPS and sync to every machine.

## `claude-window-ping.sh`: scheduled 5h-window opener

Cron-fired dumb pipe: sends one headless `ping` to a brand-new Claude Code
session per configured profile so the 5-hour usage window starts counting at
times the Operator chooses, with nobody at the keyboard. MCP stripped
(`--strict-mcp-config` + empty config), runs from `$HOME`, outside tmux: so
ping sessions never enter the remote-session registry and load no project
context.

```
45 5  * * * $HOME/OPS/.claude-config/bin/claude-window-ping.sh
0  11 * * * $HOME/OPS/.claude-config/bin/claude-window-ping.sh
15 16 * * * $HOME/OPS/.claude-config/bin/claude-window-ping.sh
```

Knobs: `CC_WINDOW_PING_PROFILES` (space-separated `name=config_dir` pairs,
default `default=$HOME/.claude`; a pair without `=` is skipped loud with an
rc=2 status row), `CC_WINDOW_PING_MODEL` (default `sonnet`),
`CC_WINDOW_PING_TIMEOUT` (seconds per profile, default 180: worst-case wall
time is N profiles x timeout). Surfaces: `~/.local/state/window-ping/ping.log`
(append log) and `last-status.tsv` (atomic tmp+mv; rc verbatim, 124 = timeout,
127 = binary missing, 2 = config error), which `hooks/session-briefing.sh`
reads to flag a failed or stale (default ≥25h, `CC_WINDOW_PING_STALE_HOURS`)
ping at next session start. Overlapping runs are serialized by a non-blocking
flock. `claude-window-ping-selftest.sh` proves every unattended path against
a mock binary: no real API usage. Machine-local: Stage 2 does not deploy the
crontab; add the lines by hand per box.

## `model-probe.sh`: do the pinned models answer on this account?

Report only. It reads the model ids your settings pin (the top-level `model`
key and the `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL` and
`CLAUDE_CODE_SUBAGENT_MODEL` env keys), sends one short headless request per
distinct id, and prints `ok`, `FAIL` (request failed), or `UNSURE` (timeout or a
usage-limit refusal, which says nothing about entitlement) for each. It never
writes a settings file. Probes disable tools, transcript persistence, and user
customizations (hooks and plugin sync) with Claude Code's `--safe-mode`.
Subscription authentication still works; `--bare` would skip it. The CLI can
update its own cache/auth state, and policy-managed hooks still apply.
Which tier to run is policy
(`CONTEXT/model-roles.md`); this only tells you whether an id works on your
plan.

```
model-probe.sh          probe each distinct pinned id (spends a few tokens)
model-probe.sh --list   print the ids and the keys that pin them; no API call
```

Exit 0 = every id answered (or `--list`), 1 = a rejected or inconclusive id,
2 = no settings, jq, or claude CLI. A value in those keys that is not a model
id is never passed to the CLI or printed. Why report-only: on a
linuxploitacious host `~/.claude/settings.json` is a symlink into the tracked
Stage-1 checkout, and the earlier version of this script rewrote the `model`
line there on every deploy, pinning retired tiers and leaving a diff that broke
that checkout's next `git pull --ff-only`. Neither `deploy.sh` nor
`deploy.ps1` runs it; `BOOTSTRAP.md` Stage 0 recon runs it once. Test hooks:
`OPS_MODEL_PROBE_{SETTINGS,BIN,TIMEOUT}`. `model-probe-selftest.sh` proves it
against a mock binary under a throwaway `HOME` (no API usage), including that
the settings file and the rest of `HOME` stay unchanged by the mock, and that
probes request the isolation flags. The settings source honors
`CLAUDE_CONFIG_DIR` when a profile is selected.

`python3 plugin-retire-selftest.py` exercises only the caveman + ponytail
check of both deployers under temporary homes: no case makes a mutating CLI
call, an installed plugin gets the removal command and stays installed,
declarations point at Stage 1, absent plugins are quiet, and an unreadable
inventory warns. It uses a local real Claude CLI when available as well as a
mock; neither path downloads plugins or calls an API.

## `verify-ops.sh`: the drift gate

Machine-checks the conventions that used to live only in prose; exit 1 on any
FAIL. Run it after a harness change and after a template sync
(`verify-ops.sh --quiet` prints only WARN and FAIL lines). The model checks
read the settings files and the pin surfaces (agents, workflows, commands,
skill workflow scripts): 14 warns when the session pin is not the foreman tier,
15 fails on the banned Opus 5 id matched at its boundary, and 15b fails on a
retired id, on any Haiku other than `claude-haiku-5-5`, and on an
`ANTHROPIC_DEFAULT_HAIKU_MODEL` pin that is not exactly that id. Check 24
fails a test that names a destructive tool without the sandbox guard (next
section), and check 25 warns on a `~/.claude/projects/*/memory` link whose
pool directory is gone (run `memory-init`). The memory checks measure what a
session loads: check 6 runs `memory-index --digest-fit` on every pool and
WARNs when a pool's entries lose their descriptions in the 9,000-character
digest (with an older indexer it falls back to the 24 KB `MEMORY.md` check),
and 6b WARNs on a pool over 60 entries; both FAIL only when the indexer cannot
run or cannot read a pool, because a pool's size is its owner's call. Check 9b
WARNs on a `SKILL.md` over 16 KB or with a line over 1,500 characters, skipping
mounted, synced and symlinked skills. Check 5 reads a tracker project number
(`P` plus 8 digits, a dot, 4 digits) as an ID, not a principle citation. Check
8 runs `secrets-scan.sh` over memory and lessons and reports its two failures
apart: a found credential (exit 1), or a line grep could not scan (exit 2,
with the scanner's reason). `verify-ops-selftest.sh` sources the gate and
drives those checks plus the SessionStart matcher check against fixture trees
under a throwaway `HOME`.

## `sandbox-run`: the sandbox for destructive-tool tests

The rule (`CONTEXT/how-i-work.md` P9): a test, self-test, mutation check, or
probe of a tool that deletes, moves, or overwrites files runs only through
`sandbox-run`. In the harness OPS is ported from, an unsandboxed mutation
sweep of a cleanup tool ran the real deleter on `/` and `$HOME` and wiped most
of a home directory. The tools on the list, and why each is there, are
`OPS_DESTRUCTIVE_TOOLS` in `verify-ops.sh` (check 24).

`sandbox-run` runs a command inside bubblewrap (`bwrap`, a root-owned binary
it checks before trusting): the root filesystem read-only, a fresh tmpfs over
the home directory at the same path (a script that builds paths from `$HOME`
lands in the tmpfs, and the real home is hidden), a fresh tmpfs `/tmp`, an
empty tmpfs over `/run/user/<uid>`, a fresh PID namespace, and writable only
the directories named with `--bind` (none by default).

```
sandbox-run [--bind DIR]... [--no-bind] [--ro-bind PATH]... [--no-net] [--chdir DIR] [--] CMD [ARG...]
```

- `--bind DIR` is repeatable. Refused: `/`, the home directory or any
  ancestor of it, paths under `/proc`, `/sys`, `/dev`, the user runtime dir,
  anything you do not own, and a repository's primary checkout or anything
  inside one (a writable bind is what an `rm -rf` in the sandbox can still
  reach). Bind a linked worktree or a scratch directory.
- `--ro-bind PATH` shows a path read-only; anything under the home directory
  is hidden without one. `--no-net` gives a network namespace with loopback
  only.
- It never runs the command unsandboxed. Exit codes: the command's own, or 2
  usage, 3 a refused path, 4 `bwrap` missing or replaceable by a non-root
  user, 125 the sandbox could not be set up.
- Inside: `OPS_SANDBOX=1`, `OPS_SANDBOX_NONCE`, and the nonce again in
  `/tmp/.ops-sandbox/nonce`, a read-only mount.

Run a destructive suite by hand from the checkout root (Python suites get
`/usr/bin/python3`, since a pyenv interpreter under the home is hidden):

```
.claude-config/bin/sandbox-run --no-bind --no-net --ro-bind "$PWD" -- bash .claude-config/bin/tests/branch-gc-test.sh
.claude-config/bin/sandbox-run --no-bind --no-net --ro-bind "$PWD" -- python3 -B .claude-config/bin/tests/branch-gc-safety-test.py
```

The guard. Every suite that runs a destructive tool starts with one line that
refuses to run anywhere else (exit 97, `refusing to run outside sandbox-run:
<reason>`); `sandbox-lint`'s header holds the exact lines and the detection
check 24 uses:

```
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/../sandbox-guard.sh" && sandbox_guard || exit 97
import os, runpy; runpy.run_path(os.path.join(os.path.dirname(os.path.realpath(__file__)), "..", "sandbox_guard.py"))["require"]()
```

Both guards read the mount table, not the environment: the root read-only, a
tmpfs at the account's home, `$HOME` on a tmpfs, and the nonce mount matching
`OPS_SANDBOX_NONCE`, so an exported variable proves nothing. A mutation sweep:
save a copy of the file, mutate it, run the suite through `sandbox-run` with
`PYTHONDONTWRITEBYTECODE=1` and a scratch copy as the only `--bind`, then
restore the saved copy (never `git checkout <file>`, which wipes every
uncommitted edit).

Limits. bwrap cannot nest where AppArmor's `unpriv_bwrap` profile denies a
second user namespace (Ubuntu 23.10 and later), so a sandboxed suite cannot
start `sandbox-run`; `tests/sandbox-run-test.sh` and `tests/sandbox-run-fd-test.py` start it and run outside,
safe by construction (it writes and deletes only in its own scratch dir). The
sandbox stops writes, not reads. Files: `sandbox-run`, `sandbox-guard.sh`,
`sandbox_guard.py`, `sandbox-lint`. Tests: `tests/sandbox-run-test.sh`
(isolation, every refusal, both guards), `tests/sandbox-run-path-test.py`
(path swaps and the bind policy, with an inert bwrap recorder),
`tests/sandbox-lint-test.py` (the detection).

## `branch-gc`: merged-branch and worktree cleanup

Squash merges leave every landed branch, and the Claude Code or T3 worktree on
it, behind; `gh pr merge --delete-branch` is never used, because worktrees
share one ref store and it moved live checkouts. `branch-gc` removes local
branches covered by a merged PR or by origin's default branch, and moves their
eligible worktrees into a trash purged after a week. Default is `--dry-run`
(the table, no changes).

```
branch-gc [--dry-run|--apply] [--remote] [--tsv] [REPO_PATH...]
branch-gc --restore TRASH_ENTRY
```

Every rule fails closed; the script's header states each one with its why. In
short: a branch goes only when a MERGED PR's head (or the default branch) holds
its tip and every commit in its reflog; OPEN, CLOSED-only, the default branch
and the main checkout's branch are report-only; a worktree is moved (one
rename, never a copy or a delete) only when it is clean, ignored files
included, unlocked, not anyone's cwd, not held by a live T3 thread, and past a
2-hour grace after the merge; any `gh` error skips the whole repo and fails
the run. Repos: arguments, else `BRANCH_GC_REPOS`, else `~/OPS`, every repo at
`~/OPS/PROJECTS/*/*`, and `~/linuxploitacious`. State and the trash live
under `~/.local/state/ops/` (`branch-gc.log`, `branch-gc-trash/`).

Who runs it: `../backup/daily-sync.sh` nightly (`--apply`, after the project
pull), the PreCompact hook for the repo holding the cwd (detached, with a
soft deadline and the purge off), and closeout on each repo a session
touched. Tests (all inside `sandbox-run`): `tests/branch-gc-test.sh`,
`tests/branch-gc-safety-test.py`, `tests/branch-gc-t3v2-test.py`,
`tests/branch-gc-deadline-test.py`, `tests/branch-gc-late-writer-test.py`;
the hook's half: `tests/pre-compact-test.sh`.

## `second-vendor-review`: the optional second-vendor reviewer

The review split (`CONTEXT/how-i-work.md`, Review pickup) sends code where a
miss is expensive to a model from another vendor. This script is the hand-off
when you have one: it builds one packet (a fixed reviewer preamble, your
digest, the diff stat, and `git diff <base>...HEAD` without lock files or
`--exclude` paths), pipes it to the command in `OPS_REVIEWER_CMD`, and writes
the result to a file. The command runs in an empty scratch directory, so the
reviewer sees the packet and never your tree. Without `OPS_REVIEWER_CMD` it
exits 3 and names the fallback (an Opus 5.5 refutation lane plus the
Operator's read). Nothing runs it on its own.

```
second-vendor-review --base REF --digest FILE [--repo DIR] [--out FILE] [--exclude SPEC]... [--max-kb N] [--timeout S] [--dry-run]
export OPS_REVIEWER_CMD='codex exec --sandbox read-only --skip-git-repo-check -'   # one example
```

Exit: 0 reviewed, 2 usage, 3 not configured (no `OPS_REVIEWER_CMD`, or no
`timeout` or `gtimeout` on PATH to enforce `--timeout`; stock macOS needs
`brew install coreutils`), 4 packet over `--max-kb` (default 400: split the
change), 5 the reviewer failed, timed out or printed nothing (the result file
says NO REVIEW), 6 git could not build the diff, or it is empty. Test:
`tests/second-vendor-review-test.sh`.

## `transcript-usage.py`: token profile from transcripts

`transcript-usage.py --since ISO [--until ISO] [--hourly] [--gaps] ROOT...`
reads Claude Code transcripts under each root (`~/.claude/projects`) and
prints one row per session or lane: calls, input, cache writes and reads,
output, idle gaps and the cache re-writes after them. Metadata only, never
message text. Test: `tests/transcript-usage-test.py`.

## `memory-index`, `memory-init`, `memory-init.ps1`: auto-memory

`memory-init` (bash; `memory-init.ps1` on Windows) walks Claude Code's encoded
cwd dirs under `<config>/projects/` and links each `memory/` into
`.claude-memory/<host>-<encoded>/`, so auto-memory is git-synced; deploy runs
it with `--auto-commit`, which commits each new pool and pushes it only through
`origin-private-check` (below; `memory-init.ps1` carries the same check as
`Test-OriginPrivate`). `memory-index <dir>` regenerates a pool's `MEMORY.md`
from each entry's frontmatter (atomic write; `--check` prints without writing);
the `memory-index.sh` SessionStart hook calls it, so never hand-edit an index.
Both moved here from the retired fleet's `WORKFORCE/bin` (formerly
`ac-memory-*`).

**What gets a pool.** `memory-init` makes no pool for a scratch or temp cwd
(`-tmp*`, the T3 Code "No project" scratch dirs in both dot spellings, Claude's
own temp dir, `t3code-claude-title`) or for a project whose memory dir holds
nothing but `MEMORY.md`, and the run says how many scratch cwds it skipped. A
link to a pool that no longer exists gets the pool recreated (with a
`.gitkeep`, so git keeps it). One run on a box with many throwaway sessions had
made 35 empty pools in 7 seconds before these two rules.

**Host key.** A pool's name starts with the machine's host key. Order:
`memory-init --hostname` (this run only; `MEMORY_DIGEST_HOST` is the same for
`memory-index`, a test hook), then the per-machine file
`~/.config/ops/memory-host` (outside the synced repo), then the hostname, or
`m-<machine-id[:12]>` when it is generic. The file lets a successor box, or a
second login, share the first box's pools instead of keying an empty set:
`memory-init --set-host-key <key>` writes it (`memory-init.ps1 -SetHostKey` on
Windows), and `memory-init` and `memory-index` read it. Undo: delete the file.
The file is per HOME, so a root session needs its own (run it as root). The
rule is one rule held by three readers, so they cannot disagree about a file:
ASCII bytes only, at most 65 bytes, one key (`[A-Za-z0-9][A-Za-z0-9._-]{0,62}`,
ASCII uppercase lowercased after the check) and optionally one LF or CRLF. Anything else (a BOM, UTF-16,
padding or other whitespace, a NUL, a second line, the Kelvin sign) is refused,
as is any failure to look at or read an existing file (a directory, a dangling
symlink, no permission): a bad file stops `memory-init` and makes the digest
print a notice, never another key's pool. Nothing there, `~/.config/ops` being
a file, or HOME unset means no override. The readers are `host_key_ok` and
`read_host_key_file` in `memory-init`, `parse_host_key_file` in `memory-index`
and `Get-HostKeyFromFile` in the PowerShell twin; `tests/memory-host-key-rule-test.sh`
feeds all three the same cases and fails on any disagreement. Change them
together. It runs its PowerShell column only when `pwsh` is on the PATH, and
says SKIP when it is not (under `sandbox-run`, bind the directories that hold
`pwsh` in with `--ro-bind` to run it).

**Index, digest, hint.** Beyond the index, `memory-index` reads the same
frontmatter for three more jobs, all read-only:

- `--digest [--cwd DIR] [--ops DIR]` prints a memory digest of at most 9,000
  characters (Claude Code shows the model only a 2,000-character preview of a
  hook's output past 10,000), in tiers: entries with `metadata.pinned: true`
  first, always with their descriptions (the Operator's rulings and hard gates;
  at most 20 across both pools, and an extra pin is demoted to the next tier,
  never dropped), then `user` entries, then `feedback` entries, then the rest,
  this directory's pool before the OPS root pool's cross-project entries,
  newest `metadata.modified` (else file time) first within a tier. Past the
  budget an entry is listed by name, then counted, and the last line names
  `memory-index --find`. `hooks/memory-digest.sh` prints it at every
  SessionStart source when Claude Code's native auto-memory is off (the
  Stage-1 settings turn it off and register the hook) and stays silent when
  the native load is on: `MEMORY_DIGEST=1` or `0` forces it, and otherwise
  `CLAUDE_CODE_DISABLE_AUTO_MEMORY` and `autoMemoryEnabled` in the user
  settings decide. A failure prints one notice line naming the indexes, never
  a partial block. It never writes anything and creates no pool.
  `--digest-fit <pool>...` prints one row per pool (entries, described, by name
  only, not shown) for a gate or an inventory script.
- `--hint` reads a UserPromptSubmit payload on stdin and prints at most three
  `Relevant memory: <name>: <description>` lines when the prompt strongly
  matches the names and descriptions of this directory's pool and the root
  pool, and nothing otherwise. It is a local keyword scorer: no model call, no
  network, tens of milliseconds. It stays silent for a message the harness sent
  (slash commands, compaction summaries, batons, scheduled wakes, task
  notifications, notes from other agents, quote replies) and for a lane.
  `memory-index --find <words>` is the same scorer by hand: the best matches
  with their scores, no strong-match bar, the way to find an entry the digest
  did not describe.
- `--check <dir>` exits 2 when a file has neither `title:` nor `name:` (an entry
  with only `name:`, the pool entry format, is labelled by it, Title Cased).
  A pool of more than 60 entries is a WARN on stderr and nothing else: the
  index is still written, the exit status does not change and no entry is
  removed, because a pool is its owner's. Past about 40 entries the digest can no
  longer describe every one, so the tail loses its descriptions; the
  `memory-prune` skill is the fix, whenever you choose it. More than 20 pinned
  entries warns the same way.

Tests: `tests/memory-index-test.sh`, `tests/memory-digest-test.sh`,
`tests/memory-boundary-test.py`, `tests/memory-init-test.sh` (conflicting pools
and the push gate), `tests/memory-init-hostkey-test.sh` (the host key flags and
which cwds get a pool), `tests/memory-host-key-rule-test.sh` and
`tests/memory-init-windows-test.ps1`. The hint hook's own suite is
`tests/memory-hint-test.sh`; `tests/memory-digest-test.sh` also drives
`hooks/memory-digest.sh`. The `memory-prune` skill's read-only inventory has
`tests/memory-prune-inventory-test.sh`.

## `memory-hint.sh`, `report-lint.sh`, `askuser-cancel.sh`, `foreman-context.sh`: prompt, stop and boot hooks

Four fail-open hooks (exit 0 always, nothing printed when there is nothing to
say, an interpreter or a crash never reaches the session). The Stage-1
settings register each one behind a `test -x` guard, so it runs once this
checkout ships it; `deploy.sh` never writes `~/.claude/settings.json`. Each
header says which event.

- `hooks/memory-hint.sh` (UserPromptSubmit): prints the `memory-index --hint`
  lines (above) at the moment the agent is about to act, so a ruling that is not
  pinned still reaches it when the prompt is about it. Silent for a harness send,
  a prompt too short or too long to be a request, and a lane (`agent_id` in the
  payload, or `bin/lane-class` answering `t3-lane` or `agent-lane`). A 3 s cap on
  the scorer; a failure is one line in `${OPS_STATE_DIR:-~/.local/state/ops}/memory-hint.log`,
  never a message to the model. `MEMORY_HINT=0` turns it off.
- `hooks/report-lint.sh` (Stop; the work is in `report-lint.py`): when a
  foreman's FINAL message asks the Operator to decide more than three things,
  carries a decision table, or names things only by ID in its asks, it blocks
  the stop once with a short reason that tells the agent to post it again as an
  ask card: at most three asks, each with a recommendation and a default, the
  rest as one-line "decided" or "handling" items, a name beside any ID. Earlier
  narration in the turn is never judged, and nothing in it reads for deferral. It
  never blocks a message under 400 characters, a stop that is already the
  rewrite (`stop_hook_active`), a lane, the same message twice, or anything it
  cannot read. `REPORT_LINT=0` turns it off; `REPORT_LINT_MAX_ASKS` (default 3)
  moves the threshold. Each judged Stop leaves one line of counts and a hash,
  never text, in `${OPS_STATE_DIR:-~/.local/state/ops}/report-lint.jsonl`.
  Tests: `hooks/report-lint-selftest.sh`, `hooks/report-lint-regression-test.py`.
- `hooks/askuser-cancel.sh` (UserPromptSubmit and Stop, as the Stage-1
  settings register it; PostToolUse with the matcher AskUserQuestion is also
  safe to add; the work is in `askuser-cancel.py`): in T3 Code a
  message that arrives while a question card is pending cancels the question,
  and the stock rejection reads like a refusal by the Operator. This adds the
  missing fact once per question (it was cancelled, it is no answer; do not
  record it as declined; re-ask once or proceed on the stated default). The
  common case, nothing cancelled, costs a `grep` over the transcript tail and no
  Python. `ASKUSER_CANCEL=0` turns it off. Test: `hooks/askuser-cancel-selftest.sh`.
- `hooks/foreman-context.sh` (SessionStart): prints `CONTEXT/foreman.md`, the
  doctrine that binds the main thread only, into a foreman session, so `core.md`
  carries only what binds everyone (every session and every subagent pays for
  `core.md` on every turn). `bin/lane-class` decides: only `foreman` prints; a
  lane gets nothing, and a missing or slow `lane-class` degrades to foreman (a
  lane that wrongly receives the file wastes tokens, a foreman that wrongly does
  not would lose its rules). A lane's own auto-compaction still gets it once
  (OPS's PreCompact writes no lane marker to tell it apart). A file over
  8,192 bytes prints nothing at all, because Claude Code would show only a
  preview of an oversized hook output that still opens with the heading, and
  `core.md` tells a foreman with no "Foreman doctrine" block to read the file
  itself. The root is the script's own checkout, so a worktree reads its own
  copy. Test: `hooks/foreman-context-selftest.sh`. `harness-update` syncs
  `foreman.md` with `core.md`, which points at it.

## `origin-private-check`: the push gate

`origin-private-check [dir]` exits 0 only when every push URL of the repo's
`origin` is verified private, so the unattended pushes (`memory-init
--auto-commit`, `../backup/daily-sync.sh`) never publish an Operator's notes.
Exit 1: a push URL is the public template (`github.com/Exploitacious/OPS` in
any URL form or case) or GitHub reports the repo public. Exit 2: it cannot
verify (no origin, `gh` missing or signed out, an API or network failure, a
host other than github.com). It asks `gh api --hostname github.com
repos/<owner>/<repo> --jq .private`, resolves an ssh host alias with `ssh -G`,
and prints one line on stderr either way, naming only host and owner/repo,
never a URL's credentials. Callers commit regardless and push only on 0 with
the gate's `private` verdict as its last line, because an empty or truncated
copy of the gate also exits 0. A URL is normalized first (whitespace, quotes,
percent-escapes, repeated slashes, dot segments, a trailing host dot), so an
odd form of the template still reads as the template. For a
remote it cannot verify, `git -C <copy> config ops.pushVerified true` (read
from the repo's own config only) turns 2 into 0; it never changes 1. Tests:
`tests/origin-private-check-test.sh`, and the caller cases in
`tests/memory-init-test.sh` and `tests/daily-sync-test.sh`.

## `claude-root-wrapper.sh`: root permission mode and shared-host lock

Sourced from `/root/.zshrc` and `/root/.bashrc` (deploy wires it when
passwordless sudo exists). As root it injects `--permission-mode auto`
(Claude Code refuses bypass mode as root); for root, or with
`CLAUDE_SHARED_HOST` exported, it holds a `flock` on
`<config dir>/.instance.lock` so two UIDs sharing a config dir never run at
once, and fails closed when `flock` is missing. Your own shell is not wrapped.
Replaces the fleet's `claude-wrapper.sh`. Test:
`tests/claude-root-wrapper-test.sh`.

## `skills-vendor.sh`: the skill mounts

Mirrors each `SKILLS/VENDORED.tsv` row from its source clone under `PROJECTS/`
into `SKILLS/<name>/` (`sync`, the default), or reports drift (`--check`: OK,
DRIFT, MISSING; the gate behind `verify-ops.sh` check 22). Uses rsync with a
content comparison where installed and tar otherwise; either builds the mirror
in a temp dir and swaps it in, so a failed copy leaves the old one intact. Honors `OPS_DIR`. Deploy
clones the public source once and runs `sync`. It never deletes a folder it
did not write: `SKILLS/.vendored-state.tsv` records a digest of each mirror,
and a destination that is not a known mirror (your own skill under a mounted
name, a hand-edited mirror, any unrecorded folder that differs from its
source) is moved to
`.claude-config/backup/skills-replaced/<name>-<UTC>/` first, with a `BACKUP`
line naming the path, and moved back if the install fails. Test:
`tests/skills-vendor-test.sh`.

## `mcp-http-call.py` and `await-approval`: scripts that talk to an MCP server

Both are standard-library Python and carry no server name: where they talk is
configuration, and a copy that sets none of it refuses to run and says what is
missing.

`mcp-http-call.py` is the script-side MCP client (Streamable HTTP). Use it, not a
hand-rolled client, whenever a tool call has to go over HTTP instead of through
a Claude session: a payload too big to send through a turn (the content travels
from disk to the API and never passes through token re-emission, where unchanged
sections can drift), a timed one-shot, or a loop over many items.

```
mcp-http-call.py [--server NAME] list
mcp-http-call.py [--server NAME] call <tool-suffix> <args.json> [out.json]
mcp-http-call.py [--server NAME] batch <calls.jsonl> <out.jsonl>
```

The endpoint is `OPS_MCP_URL` (one endpoint), or, with `--server NAME`,
`OPS_MCP_URL_TEMPLATE` with `{server}` filled in (a gateway that serves many
endpoints; NAME is checked against `[a-z0-9][a-z0-9-]{0,40}` so it cannot
rewrite the host or path). Nothing defaults, so a call can never land on the
wrong system because a name was left out. Only http and https URLs are accepted,
and a redirect is refused and never followed, because the bearer key would ride
along. The key is `OPS_MCP_API_KEY` in the environment, else that line of
`$OPS_DIR/.env` (default `~/OPS/.env`), and is never printed;
`OPS_MCP_KEY_VAR` names a different variable, and `OPS_MCP_CLIENT_NAME` sets the
`clientInfo.name` a server-side audit log groups calls by. `batch` checks the
whole calls file first (a bad file opens no session and clears the out file),
then runs every line (`{"tool": "<suffix>", "args": {...}}`) in one session and
writes one result line per call. It stops at the first failure (exit 1): a
JSON-RPC error, an `isError` answer, an unknown tool, or an in-band refusal
(`success: false`, an `error` or `error_code` field, `status` failed or
partial, `partial: true`). A call interrupted by a network error, a timeout or
SIGTERM/SIGHUP is written with `"state": "unknown"`: read back before any rerun.
`call` prints the answer as it is and does not judge in-band refusals; check the
body. Tool suffixes match only at the namespace boundary (`invoice_query` finds
`billing__invoice_query`, `query` finds nothing). Every run closes its session
with an HTTP DELETE in a `finally`, also on SIGTERM and SIGHUP (only SIGKILL
skips it): a server counts live sessions per key and reaps an idle one only
after a timeout, so a client that opens a session per call and never closes it
leaks one per call until the cap refuses every new session. Server text printed
on an error has the key scrubbed, and every out file is written 0600 (results
can carry secrets). Writes: pass an idempotency key where the tool takes one,
and never re-run a call that timed out; read back instead. Test:
`tests/mcp-http-call-test.sh`.

`await-approval <id> [--kind NAME] [--timeout SEC]` is the waiter for an approval clicked out of band (a remote session, a write grant, a deploy gate) on a host with no webhook callback: it long-polls a status tool through `mcp-http-call.py` and prints one state line, so run it with `run_in_background` and an explicit Bash timeout of at least 1900000 ms and its exit wakes the idle thread with no typed "Approved". Exit codes, all of them: 0 approved (the request is OPEN, and for a kind with a `usable_field`, usable by this caller); 3 not approved and never will be, with `state=` naming why: `denied` (the approver pressed Deny: status CLOSED with reason denied, or a bare DENIED status), `expired` (the pending window ran out), `closed` (any other close), or `not_usable` (the request is OPEN but another caller made it, so acting on it would be refused); 124 the timeout (default 1860 s, a 1800 s pending window plus margin) passed with the request still PENDING; 2 an error (bad usage or configuration, no caller, no API key, a refused key, an id the server does not know, an unreadable answer, five transient failures in a row); 128+N the waiter was stopped by signal N before an answer (`state=interrupted`: 143 SIGTERM, 130 SIGINT, 129 SIGHUP). The script header carries the same table, the on-exit guidance, the status contract the tool must answer and what a box needs.

Which server, tool and arguments are configuration, in `$AWAIT_APPROVAL_CONFIG` or `~/.config/ops/await-approval.json` (an explicit path that is missing is an error; the default path may be absent). Each named kind sets `server` (an endpoint name for `--server`, or `null` for `OPS_MCP_URL`), `tool`, `args` (the string `"{id}"` becomes the id and `"{wait}"` the wait in whole seconds), an optional `record` (the answer key that holds the status record) and an optional `usable_field` (the answer key that says whether this caller may use an OPEN request); `default_kind` picks the kind when `--kind` is not given, and `key_connectors` names `mcpServers` entries of `~/.claude.json` whose literal `Bearer <key>` header is the last-resort key (a `${VAR}` reference is not a key; the key reaches the poll through its environment only, never argv or a file). With no file, the built-in kind `default` calls `approval_status` with `{"id": <id>, "wait_s": <seconds>}` on `OPS_MCP_URL`. The tool answers `status` PENDING, OPEN, CLOSED or EXPIRED, an optional `close_reason`, and holds the call until the request changes or about 40 s pass, so a click ends the wait at once; a poll that returns early with PENDING is paced to at least 3 s. Each poll is one run of `mcp-http-call.py`, so at most one session per waiter is live, and SIGTERM, SIGINT and SIGHUP reach the poll in flight so its session still closes. A transient failure (a 5xx, a 429, a dropped connection, an `isError` answer) is retried up to 5 times in a row; a refused key, an unknown endpoint or tool, a missing configuration and any in-band `error` answer stop at once, and the HTTP status is read where the client puts it, in the first `ERROR: ` line, never in the quoted response body. The line prints only the first 8 characters of the id, never an approve URL, and every key value and bearer token is scrubbed from server text. Tests: `tests/await-approval-test.py` (against a stub of the caller, 100+ cases including each signal, every exit code and the header and this section agreeing).

## `wf-resume`: lanes of a workflow that never returned

A usage-limit hold, a crash or a restart ends every running lane of a dynamic
workflow at the same second, and no notification says so: the workflow just never
returns. `wf-resume` reads the run's `journal.jsonl` and the lane transcripts
under `<projects>/<workspace>/<session id>/subagents/workflows/<run id>/`, lists
the lanes that never returned, and prints how to relaunch them. A lane's final
state is its key's last journal row; `started` with no later `result` or `failed`
means it never returned. Each such lane is `interrupted` (its transcript ends on
the interrupt marker: dead, not slow), `idle` (no activity for `--stale-min`
minutes, default 15; advisory, since a long tool call can be quiet that long) or
`active` (do not relaunch: a second copy writes the same worktree). For a lane
that worked in a linked git worktree it also prints the branch, the changed-file
count, the commits ahead of the default branch and the last commit, with
read-only git (`--no-optional-locks`, so even `status` leaves a live lane's
index and its lock alone). Nothing is written, killed or relaunched.

```
wf-resume                  list this session's runs ($CLAUDE_CODE_SESSION_ID)
wf-resume --session ID     list another session's runs
wf-resume RUN              detail one run: a run id (wf_...), a transcript dir or a journal.jsonl path
wf-resume ... --json       the same facts as JSON
```

Exit 0: nothing never returned; 1: at least one lane never returned; 2: a usage
or read error. The relaunch line is the `Workflow` call with the persisted
script and `resumeFromRunId`, plus the rules that keep it safe: confirm the
workflow task ended first, never message a workflow lane (relaunch the script),
put the resume note in the never-returned lanes' prompts only (an edited prompt
of a returned lane misses the cache and runs again), and skip a lane whose
branch you took over. `WF_RESUME_PROJECTS` (colon-separated) overrides the
projects directories; `WF_RESUME_TZ` (an IANA zone name) sets the zone times
print in, default the machine's local one. Test: `tests/wf-resume-test.sh` (a
fixture run with every lane state, a real linked worktree whose index must stay
byte-identical, and, when a `dynamic-workflows` skill is mounted with its args
prelude, that prelude run against every args shape that crashed scripts).

## `lane-class`, `await`, `safe-pkill`, and `hooks/lane-rules.sh`: lane boots and shell stumbles

Lanes (subagents, workflow lanes, delegated threads) repeat the same few shell
stumbles, and a memory note does not stop them, because a lane never loads
memory: an in-process lane gets `core.md` and nothing else, and a delegated
thread gets the foreman boot. So the rules ride in what fires.

- `lane-class`: prints `foreman`, `t3-lane` or `agent-lane` and exits 0,
  always, in well under 300 ms. `agent_id` in the hook JSON on stdin is
  `agent-lane`. A T3 thread id with a `thread:delegated-task:` or
  `thread:provider:` prefix, a state-db lineage of `relationshipToParent=subagent`,
  or a first user message that opens "Act as the ... sub-agent for this task." is
  `t3-lane`. Anything it cannot resolve is `foreman`. The ambient
  `T3CODE_THREAD_ID` counts only for the session the payload names (its
  `session_id` must equal `CLAUDE_CODE_SESSION_ID`), so a hook test run from
  inside a delegated lane still sees a foreman. `--self` classifies the caller
  from its own environment; `OPS_LANE_CLASS` forces an answer (a test seam and an
  operator override). The script header has the evidence order. Consumers call it
  as `"$H/.claude-config/bin/lane-class" <<<"$HOOK_JSON" 2>/dev/null || echo foreman`,
  so a missing script degrades to a foreman: a lane that wrongly boots as a
  foreman wastes tokens, a foreman that wrongly boots as a lane loses its rules.
  Consumers: `session-briefing.sh` (a lane gets one line), `foreman-context.sh`,
  `memory-hint.sh`, `report-lint.sh` and `lane-rules.sh`.
- `await [--timeout SEC] [--every SEC] -- <check...>` (also `--pid PID` and
  `--file PATH [--grep ERE]`): reruns the check until it exits 0 (exit 0) or the
  time is up (exit 124, last output on stderr). The sanctioned replacement for
  `sleep N; check`, which Claude Code refuses: the pause is inside the script,
  so the Bash tool sees one ordinary command. Run it with `run_in_background`
  for a wait over about 100 s (the default timeout is 110). A hanging check is
  stopped at the deadline. Command checks and `--file --grep` need GNU `timeout`
  or `gtimeout` (exit 127 without one, never an unbounded check). Pauses are
  interruptible, including a long `--every`. Exit 2 usage, 127 missing command,
  130 or 143 interrupted. Test: `tests/await-test.sh`.
- `safe-pkill` (also `safe-pgrep`): `pkill` and `pgrep` that leave the caller's
  own process chain out of the match set. The Bash tool runs every command as
  `bash -c '<the whole command line>'`, so `pkill -f "<text in my own command>"`
  matches the shell that runs it and takes the caller down, and
  `until ! pgrep -f X` never ends because its own command line holds X. It uses
  procps' `-A` where it exists and an ancestor filter over the real `pgrep`
  where it does not. It never refuses a command and never narrows which other
  processes a pattern reaches, so a pattern can still hit a sibling lane's
  process: the lane rule says to kill an exact PID, and this is for the case
  where a pattern is unavoidable. Every call is logged to
  `${OPS_STATE_DIR:-~/.local/state/ops}/safe-pkill.log`, and under its own name
  it prints each process it killed on stderr. `safe-pkill --install-shims [DIR]`
  links `pkill` and `pgrep` into `~/.local/bin` so the plain commands are safe
  too, and `--remove-shims` undoes it; both are your call, run by hand. `deploy.sh` never
  installs them. Test: `tests/safe-pkill-test.sh` (the caller dies under plain
  `pkill -f` and lives under `safe-pkill`, on both code paths).
- `hooks/lane-rules.sh`: prints a short shell-rule block for `SubagentStart` (as
  `additionalContext` JSON) and, for a `t3-lane`, at `SessionStart`; a foreman
  gets nothing. The block says: never `sleep N; check` (use `await`), one simple
  command per call in an isolated worktree with `git -C`, never `pkill -f` or
  `pgrep -f` by pattern (kill an exact PID or use `safe-pkill`), the tool is
  `Bash` with a capital B, load a deferred tool with `ToolSearch select:<exact
  name>` after a compaction, and print and check a variable path before
  `rm -rf`. The `ops-worker`, `ops-investigator` and `ops-auditor` agent
  definitions carry the same block, and a lane whose definition has it is not
  told twice; `lane-rules.sh --block` prints the text, which
  `tests/lane-rules-test.sh` compares to the agent definitions. This is context
  injected at lane start, not a command gate: nothing in it refuses or rewrites
  a command. The Stage-1 settings register it on `SubagentStart` and
  `SessionStart`.
- Tool re-select after a compaction (`hooks/mcp-reselect.py` with
  `pre-compact.sh` and `post-compact-resume.sh`): a compaction drops every
  deferred tool's schema, and a call to an unselected deferred tool fails far
  more often than one to a selected tool. `pre-compact.sh` records the deferred
  tools called since the previous compaction in the snapshot, and
  `post-compact-resume.sh` prints them most-recently-used first and says to
  select lazily (one name, just before its first call). `tests/pre-compact-test.sh`
  pins the snapshot section and `tests/post-compact-resume-test.sh` the block.

- The lane gate in the hooks that talk: `context-watch.sh` stays silent on
  Stop and in its readout for a lane, and gives a T3 lane its own 60% and 80%
  context lines keyed on its session; `session-briefing.sh` prints one line for
  a lane and starts nothing. `context-watch.sh` caches each session's
  `lane-class` answer in its run directory (30 minutes; a failed ask, 2
  minutes) and cuts a hung classifier at 2 seconds.
- Per-thread work keys and the leftover-stamp scan (`hooks/hooklib.sh`): under
  T3 Code the work key is `t3-<session id>`, stable across compaction and
  resume, so two threads in one directory keep separate stamps and work logs.
  A session stamp left behind is judged by evidence (real commits in its
  window), never by age alone, and the scan runs detached off the boot path at
  most every 30 minutes (`OPS_ORPHAN_SCAN_INTERVAL`, seconds; `OPS_ORPHAN_SCAN=sync`
  runs it inline; `OPS_ORPHAN_LOCK=mkdir` forces the portable lock where
  `flock` exists). It reports and never
  removes or moves a stamp. `OPS_STATE_DIR` (default `~/.local/state/ops`)
  holds the hooks' state and logs.

Tests: `tests/lane-class-test.sh`, `tests/await-test.sh`, `tests/safe-pkill-test.sh`,
`tests/lane-rules-test.sh`, `tests/session-briefing-lane-test.sh`,
`tests/session-briefing-scope-test.sh`, `tests/work-session-key-test.sh`,
`tests/orphan-gate-test.sh`, `hooks/context-watch-selftest.sh`,
`hooks/foreman-context-selftest.sh` and `tests/post-compact-resume-test.sh`.

## `tests/`

Runnable suites for the scripts above and for deploy's rc and core-link
wiring (`deploy-rc-wiring-test.sh`, which extracts the real functions from
`deploy.sh` and runs them against mktemp fixtures with a `sudo` shim, never a
live rc). Each exits 0 when every case passes. A suite that starts with the
sandbox guard exits 97 outside `sandbox-run`, so every suite runs through it
from the checkout root, except the sandbox's own tests, which start
`sandbox-run` themselves. The command that runs them all, with the
`*-selftest` scripts beside their subjects and the PowerShell suites, and
exits non-zero if any fails, is step 2 of "Before you open the PR" in
`CONTRIBUTING.md`; CI runs the same loops (`.github/workflows/gate.yml`).
One file, one command: no second copy here to drift.

`tests/ci-gate-test.py` runs the gate's JavaScript check over every tracked
`.js` and a set of fixtures. Under `sandbox-run` it skips when `node` lives in
your HOME (nvm, fnm), which the sandbox hides, and says so; run it bare then.
In GitHub Actions a missing `node` fails it instead.

## `grabit`: file transfer over Tailscale

Moves files between a (usually headless) OPS box and whatever machine you're
driving it from, without SFTP or cloud. Everything rides the tailnet
(WireGuard-encrypted) and is **never public**: the browser mode uses
`tailscale serve`, not `funnel`.

```
grabit FILE...              push file(s) to the machine you're SSH'd in from (auto-detected)
grabit --to DEVICE FILE...  push to a specific tailnet device (name or 100.x IP)
grabit --serve PATH...      stage path(s) + expose over tailnet HTTPS; prints browser URLs
grabit --serve-off          tear the serve endpoint down
grabit --inbox [DIR]        pull files someone sent TO this box (default ~/grabit-inbox)
grabit --list               list tailnet devices
grabit -h
```

### How the default (push) works
`grabit report.pdf` reads `$SSH_CONNECTION` to learn which tailnet device you
connected from and Taildrops the file straight to that machine's Tailscale
inbox. **Windows auto-saves received files to your Downloads folder** (no tray
prompt); on macOS/Linux run `tailscale file get ~/Downloads`. Wherever you SSH
in from, the file comes back to you: no flags.

### Two modes, when to use which
- **Push (default):** one-shot, no sudo, lands in your inbox. Best for grabbing
  a file or two.
- **Serve (`--serve`):** stages the named files into `~/.cache/grabit-serve` and
  serves *only those* over tailnet HTTPS. Best for browsing/grabbing several
  files, or when the target isn't a Tailscale device. Needs sudo (serving a path
  is privileged): that's why push is the default.

### Safety
`--serve` only ever exposes files you explicitly name (staged into a scratch
dir), so a neighbouring `.env` or secret can't leak. The serve endpoint is
tailnet-scoped (your own devices), not the public internet.

### One-time setup per new box
```
sudo tailscale set --operator=$USER     # lets push run without sudo
```
Taildrop must be enabled for the tailnet (it is by default). If `--serve` is
needed, the box also needs passwordless sudo for `tailscale` and tailnet HTTPS
enabled in the admin console.

### Put it on PATH (optional)
```
export PATH="$HOME/OPS/.claude-config/bin:$PATH"
```
Otherwise call it by path, or let your Claude Code session invoke it for you.
