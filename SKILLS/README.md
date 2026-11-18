# SKILLS: source library for Claude skills and GUI projects

This folder is the **authoritative source** for the local, OPS-specific Claude capabilities the Operator maintains across machines. A skill holds only what a capable agent with a fresh context could not know (this copy's systems, house standards), never procedure: a behavior rule goes to doctrine (`CONTEXT/core.md`), a repo fact to the repo, a mechanical step to a script or tool. Shared skills are mounted from their one source repo instead (see "Skill sources" below). Each subfolder is one "library entry" that can deploy in two places:

1. **Claude Code (CLI)**: as a Skill, lazy-loaded by trigger description. Deployed via `~/.claude/skills/` symlinked directly to this folder. One hop. Cross-platform via `.claude-config/deploy.ps1` (Windows) or `.claude-config/deploy.sh` (Linux/macOS).
2. **Claude.ai GUI (web/desktop/mobile)**: as a Project. Files uploaded manually into a project's instructions field plus knowledge file slots.

> **`SKILLS/` is the source/library AND the deployment target.** Active Claude Code skills load from here directly via the symlink at `~/.claude/skills/`. GUI Projects live in Anthropic's cloud, and this folder is where their content gets authored and backed up for manual upload.

## Why both?

- Skills win for development workflows (CLI, scripted, headless Linux, multi-machine via git).
- GUI Projects win for mobile and casual chat (phone, Claude.ai web, Claude Cowork (Anthropic's desktop app)).
- Most "capabilities" the Operator needs benefit from being available in BOTH places. Default: build the skill, mirror to a Project.

## Folder layout per entry

```
SKILLS/<entry-name>/
├── SKILL.md                    # Claude Code skill body: frontmatter, trigger description, instructions
├── 00_System_Prompt.md         # GUI Project system prompt (pasted into Project instructions field)
├── 01_*.md                     # GUI Project knowledge files (uploaded to Project)
├── 02_*.md
├── ...
└── README.md                   # entry-specific: when to use, deployment notes, last-updated
```

The `SKILL.md` and the `0X_*.md` knowledge files share content but serve different consumers:

- `SKILL.md` follows the Claude Code skill spec: frontmatter (`name`, `description`), trigger keywords, and instructions that `Read references/...` lazily load. Token-budgeted.
- `00_System_Prompt.md` follows the Claude Project spec: concise identity, behavior, and file routing. Pasted as project instructions.
- `0X_*.md` files are the knowledge files uploaded to the GUI Project. The same files can be referenced from `SKILL.md` for Claude Code consumption.

## Skill sources

A shared skill lives in exactly one repo, and every copy that uses it mounts it from there rather than carrying a drifting fork; a template copy of a same-named skill would block the shared one. What lives in *this* `SKILLS/` folder directly is the local, distribution-specific set: glue that binds to OPS's own hooks, scripts, and layout. On 2026-11-17 the template removed its thin context skills (the core's "Where to look" table names those files directly), its two generic method skills, and the skills that restated what a capable agent already knows.

**The mount mechanism is `.claude-config/bin/skills-vendor.sh` + `VENDORED.tsv`** (one mechanism, not two). `VENDORED.tsv` lists each portable skill and its source dir under `PROJECTS/`; `skills-vendor.sh sync` mirrors those source dirs into `SKILLS/<name>/`, and `skills-vendor.sh --check` is the drift gate `verify-ops.sh` runs (DRIFT = a source edit not mirrored = FAIL; MISSING = source repo not cloned = WARN). The template ships `VENDORED.tsv` with no rows: its nine rows for [`github.com/Exploitacious/agent-skills`](https://github.com/Exploitacious/agent-skills) were removed on 2026-11-17. Add rows for an org or private source of your own. To mount: clone the source under `PROJECTS/<org>/<repo>`, add one row per skill, then sync:

```
~/OPS/.claude-config/bin/skills-vendor.sh sync
```

Never hand-edit a mirrored `SKILLS/<name>/` dir; the sync replaces it. The sync never deletes a folder it did not write: a destination that is not a mirror it recorded in `SKILLS/.vendored-state.tsv` (your own skill under a name a manifest row now mounts, or a hand-edited mirror) is moved to `.claude-config/backup/skills-replaced/<name>-<UTC>/` first, and the sync prints a `BACKUP` line naming that path. On a fresh fork the source repos are not cloned, so the mounted skills appear only after the clone and the sync. Until you clone, `skills-vendor.sh --check` reports them MISSING (a WARN). Once the source is cloned, an un-synced mount reads as DRIFT (a FAIL) until you run `sync`.

The clone's checked-out commit is what a mount follows, and deploy never pulls an existing clone, so a newer source release reaches your copy only when you move it on purpose: read what changed (`git -C ~/OPS/PROJECTS/<org>/<repo> fetch`, then `log -p HEAD..origin/main`), `git -C ~/OPS/PROJECTS/<org>/<repo> pull --ff-only`, then `skills-vendor.sh sync` and `skills-vendor.sh --check`. `VENDORED.tsv` has no version column; the commit you pulled is the pin.

## How to add a new entry

First route the knowledge (`CONTEXT/core.md`, "Memory and where knowledge goes"): a client fact to the documentation system, a repo fact to the repo, a behavior rule to doctrine, a mechanical step to a script or tool. Only what fits none of those becomes a skill. When a `meta-skill-creator` skill is mounted from a shared source, it says how to build one; the template no longer ships it.

## Deployment

**Claude Code (auto via deploy script):**
```
~/OPS/SKILLS/         <- canonical (this folder)
  └─ symlinked at: ~/.claude/skills/   (by deploy.ps1 or deploy.sh, one hop)
```

Run the deploy script once per machine after cloning OPS:
- Windows: `pwsh ~/OPS/.claude-config/deploy.ps1`
- Linux/macOS: `bash ~/OPS/.claude-config/deploy.sh`

The script is idempotent, so it is safe to re-run anytime.

**Claude.ai GUI (manual):**
1. Open claude.ai → Projects → New (or edit existing).
2. Paste `00_System_Prompt.md` content into the project instructions field.
3. Upload `01_*.md` … `0N_*.md` as knowledge files.
4. After updates: re-paste sysprompt, replace knowledge files. (There is no GUI sync; a manual refresh is acceptable.)

## Index

Local entries live in this folder. The template mounts none; a skill you mount appears in `SKILLS/` only after `skills-vendor.sh sync`.

| Entry | Deployed as Skill? | GUI Project? | Notes |
|-------|--------------------|--------------|-------|
| `grabit` | yes | no | Claude Code only: SEND direction of the Tailscale file courier off a headless box; a GUI Project can't execute the local binary. It also says an image attached in a T3 message is already a path to read, not a receive. See [[grabit/README.md]]. |
| `pre-compact-synthesis` | yes | no | Claude Code only: durable-state synthesis plus closeout hygiene, taken at natural rest stops and before a manual `/compact`. Context-watch and automatic compaction are safety nets, not the ritual. Also holds the ask card (at most three asks, each with a recommendation and a default, every claim marked) for "what do you need from me" questions and close receipts. No GUI Project half exists. |
| `session-handoff` | yes | no | Claude Code only: write/read baton pair for handing off sessions across profiles and machines; pairs with `pre-compact-synthesis`. No GUI Project half exists. |
| `session-close` | yes | no | Claude Code only: permanent end-to-end close (the session's own cleanup, scoped to what it touched and never another live session's work; the work-tracking reconciliation gate; the receipt as an ask card; then archive or deregister and tear down the backend). Runs only on the operator's explicit word. The terminal counterpart to `pre-compact-synthesis` (pause) and `session-handoff` (move). |
| `harness-update` | yes (slash-only: `/harness-update`) | no | Claude Code only: safe template-sync of a private OPS copy from the public upstream (no shared git history); the scan classifies files NEW/UPDATE/CONFLICT/IDENTICAL, hard-excludes identity, memory, and handoff surfaces, and never auto-applies a CONFLICT. See [[harness-update/SKILL.md]]. |
| `t3-html-render` | yes | no | T3 Code only: builds one self-contained interactive HTML page for data, a report, research findings, a comparison, or a plan, checks it with `html_preview` at two widths and both themes, and shows it inline with `html_render`. Carries a starter page, a worked example (synthetic data), and a palette validated for colorblind safety on T3's surfaces. In a T3 thread the page is the default for data and reports (`CONTEXT/how-i-work.md`, "Reporting to the Operator"). |

Domain-partner skills (a vendor-docs assistant, anything tied to your own
stack or business) aren't shipped here; they're yours to build, after the
routing test above says a skill is the right home.

## The skill listing budget (an option, never required)

Every model-invocable skill puts its name and description into the listing each session loads, and Claude Code drops descriptions from the tail of that listing above about 30,000 characters (built-in and account skills share the budget). A skill nobody loads can therefore cost a live one its description. The template marks one of its own skills slash-only (below) and never removes a skill from your copy; the other levers are yours, and a team can use them without touching OPS:

- `disable-model-invocation: true` in a skill's frontmatter (a standalone `#` comment line or a trailing comment beside it parses) drops the skill from the model's listing and leaves only the human `/name` command; the model cannot load it through the Skill tool. It suits a skill the operator starts by name. The template ships it on `harness-update`: a template sync starts only when the operator asks, so its description bought nothing in the listing. Type `/harness-update` to run it; asked in plain words, an agent cannot load it through the Skill tool. To give the model that skill back, delete the line in your copy. Probed on Claude Code 2.1.319. An edit to a template skill's frontmatter is a local change: `harness-update` reports that file as a CONFLICT if upstream later changes it too.
- The `skillOverrides` setting in your own Claude Code settings (`{"<name>": "on" | "name-only" | "user-invocable-only" | "off"}`) changes how a skill is listed without editing its file, and also covers built-in and account skills. A `Skill(...)` permission deny does not hide a skill from the listing. `deploy.sh` never writes your settings, so this one is entirely yours.
- A skill you never load can be deleted, local or mounted. For a mounted one, delete its row in `VENDORED.tsv` and its `SKILLS/<name>/` mirror folder: the sync writes mirrors and never removes one, so a dropped row leaves its folder in place.

## Migrating a cloud-only Project

If a Project exists in claude.ai but not here:

1. Export sysprompt from claude.ai Project settings → save as `00_System_Prompt.md`.
2. Download each knowledge file → save as numbered `0X_*.md`.
3. Drop in `SKILLS/<slug>/`.
4. Triage with the routing test in "How to add a new entry": should this also be a Claude Code Skill? If yes, author `SKILL.md`. The deploy chain picks it up automatically, with no extra symlink work needed.
