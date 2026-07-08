# Projects Map

> Workspace map for the project portfolio under `~/OPS/PROJECTS/`.
> Describes the organization layout, the clusters you keep here, how
> repos inside a cluster relate, cross-repo conventions, and a
> keyword-to-repo routing table for ambiguous task requests.
>
> Read this file when a task involves a specific project repo, when
> deciding which repo a request belongs to, or when scaffolding a
> new project. Skip it for pure CONTEXT / WORKFORCE / NOTES work.
>
> Source of truth for the project layout. Per-repo internals live
> inside each repo's own `README.md` / `CLAUDE.md` / `ARCHITECTURE.md`.

> **This shipped copy is a starter template.** It carries one synthetic
> cluster (`ExampleOrg`) with placeholder repos so the layout, the
> conventions, and the routing table are visible on a fresh copy.
> `BOOTSTRAP.md` and your first real projects replace `ExampleOrg` with
> your actual clusters and repos. The structure below is what stays;
> the names are what you fill in.

---

## Organization layout

All project repos live under `~/OPS/PROJECTS/<organization>/<repo>`.
The organization layer is mandatory — never drop a repo directly
under `PROJECTS/`. Loose files at `PROJECTS/` root are reserved for
cross-cluster tooling (sync scripts, this map, a cross-cluster
backlog).

```
PROJECTS/
├── projects-map.md            # this file
├── sync-check.sh              # cross-repo sync verify (Linux/macOS)
├── Sync-Check.ps1             # cross-repo sync verify (Windows)
├── IDEAS.md                   # (optional) cross-cluster portfolio backlog
├── ExampleOrg/                # a cluster — one organization / body of work
│   ├── IDEAS.md               #   (optional) cluster-wide backlog
│   └── <repo>/                #   one git repo per subdir (gitignored)
└── AnotherOrg/                # a second cluster, added the same way
    ├── IDEAS.md
    └── <repo>/
```

**Adding a new organization.** Future-flexible — when a side project,
client engagement, or third-party collab gets enough repos to warrant
its own cluster, create `PROJECTS/<NewOrg>/` and add a section to this
file. Single one-off scripts/scratchpads belong in an existing cluster,
not a new top-level org folder.

**Layered backlog pattern.** Backlogs nest by scope: a workspace-level
one at `~/OPS/IDEAS.md`, a portfolio one at `PROJECTS/IDEAS.md`, a
cluster one at `PROJECTS/<org>/IDEAS.md`, and repo-scoped work inside
each repo's own git. Each level declares its scope and routes narrower
work down. These files are optional — create a level when it has
backlog worth tracking. For where a backlog file belongs *inside* a
repo, follow `CONTEXT/project-kata.md` § A note on backlogs (repo
backlogs live in `docs/`, not at the repo root).

**Gitignore behavior** (see `OPS/.gitignore`): `PROJECTS/*/*/` is
gitignored — only repo subdirs (2nd level deep) are ignored. Cluster
folders (`ExampleOrg/`, `AnotherOrg/`, …) and loose files at any level
are tracked. Each project repo (`<org>/<repo>/`) manages its own git.

---

## Clusters

| Cluster | Purpose |
|---------|---------|
| `ExampleOrg/` | *(example)* your primary body of work — swap for your real org. |
| `AnotherOrg/` | *(example)* a second cluster, added when a distinct body of work earns one. |

On a fresh copy there is one example cluster. Add rows here as you
create real clusters, and give each its own section below.

---

## Cluster: ExampleOrg (example)

*Placeholder cluster. Replace the repos, roles, and stacks with your
own.*

### Stack

| Repo | Role | Stack | Deploys to |
|------|------|-------|------------|
| `sample-app/` | Example application — API + web UI | *(your stack)* | *(your target)* |
| `sample-infra/` | Example infrastructure — IaC provisioning the hosts the app runs on | *(your IaC)* | *(your cloud)* |
| `sample-data/` | Example data layer — DB schema + sync workers the app reads | *(your DB)* | *(your host)* |

### How these repos relate

A short map of the dependencies between a cluster's repos lives here so
a session knows which repo a change belongs in. For the example:
`sample-infra` provisions the hosts; `sample-app` deploys onto them;
`sample-data` owns the schema `sample-app` reads. Keep infrastructure
diffs in `sample-infra`, application diffs in `sample-app`, and
cross-cutting changes in paired PRs that reference each other.

### Cluster conventions

A cluster can layer its own conventions on top of the universal ones in
`CONTEXT/working-preferences.md` and `CONTEXT/operating-doctrine.md`.
Record them here so every session applies them. Examples of what a real
cluster might pin:

- **CHANGELOG.md mandatory** on the deployable repos.
- **Secrets backed up to a single source of truth** (name it) — not
  scattered across files or password managers.
- **PR autonomy:** open and merge minor PRs on this cluster's repos
  without asking; escalate only on major or directional changes.

---

## Keyword routing

When the task description doesn't name a repo, use the keyword hints
below to pick the right one. If two match, ask before crossing repo
boundaries — infra and app changes belong in different PRs.

This table is illustrative; build it out to match your real portfolio
so ambiguous requests route correctly.

| User says… | Likely repo |
|------------|-------------|
| "api", "endpoint", "server" | `ExampleOrg/sample-app` (server) |
| "web", "UI", "frontend" | `ExampleOrg/sample-app` (client) |
| "terraform", "provisioning", "DNS", "host" | `ExampleOrg/sample-infra` |
| "schema", "migration", "sync worker", "entity data" | `ExampleOrg/sample-data` |
| "dotfiles", "shell setup" | external dotfiles repo (see below) |

---

## External to the PROJECTS/ tree

Some repos must live outside `PROJECTS/` — for example a dotfiles repo
whose files symlink into `$HOME`, where moving the directory would break
the symlink graph. Those aren't listed in the cluster tables above; note
them here for portfolio completeness, with their real location and why
they live outside the tree.

---

## When working in a project repo

This map exists to route you to the right repo. Once inside, the
per-repo docs take over:

0. **Sync first.** Run `git fetch && git pull --ff-only` on first
   entry into the repo each session. Repos are multi-machine;
   out-of-date clones cause silent rework. Same rules as the OPS sync
   in `~/OPS/CLAUDE.md` — `--ff-only` only, flag failures, don't
   auto-resolve.
1. Read the repo's `CLAUDE.md` (or `CONTRIBUTING.md` / `AGENTS.md`)
   for workflow + conventions.
2. Read the repo's `README.md` for the infrastructure surface.
3. Read the repo's `ARCHITECTURE.md` / `RULEBOOK.md` / `SPEC.md`
   when changes touch the spec.

If a per-repo doc disagrees with this map, the per-repo doc wins —
this map is the index, not the rulebook for any single repo.

---

## Drift discipline

Per kata Rule 5 (drift is a bug): this file is a documented surface.
When a project changes name, gets archived, gets split, or a new repo
joins a cluster, update this map in the same PR (or follow up with a
dated TODO at the top + a tracked task).

Common drift sources:
- New repos added to a cluster — add a row, add a keyword routing
  entry.
- Repos archived or merged — remove from the stack table, leave a
  one-line note if non-obvious.
- Deploy-target changes — update the table column.
- Relationship changes (new credential flow, new tool consumer) —
  update the "How these repos relate" section.

When a cross-cutting refactor lands, prefer updating this map *before*
the cluster-level work, so subsequent sessions don't operate on a
stale picture.
