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

`python3 plugin-retire-selftest.py` exercises only the plugin-retirement blocks
of both deployers under temporary homes: declarations stay unchanged, absent
plugins are quiet, and failed removals warn. It uses a local real Claude CLI
when available as well as a mock; neither path downloads plugins or calls an API.

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
pool directory is gone (run `memory-init`). `verify-ops-selftest.sh` sources
the gate and drives those checks plus the SessionStart matcher check against
fixture trees under a throwaway `HOME`.

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
`ac-memory-*`). Tests: `tests/memory-index-test.sh`, `tests/memory-init-test.sh`,
`tests/memory-init-windows-test.ps1`.

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
