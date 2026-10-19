# `.claude-config/bin/`: operator utilities

Small, tracked helper scripts that ship with OPS and sync to every machine.

## `compact-cycle.sh`: automated /compact for a Claude session in tmux

The deterministic half of the automated compact ritual (the judgment half is
the `pre-compact-synthesis` skill, which runs the synthesis and writes the
resume baton BEFORE spawning this). A session cannot fire `/compact` on itself,
so this spawns a detached `Compactor-<Key>` tmux session (plain bash, no Claude)
that waits for the target pane to go idle, types `/compact`, watches until
compaction completes, types the baton (or `--resume` text) as the next user
message, and self-destructs. On error/timeout it never types the resume: the
target stays paused with synthesis already on disk.

```
compact-cycle.sh --target <Session|Session:win.pane> [--baton FILE] [--resume "TEXT"]
                 [--no-resume] [--grace S] [--idle-timeout S] [--timeout S]
```

Runtime state (locks, logs, status, batons): `~/.claude-compact-cycle/`.
Consumers: the skill's self-compact exit, the `[context-watch]` escalation
ladder (`hooks/context-watch.sh`: Stop nags at 65/78/86/92% of the window
plus mid-turn PostToolUse injections from 86%; both registered in the Stage 1
`settings.json` template); `--no-resume` serves a session that re-wakes on
its own. tmux gotcha baked in: targets use the `=Name:` exact form:
bare names unique-prefix-match and pane-level commands reject bare `=Name`.

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
`ANTHROPIC_DEFAULT_HAIKU_MODEL` pin that is not exactly that id.
`verify-ops-selftest.sh` sources the gate and drives those checks plus the
SessionStart matcher check against fixture trees under a throwaway `HOME`.

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
never a URL's credentials. Callers commit regardless and push only on 0. For a
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
content comparison where installed and tar otherwise. Honors `OPS_DIR`. Deploy
clones the public source once and runs `sync`. It never deletes a folder it
did not write: `SKILLS/.vendored-state.tsv` records a digest of each mirror,
and a destination that is not a known mirror (your own skill under a mounted
name, a hand-edited mirror) is moved to
`.claude-config/backup/skills-replaced/<name>-<UTC>/` first, with a `BACKUP`
line naming the path, and moved back if the install fails. Test:
`tests/skills-vendor-test.sh`.

## `tests/`

Runnable suites for the scripts above and for deploy's rc and core-link
wiring (`deploy-rc-wiring-test.sh`, which extracts the real functions from
`deploy.sh` and runs them against mktemp fixtures with a `sudo` shim, never a
live rc). Each exits 0 when every case passes:

```bash
for t in ~/OPS/.claude-config/bin/tests/*.sh; do bash "$t" || echo "FAILED: $t"; done
```

The older `*-selftest.sh` scripts beside their subjects (`verify-ops`,
`model-probe`, `claude-window-ping`, and the hooks) work the same way.

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
