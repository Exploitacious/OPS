# OPS

This repo is a copy of OPS, the Claude Code harness published as the
`Exploitacious/OPS` template: the context layer (`CONTEXT/`), the skills
library (`SKILLS/`), the deployers and hooks (`.claude-config/`), the
git-synced memory pools (`.claude-memory/`), handoff batons, and the projects
it manages (`PROJECTS/`). In the Operator's private copy it holds their
identity and work; in the public template it holds only generic mechanics.
This file is about working in this repo. The rules that bind every session
are in [CONTEXT/core.md](CONTEXT/core.md); nothing here restates them.

## Read first

`CONTEXT/core.md` should already be in your startup context: `deploy.sh`
links it into `~/.claude/rules/ops-core.md`. If it is not (no "# Core" in
what you were given), read it now, then proceed, and tell the Operator to
re-run `.claude-config/deploy.sh`. Everything else in `CONTEXT/` loads on
demand through the core's "Where to look" table; do not read those files as a
startup ritual.

First launch: if `CONTEXT/.bootstrapped` does not exist, this copy has never
met its Operator. Do not start normal work: read `BOOTSTRAP.md` and run it;
on a fresh copy the bootstrap is the session. If the marker exists, its
`stage=` value says which optional stages remain; offer the next one when the
current task allows.

## Build, test, land

- Gate: `bash .claude-config/bin/verify-ops.sh` after any harness change. It
  checks `~/OPS`; set `OPS_DIR` to check another checkout. Its host checks
  (the core link, the Stage-1 settings) still read `$HOME`, so on a machine
  with no deployed OPS run it in a throwaway `HOME` (DEPLOYMENT.md, "Testing a
  deploy under a throwaway HOME").
- Tests: `.claude-config/bin/tests/*-test.{sh,py}`, `.claude-config/bin/*-selftest.*`,
  and `.claude-config/hooks/*-selftest.sh`. Run the ones covering what you
  changed. A suite that runs a tool that deletes or moves files starts with
  the sandbox guard and runs only inside `.claude-config/bin/sandbox-run`
  (exit 97 elsewhere); the command line is in `.claude-config/bin/README.md`.
  Every shell script you touch passes `bash -n`; every workflow script parses
  (plain `node --check` is unreliable for them; CONTRIBUTING.md has the
  command CI uses). In the template repository, CI
  (`.github/workflows/gate.yml`) runs the syntax checks, every suite, a
  fresh-install smoke test with `verify-ops.sh`, and a secrets scan on each push
  and pull request; CONTRIBUTING.md has the same commands for a local run.
- `CHANGELOG.md` gets a dated entry for every notable change.
- Several sessions can share this checkout. Before pushing, run
  `git log --oneline origin/main..main`; if it shows commits that are not
  yours, push and reconcile with a merge, never a rebase over another
  session's commits.
- This copy pushes only to its own private origin. The git-guard hook runs
  `.claude-config/bin/origin-private-check` on the agent pushes it can parse
  here and blocks one it cannot verify, or one to another remote. It is a
  seatbelt, not a sandbox: DEPLOYMENT.md, "What Stage 2 does" step 8 ("The
  push gate"), lists its limits.
- Contributions to the public template go by PR and follow
  [CONTRIBUTING.md](CONTRIBUTING.md): port the mechanic, never paste the file,
  keep your private-term list out of every PR and commit, and push the PR branch
  with `GIT_GUARD=off` (the git guard blocks an unverified push by design).

## Conventions

- `SKILLS/` is the single source for skills, deployed through the
  `~/.claude/skills/` symlink. Mounted entries (`SKILLS/VENDORED.tsv`) are
  edited at their source repo and synced with
  `.claude-config/bin/skills-vendor.sh`; never edit the mirror or
  `~/.claude/skills/` directly.
- `.claude-config/`, `.claude-memory/`, and `.claude-handoffs/` are literal
  names; do not rename them.
- Personalization lives only in the files `harness-update` never syncs:
  `USER.md`, `voice.md`, `standing-orders.md`, the `work-tracking.md`,
  `team.md`, and `tools.md` slots, `.bootstrapped`, and `CONTEXT/projects/`.
  The doctrine files (`core.md`, `how-i-work.md`, `model-roles.md`,
  `project-kata.md`) stay generic, so a template sync can update them; an
  Operator ruling goes to `standing-orders.md` instead of an edit there.

## Invariants and bans

- Never write `~/.claude/settings.json`: on a linuxploitacious host it is a
  symlink into that tracked checkout, and a local edit fails its next
  `git pull --ff-only` whenever upstream changed the same file.
- Never publish a private copy or anything from `CONTEXT/`, `.claude-memory/`,
  `.claude-handoffs/`, `NOTES/`, `DELIVERABLES/`, or `PROJECTS/`: they hold
  the Operator's identity and work.
- `CONTEXT/core.md` stays under 15,360 bytes (`verify-ops.sh` check 16): every
  session and lane pays for it on every turn.
- No root `CLAUDE.md`. With one present, Claude Code reads it instead of this
  file and skips every `AGENTS.md` in the repos under `PROJECTS/`.

## Where to look

| Need | Home |
|---|---|
| What exists, the folder tree | `README.md` |
| Deploy (Stage 1 and 2), migration, T3 Code hosts | `DEPLOYMENT.md` |
| First launch | `BOOTSTRAP.md` |
| Template sync from upstream | the `harness-update` skill |
| Scripts, tests, and the gate | `.claude-config/bin/README.md` |
| Porting rules, the CI gate, local test commands | `CONTRIBUTING.md`, `.github/workflows/gate.yml` |
| Licenses of adapted third-party work | `SKILLS/THIRD_PARTY_NOTICES.md` |
| History | `CHANGELOG.md`, `git log` |
