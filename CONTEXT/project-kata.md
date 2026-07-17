# Project Kata

> A portable system for organizing any repository — documentation,
> scaffolding, and the rules that hold them together. Not tied to a
> particular project, language, or domain. Apply wherever the doc set
> is starting to sprawl, the root directory is growing files faster
> than rules, or a new project needs a sane starting shape.
>
> The core fits on one page. If you remember six rules, one directory
> layout, and the scaffolding checklist, you have it.
>
> **This file is mandatory reading for any task that creates,
> scaffolds, organizes, or modifies a project or repository.**
> Operator-specific overlays live at the bottom (`BOOTSTRAP.md` fills
> them in); everything above the overlays is portable and applies to
> any repo.

---

## The six rules

These are the only rules. Everything else in this file is mechanics
that follow from them.

1. **The root holds canonical entry points only.** A repo's root has
   four documentation files, no more:
   - `README.md` — _what exists_. The first file a visitor reads.
   - `CONTRIBUTING.md` (or your project's equivalent — `CLAUDE.md`,
     `AGENTS.md`, `STYLE.md`, etc.) — _how we work in this repo_. The
     first file a contributor reads.
   - One spec / rulebook file (commonly `RULEBOOK.md`, `SPEC.md`,
     `RFC.md`, or `ARCHITECTURE.md`) — _the rules of the road_. The
     authoritative document everything else defers to.
   - `CHANGELOG.md` — _every merged change_. The history.

   Any new file at the root needs a positive justification, not just
   "couldn't think of where else to put it." If you want to add a
   fifth root file, your rulebook gets a note explaining the
   exception.

2. **`docs/` holds every deep-dive.** Runbooks, lifecycle
   walkthroughs, migration playbooks, backlogs, deep architectural
   discussions. Anything longer than a paragraph that doesn't fit
   one of the four canonical files goes here. Every file in `docs/`
   opens with a one-line "what this is" and ends with a "see also"
   pointer back to related docs.

3. **Component-specific docs live next to their code.** If a doc is
   only meaningful in the context of a single directory, that's where
   it lives. Examples:
   - `<component>/README.md` for per-component notes
   - Schema or data-model docs adjacent to the schema files
   - Per-module READMEs in monorepos

   The test: would a contributor working on this component find the
   doc faster from the directory listing or from a `docs/` index?
   If the directory listing wins, the doc belongs there.

   **User-facing help is the same principle, applied externally.**
   If the project has a UI and non-technical users, user-facing docs
   live where users find them — in-app, a `/docs` route, a customer
   portal — not in the repo root. Repo docs are for contributors;
   user docs are for users. Don't mix them.

4. **No fact lives in two places.** If you find yourself writing the
   same paragraph twice, one of them must become a link by anchor.
   Cross-link instead of duplicating. The rulebook is the source of
   truth for _rules_; everything else references it. The README is
   the source of truth for the _infrastructure surface_; everything
   else references that.

5. **Drift is a bug.** A PR that touches a documented surface either
   updates the doc in the same PR or leaves a dated TODO at the top
   of the doc and a tracked task elsewhere. Stale docs are worse than
   missing docs because they actively mislead. Treat doc-staleness
   the way you treat broken tests. **When code and docs disagree,
   code wins.** The doc gets fixed in the same PR; flag as tech debt
   only if explicitly deferred.

6. **Soft cap on file lengths.** README around 500 lines. The
   spec/rulebook is the deliberate exception (it's a spec). Any other
   file approaching the cap is a signal to split it. A long file
   isn't comprehensive — it's a sign the topic isn't carved up well
   yet.

That's the whole kata. The rest of this file is application detail.

---

## The directory layout

```
<repo>/
├── README.md             What exists
├── <RULEBOOK>.md         The rules
├── <CONTRIBUTING>.md     How we work
├── CHANGELOG.md          Every merged change
└── docs/
    ├── README.md         Index + the six rules + per-repo specifics
    ├── <runbooks>.md     Operational procedures
    ├── <deep-dives>.md   Lifecycle / subsystem walkthroughs
    ├── <backlog>.md      Unscoped + scoped task list
    └── migrations/       One-time playbooks
        └── <NAME>.md
```

Sub-categorization inside `docs/` is by content type, not by
filename prefix. A four-line table at the top of `docs/README.md`
groups entries:

| Category            | What it is                            | Examples                                      |
| ------------------- | ------------------------------------- | --------------------------------------------- |
| Runbook             | Things an operator does on demand     | `BOOTSTRAP.md`, `DEPLOY.md`, `DR.md`          |
| Lifecycle deep-dive | End-to-end walkthrough of a subsystem | `SECRETS.md`, `NETWORKING.md`, `DATA-FLOW.md` |
| One-time playbook   | Procedure for a single cutover        | `migrations/<NAME>.md`                        |
| Backlog             | Unscoped + scoped work                | `IDEAS.md`, `ROADMAP.md`                      |

Migrations get their own subdirectory because they're write-once,
historical-after — they shouldn't crowd the active runbooks.

---

## The README ↔ CONTRIBUTING boundary

The two most-read files in any repo are the README and the
how-we-work file (CONTRIBUTING.md, CLAUDE.md, AGENTS.md — whatever
the project calls it). They have distinct jobs and content drifts
between them constantly if the boundary isn't enforced.

**The rule:** if it changes when the infrastructure changes, it's a
README item. If it changes when the workflow or tooling changes,
it's a CONTRIBUTING/CLAUDE.md item.

| Goes in README                          | Goes in CONTRIBUTING/CLAUDE.md         |
| --------------------------------------- | -------------------------------------- |
| What the project is and does            | How we work in this repo               |
| Requirements / dependencies             | Where to put new files                 |
| Getting started / installation          | Code style and naming conventions      |
| Server, infra, and deployment maps      | Branching and PR rules                 |
| Configuration surface                   | Examples of good patterns              |
| Examples and troubleshooting            | Tooling, agents, dev workflow          |

Cross-link by anchor, never copy-paste. If a fact lives in both
files, one of them is going to go stale and you won't notice until
it bites someone.

---

## Each doc's shape

Every file in `docs/` follows the same pattern:

```markdown
# <Title>

> One-line "what this is". A reader who only reads this line should
> know whether the rest of the doc is what they want.
>
> Authoritative pointers: <root spec> § <section> (rules), <other
> related doc> (related procedure). This file is the _map_; the
> spec is the rules.

---

## <First substantive section>

...content...

---

## See also

- `<related doc 1>` — what it covers
- `<related doc 2>` — what it covers
- `<root spec>` § <section> — the underlying rule
```

The opening blockquote and the closing "See also" are
non-negotiable. They make a doc skimmable and link the doc graph.

---

## Adding a new doc

The procedure when something needs to be written down:

1. **Check whether it belongs in an existing doc.** New docs earn
   their place when the topic is clearly distinct AND the content
   would bloat an existing file past its soft cap. If neither is
   true, append to the existing doc.

2. **Decide where it lives:**
   - Root? Almost never. Unless it joins the four canonical files,
     adding to root needs a rulebook update.
   - `docs/`? Default for cross-cutting deep-dives.
   - `docs/migrations/`? One-time cutover playbooks only.
   - Adjacent to code? Yes for component-specific notes.

3. **Add a row to `docs/README.md`** with a one-line "what it
   covers". Don't skip this — an unindexed doc is invisible.

4. **Add a "see also" footer** to the new file pointing at the
   relevant entry points (the rulebook section it derives from, any
   sibling docs).

5. **Update the rulebook only if the directory shape itself
   changes** (new subdirectory under `docs/`, new convention).

6. **CHANGELOG entry.** Always.

---

## Project scaffolding

Documentation rules govern an existing repo. Scaffolding rules
govern how a new one starts. The kata is opinionated about both
because the wrong starting shape produces sprawl no amount of
discipline can fix later.

### The init flow

When creating a new project, ask before scaffolding. Use structured
multiple-choice questions, not open-ended ones:

1. **Initialize a git repo?** — `Yes (recommended)` / `No`
2. **Project type?** — `Work` / `Personal` (drives license + copyright defaults — see overlays)
3. **Public or private?** — `Public` / `Private`
4. **License?** (Work, or Personal+Public) — `MIT (default)` / `Apache 2.0` / `None`
   - Personal + Private: skip license entirely.

Don't scaffold past these questions. If any answer is unclear, ask
before creating files.

### Required files at the root

Every git-initialized project starts with these files. They are
exempt from Rule 1 (canonical entry points) — they're not
documentation, they're tooling configuration.

**`.gitattributes`** — prevents line-ending and binary-diff issues
between Windows and Linux contributors:

```
# Auto-detect text files and normalize line endings
* text=auto

# Force LF for shell and scripting
*.sh text eol=lf
*.py text eol=lf
*.js text eol=lf
*.ts text eol=lf
*.json text eol=lf
*.yml text eol=lf
*.yaml text eol=lf
*.md text eol=lf
*.css text eol=lf
*.html text eol=lf

# Force CRLF for Windows-native scripting
*.ps1 text eol=crlf
*.bat text eol=crlf
*.cmd text eol=crlf

# Binary — never diff or normalize
*.png binary
*.jpg binary
*.jpeg binary
*.gif binary
*.ico binary
*.zip binary
*.gz binary
*.pdf binary
*.woff binary
*.woff2 binary
*.ttf binary
*.eot binary
```

**`.gitignore`** — baseline patterns. Extend with
language/framework-specific entries based on the stack:

```
# Secrets
.env
*.key
credentials.*

# OS
.DS_Store
Thumbs.db
desktop.ini

# Editors / IDEs
.vscode/
.idea/
*.swp
*.swo
*~

# Agent tooling
.claude/

# Python
__pycache__/
*.pyc
*.pyo
.venv/
venv/

# Node
node_modules/
package-lock.json

# Build artifacts
dist/
build/
*.log
```

`.claude/` is in the baseline for Claude Code and desktop-agent
workflows. If the project uses other agent tooling (`.cursor/`,
`.aider/`, etc.), add those too. None of these should ever be
committed.

**`README.md`** — at minimum, project name and a one-line description.

### Public-repo additions

Public repos take everything above, plus:

**Sensitivity banner** at the top of `README.md`, directly below
the title:

```
> **This is a public repository.** Do not commit API keys, passwords,
> tokens, internal URLs, or any credentials. Use `.env` for secrets
> and verify `.gitignore` is working before every commit.
```

**`LICENSE`** file based on the user's choice. Copyright line
depends on project type — see overlays.

**`.env.example`** if the project uses environment variables —
document every required variable with placeholder values, never
real credentials.

**Tighter `.gitignore` review** — confirm coverage of all secret
patterns, build outputs, and environment-specific files before the
first push.

### Private-repo notes

- `.gitignore` still covers secrets — private isn't an excuse for
  laziness here. Repos get cloned, forked, and re-shared.
- No `LICENSE` needed unless explicitly requested.
- README doesn't need the sensitivity banner, but should still note
  if the project uses `.env` and point to `.env.example`.

### The four canonical files, instantiated

The kata's Rule 1 lists four canonical roles. For most repos that
follow this kata, the files are:

| Role                      | File                | What it is                          |
| ------------------------- | ------------------- | ----------------------------------- |
| What exists               | `README.md`         | Infra surface, requirements, setup  |
| How we work               | `CONTRIBUTING.md` or `CLAUDE.md` | Workflow, tooling, conventions |
| The rules / spec          | `ARCHITECTURE.md`   | System design, decision records     |
| Every merged change       | `CHANGELOG.md`      | Keep a Changelog format             |

`ARCHITECTURE.md` is the spec/rulebook slot — required only for
mid-to-large projects. Break it out of `README.md` when the README
crosses ~500 lines (the kata's soft cap) or when three or more
major sections start competing for space (infra maps, data flow,
service dependencies, onboarding).

### Secrets handling

Secrets never live in the repo. The pattern:

- A `SECRETS.md` pointer file is allowed at the root or in `docs/`
  — it lists *where* credentials actually live (1Password, Key
  Vault, vendor-specific stores). It contains zero secrets itself.
- Pair with a pre-commit hook that blocks `.env` files and common
  credential patterns from reaching staging.
- `.env.example` documents the surface; `.env` (gitignored) holds
  the real values locally.

### Image-publishing repos: GHCR retention workflow

Any repo that publishes container images to GHCR gets a retention
workflow at scaffold time — registries accumulate versions forever,
and the cost surfaces only after thousands of stale versions pile
up (one dashboard repo hit ~3,000 before its first cleanup).

The standard shape is `ghcr-cleanup.yml` using
`dataaxiom/ghcr-cleanup-action`, manual-first:

- `workflow_dispatch` only — no schedule until the config has
  proven itself on a real run.
- A `dry_run` input defaulting to `true` — nothing deletes until
  someone deliberately runs it dry, reviews, then runs it live.
- Keep the last N tagged versions (10-25 depending on release
  cadence).
- `exclude-tags` for `latest`, `prod`, and any sha pins.

Two platform gotchas, learned live:

- **`workflow_dispatch` only fires from the repo's GitHub default
  branch.** A cleanup workflow merged to a non-default working
  branch (e.g. a fork's long-lived integration branch) cannot be
  triggered until either the default branch is switched or the file
  lands on the default. Check this before declaring the workflow
  deployed.
- **Guessed package names 404.** The workflow's package list must
  name packages that actually exist in the registry — a plausible
  but never-published name fails the run. Always dry-run first and
  confirm the package exists and `latest`/pins are excluded before
  the real deletion.

### A note on backlogs

Per Rule 1, backlog files (`IDEAS.md`, `ROADMAP.md`,
`BACKLOG.md`) are not canonical entry points. They live in
`docs/`, not at the root. A backlog at the root is the most common
form of root sprawl in practice — resist it.

Keep the backlog one flat file (`docs/IDEAS.md`), not a
`docs/ideas/` subfolder. Folders of improvement files become
graveyards.

---

## Anti-patterns

The mistakes the kata exists to prevent.

### Root sprawl

Adding files to the root because "it's the most visible place."
Every file at the root competes with the four canonical files for
attention. Visibility is a fixed quantity; spending it on a
non-canonical doc is taking it away from the four that matter.

### Duplicated paragraphs

Writing the same thing in two places "for convenience." Convenient
to write, expensive to maintain — the second copy goes stale within
a quarter. Always link by anchor.

### Topic creep

A doc that started as "how X works" growing sections on Y, Z, and
W until it's a 1500-line everything-doc. Split when the table of
contents stops fitting on one screen.

### Phantom docs

Files that haven't been touched in 18 months and reference systems
that no longer exist. Either resurrect (update + verify) or delete.
A doc no one reads is fine; a doc that lies is dangerous.

### Setup-only files

Bootstrap or handoff documents that were useful once and are now
historical artifacts. After the bootstrap is done, fold the
permanent rules into the rulebook + how-we-work doc and delete the
setup file. Source-of-truth for "what to do today" should not
include "what we did to set this up two years ago."

### Migration playbooks left at root

A one-time cutover document at the root, three quarters after the
cutover ran. Move to `docs/migrations/` so the active runbooks
aren't crowded by historical procedures.

### "When in doubt, make a new file"

The opposite of the kata. If you can't decide where something
belongs, the answer is _not_ a new top-level file. It's a section in
an existing doc, plus a link.

---

## When to break the rules

The kata is a default, not a law. Break it when:

- **You're writing a spec.** Specs are long. The rulebook is allowed
  to exceed the soft cap because it IS the rulebook.
- **The rule conflicts with a tool's expectations.** Some tools
  expect specific filenames at the root (`LICENSE`, `SECURITY.md`,
  `CODE_OF_CONDUCT.md`, `.github/`). Those files get an automatic
  exception — they're not documentation in the kata's sense.
- **You're at the very start.** A brand-new repo with two files in
  total doesn't need a `docs/` directory. The kata kicks in when the
  doc set is starting to sprawl, not before.

When you break the rules, document why in the spec. A documented
exception is fine; a silent one is drift.

---

## A six-line check

Before merging a PR that touches docs, ask:

1. Did anything change at the documented surface? If yes, did the
   doc change in the same PR?
2. Is the file growing past its soft cap? If yes, can it be split?
3. Did I add a fact that already exists in another doc? If yes,
   delete one and link the other.
4. Did I add a new file at the root? If yes, why?
5. Did I add a new file in `docs/` without indexing it in
   `docs/README.md`?
6. Does the new doc have an opening "what this is" and a closing
   "see also"?

If all six answers are no/yes-as-appropriate, ship.

---

## Bootstrapping the kata in an existing repo

For a repo that doesn't have this structure yet:

1. Read every `*.md` at the root. Decide which of the four canonical
   roles each fills (or if it's a deep-dive that belongs in `docs/`).
2. Create `docs/`. Move every non-canonical `*.md` into it. Use
   `git mv` so blame stays intact.
3. Create `docs/README.md` with the index of moved files + the six
   rules from this kata.
4. Update every cross-reference. A `(?<![/.])\bFILE\.md\b` perl
   substitution with the right replacement is idempotent and safe.
5. Fold any "handoff" or "setup" files into the four canonical
   files. Delete the originals.
6. Open one PR titled "chore: consolidate docs into docs/, codify
   documentation philosophy". The diff should be: many file moves,
   one new index, four canonical files updated, zero new content
   added except `docs/README.md`.

The whole reorg is mechanical. The discipline is in keeping the
shape after the reorg.

---

## Why this works

The kata is built on three observations.

1. **Most docs are read at most once per project lifetime.** The
   four canonical files get read every time someone joins the
   project. Everything else gets read on demand. Treating them
   differently saves the canonical files from sprawl and lets the
   on-demand files live where they're easiest to find.

2. **The thing that kills documentation is drift, not absence.** A
   missing doc gets written when someone needs it. A wrong doc
   misleads forever. Rules 4 (no duplication) and 5 (drift is a bug)
   exist for this reason and are the most-violated.

3. **Conventions beat completeness.** A repo where every doc is in
   the right place is easier to navigate than a repo with twice as
   many docs in the wrong places. The kata trades documentation
   quantity for documentation findability.

If your doc set follows the kata, a new contributor's path is:

```
README.md → I now know what exists
CONTRIBUTING.md (or equivalent) → I now know how you work
RULEBOOK.md → I now know the rules
docs/README.md → I now know where to find the deep dive I need
```

Four files to read. Everything else is on demand.

---

## Sandboxed-agent git constraint

**Scope: sandboxed agent environments only** — any agent surface
that runs shell commands inside a sandbox against a host-mounted
filesystem (Anthropic's desktop app is the common case). Claude
Code, chat Claude, and any other environment have no such
constraint and handle git normally. Don't carry this rule outside
the sandbox.

**Inside the sandbox, 99% of repo work is fine.** Edit files, read
files, restructure folders, run scripts, browse history — all
normal. A sandboxed session is a perfectly capable environment for
working in a repo.

**The narrow exception** is git write operations (`add`, `commit`,
`push`, `merge`, `rebase`, `reset`, `tag`, etc.) run through the
sandbox shell. These create `.git/index.lock` files on the mounted
filesystem that persist after the command finishes and break
subsequent git operations on the host.

The rule:

- Read-only git commands (`status`, `log`, `diff`, `show`,
  `branch -l`) — fine in the sandbox.
- File edits, scaffolding, doc work, code changes — fine in the
  sandbox. The lock-file issue is about the `git` CLI specifically,
  not about touching files in a repo.
- Git write commands — don't run them from the sandbox shell.
  Either let the Operator run them outside the sandbox, or switch
  to Claude Code if a continuous build-commit-iterate cycle is
  needed.

This is a tooling workaround, not a kata rule. It lives here so it
has a single home.

---

## Operator overlays

Everything above this section is portable — apply it to any repo,
any team, any domain. This section is where the kata's portable
rules meet one specific setup: project portfolio layout, LICENSE
defaults, which file plays which canonical role, backlog
conventions, and anything else true of *your* machine and *your*
organizations but not true of the kata in general.

This section ships as a template. `BOOTSTRAP.md` fills it in on
first run — it asks a short set of structured questions (repo home
path, organization name(s), license defaults, which file plays the
spec/rulebook role) and writes the answers here as a living record.
Until bootstrap has run, treat the entries below as illustrative
only — they are not real configuration.

### EXAMPLE — project portfolio + license defaults

*(Synthetic. Replace this entire subsection with your own answers
during bootstrap — it shows the shape an overlay entry takes, not a
default to inherit.)*

Project repos live under `PROJECTS/<organization>/<repo>`. The
organization folder is mandatory — never drop a repo directly under
`PROJECTS/`. Example organizations for a two-context setup:
`ExampleCorp` (work), `personal` (side projects). New organizations
get added when warranted; the canonical description of current
clusters, cross-repo relationships, and keyword routing lives in
`PROJECTS/projects-map.md`.

| Project type | License default      | Copyright line              |
| ------------ | --------------------- | ---------------------------- |
| Work         | MIT                    | Copyright (c) Example Corp   |
| Personal     | None (skip the file)   | n/a — only add if asked      |

If a personal project is going public and a license is wanted, ask
before defaulting — don't auto-attach a work organization's name to
a personal repo.

### EXAMPLE — layered IDEAS files

*(Synthetic, same caveat as above.)*

The kata keeps each repo's backlog at `docs/IDEAS.md`. A portfolio
overlay can extend the same discipline upward, so every scope has a
place to park ideas that span its members but don't fit any single
one:

```
~/OPS/IDEAS.md                            # harness-itself + general
~/OPS/PROJECTS/IDEAS.md                   # cross-cluster portfolio
~/OPS/PROJECTS/<org>/IDEAS.md             # cluster-wide (shared doctrine, a vendor matrix)
~/OPS/PROJECTS/<org>/<repo>/docs/IDEAS.md # repo-scoped (lives in the repo's own git, per the kata)
```

Each file declares its scope at the top and routes anything
narrower down to the next level. IDEAS and TODO are interchangeable
in this layout — pick one and stick with it per file. CHANGELOGs
are not duplicated at cluster level (a cluster folder is a
grouping, not a project — track its changes via the parent harness
CHANGELOG).

Add further overlay entries below these the same way, as your
setup accumulates rules that are true of your machine but not true
of the kata in general (spec-slot naming, how-we-work file, backlog
tag taxonomy, and similar).
