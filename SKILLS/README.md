# SKILLS: source library for Claude skills and GUI projects

This folder is the **authoritative source** for the local, OPS-specific Claude capabilities the Operator maintains across machines. Portable technique skills are mounted from a shared skill source instead (see "Skill sources" below). Each subfolder is one "library entry" that can deploy in two places:

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

OPS mounts the portable technique skills rather than carrying its own drifting fork of each. A portable skill (delegation, skill authoring, intake, test-first work, diagnosis) is the same for every operator, so it lives in one shared source and every OPS copy mounts it. What lives in *this* `SKILLS/` folder directly is the local, distribution-specific set: glue that binds to OPS's own hooks, scripts, and layout, the thin context skills that route to `CONTEXT/`, and two generic method skills.

**The mount mechanism is `.claude-config/bin/skills-vendor.sh` + `VENDORED.tsv`** (one mechanism, not two). `VENDORED.tsv` lists each portable skill and its source dir under `PROJECTS/`; `skills-vendor.sh sync` mirrors those source dirs into `SKILLS/<name>/`, and `skills-vendor.sh --check` is the drift gate `verify-ops.sh` runs (DRIFT = a source edit not mirrored = FAIL; MISSING = source repo not cloned = WARN). The default source is [`github.com/Exploitacious/agent-skills`](https://github.com/Exploitacious/agent-skills) (the delegation set, `meta-skill-creator`, and the `grill-me`, `tdd`, and `diagnosing-bugs` skills); add rows in `VENDORED.tsv` for an org or private source of your own. To mount: clone the source under `PROJECTS/`, then sync:

```
git clone https://github.com/Exploitacious/agent-skills.git ~/OPS/PROJECTS/Exploitacious/agent-skills
~/OPS/.claude-config/bin/skills-vendor.sh sync
```

Never hand-edit a mirrored `SKILLS/<name>/` dir; the sync replaces it. The sync never deletes a folder it did not write: a destination that is not a mirror it recorded in `SKILLS/.vendored-state.tsv` (your own skill under a name a manifest row now mounts, or a hand-edited mirror) is moved to `.claude-config/backup/skills-replaced/<name>-<UTC>/` first, and the sync prints a `BACKUP` line naming that path. On a fresh fork the source repos are not cloned, so the mounted skills (`grill-me` among them) appear only after the clone and the sync. Until you clone, `skills-vendor.sh --check` reports them MISSING (a WARN). Once the source is cloned, an un-synced mount reads as DRIFT (a FAIL) until you run `sync`.

The clone's checked-out commit is what a mount follows, and deploy never pulls an existing clone, so a newer source release reaches your copy only when you move it on purpose: read what changed (`git -C ~/OPS/PROJECTS/Exploitacious/agent-skills fetch`, then `log -p HEAD..origin/main`), `git -C ~/OPS/PROJECTS/Exploitacious/agent-skills pull --ff-only`, then `skills-vendor.sh sync` and `skills-vendor.sh --check`. `VENDORED.tsv` has no version column; the commit you pulled is the pin.

## How to add a new entry

Use the `meta-skill-creator` skill (mounted from the skill source). It's the single source of doctrine for:

- When to make both (default) vs skill-only vs project-only
- How to structure each
- Anti-patterns
- Build checklist
- How to migrate an existing cloud-only Project here

Trigger Claude Code: ask to "create a new skill" or "build a Claude project", and `meta-skill-creator` activates and walks the build.

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

Local entries live in this folder. Mounted skills are listed in the second table; they appear in `SKILLS/` only after `skills-vendor.sh sync`.

| Entry | Deployed as Skill? | GUI Project? | Notes |
|-------|--------------------|--------------|-------|
| `operating-model` | yes | no | Terse prose, answer-and-action structure, lazy-correct engineering (including a destructive step that must tell an empty read from a failed one), a verification-scope rule for lists that change money or records, and the AI-tell editing catalog (`references/patterns.md`). Carries the upstream MIT notices for the sources it adapts. |
| `stewardship` | yes | no | Surface a tool or skill defect instead of silently working around it: retry rules for reads versus writes, a minimal workaround, a fix at the source, and where a mounted skill is edited. In a ticket or incident thread the defect is filed as an issue and the work continues; the tool or skill is not changed there. |
| `grabit` | yes | no | Claude Code only: SEND direction of the Tailscale file courier off a headless box; a GUI Project can't execute the local binary. It also says an image attached in a T3 message is already a path to read, not a receive. See [[grabit/README.md]]. |
| `grabit-screenshots` | yes | no | Claude Code only: RECEIVE direction. Pull files (screenshots included) the operator pushed to the box and read them. Shares the `grabit` binary. See [[grabit/README.md]]. |
| `memory-prune` | yes | no | Claude Code only: fans out a read-only memory audit via the Workflow tool (`audit_workflow.js`), plus a pool inventory (`scripts/inventory`, which reports a pool it cannot read as UNMEASURED, never as empty); executes after operator sign-off. No GUI Project half exists. |
| `pre-compact-synthesis` | yes | no | Claude Code only: durable-state synthesis plus closeout hygiene, taken at natural rest stops and before a manual `/compact`. Context-watch and automatic compaction are safety nets, not the ritual. Also holds the ask card (at most three asks, each with a recommendation and a default, every claim marked) for "what do you need from me" questions and close receipts. No GUI Project half exists. |
| `session-handoff` | yes | no | Claude Code only: write/read baton pair for handing off sessions across profiles and machines; pairs with `pre-compact-synthesis`. No GUI Project half exists. |
| `remote-session` | yes | no | Claude Code only: hand-run remote sessions. The operator asks for each start, park, revive, or end of a tmux `claude --remote-control` session, and the skill runs it through `.claude-config/remote-sessions/`. |
| `session-close` | yes | no | Claude Code only: permanent end-to-end close (the session's own cleanup, scoped to what it touched and never another live session's work; the work-tracking reconciliation gate; the receipt as an ask card; then archive or deregister and tear down the backend). Runs only on the operator's explicit word. The terminal counterpart to `pre-compact-synthesis` (pause) and `session-handoff` (move). |
| `harness-update` | yes | no | Claude Code only: safe template-sync of a private OPS copy from the public upstream (no shared git history); the scan classifies files NEW/UPDATE/CONFLICT/IDENTICAL, hard-excludes identity, memory, and handoff surfaces, and never auto-applies a CONFLICT. See [[harness-update/SKILL.md]]. |
| `operator-voice` | yes | no | Thin context skill: routes to the `CONTEXT/voice.md` slot when writing in the operator's voice; degrades to plain professional prose when unset. Also carries the story order for client documents that ask for decisions (decisions last). |
| `project-kata` | yes | no | Thin context skill: routes to `CONTEXT/project-kata.md` when scaffolding or restructuring a repo. |
| `projects-map` | yes | no | Thin context skill: routes to `PROJECTS/projects-map.md` for repo routing and portfolio layout. |
| `machines` | yes | no | Thin context skill: routes to the `CONTEXT/machines.md` slot for host topology; degrades (OPS ships no machines.md) to asking or inferring. |
| `harness-deploy` | yes | no | Thin context skill: routes to `DEPLOYMENT.md` when changing Stage 1 / Stage 2 install. |
| `harness-readme` | yes | no | Thin context skill: routes to `README.md` for "what exists / where does X live". |
| `design-method` | yes | no | Design method (UI, web, landing pages, email templates) with an optional brand layer read from `design-method/brand.md`; free-design until the brand file is filled. |

Mounted from [`Exploitacious/agent-skills`](https://github.com/Exploitacious/agent-skills) (public, MIT) through `VENDORED.tsv`. Edit these at the source, then sync; never in `SKILLS/`.

| Entry | Deployed as Skill? | GUI Project? | Notes |
|-------|--------------------|--------------|-------|
| `grill-me` | yes | no | Intake interview: rounds over a request's decision tree, a recommended answer per question, facts gathered by the agent. Fires on its own when a request still has open decisions. Adapted from mattpocock/skills `grilling` (MIT). |
| `tdd` | yes | no | Test-driven development discipline (red, green, refactor, integration tests). From mattpocock/skills (MIT). |
| `diagnosing-bugs` | yes | no | Diagnosis loop for hard bugs and performance regressions when the cause is still unknown. From mattpocock/skills (MIT). |
| `meta-skill-creator` | yes | no | Authoring doctrine for portable skills; the single source for how to build one (see "How to add a new entry"). |
| `delegation-sizing` | yes | no | Delegate-or-not gate, the five delegation patterns and their decision tree, agent-type choice, and a conversion-factor estimate. |
| `briefing-subagents` | yes | no | Stakes-mode brief framing and the eight-section brief shape. |
| `worktree-isolation` | yes | no | Isolation for parallel writers, and the six failure modes at its edges. |
| `verifying-delegated-output` | yes | no | The two claim classes to verify before trust, git-state checks before a merge, a stub and fabrication audit, and recovery when a lane returns a waiting line or no report. |
| `dynamic-workflows` | yes | no | Workflow-authoring escalation gate, script primitives, the args prelude every script starts with, recovery after a usage-limit hold, and the pipeline-versus-parallel rule. |

Domain-partner skills (a vendor-docs assistant, a trading co-strategist, anything
tied to your own stack or business) aren't shipped here; they're yours to
build. `meta-skill-creator` is the authoring doctrine; `BOOTSTRAP.md` offers to
scaffold your first one when it learns what you do.

## The skill listing budget (an option, never required)

Every model-invocable skill puts its name and description into the listing each session loads, and Claude Code drops descriptions from the tail of that listing above about 30,000 characters (built-in and account skills share the budget). A skill nobody loads can therefore cost a live one its description. The template sets nothing here and never removes a skill from your copy; the levers are yours, and a team can use them without touching OPS:

- `disable-model-invocation: true` in a skill's frontmatter (a standalone `#` comment line or a trailing comment beside it parses) drops the skill from the model's listing and leaves only the human `/name` command; the model cannot load it through the Skill tool. It suits a skill the operator starts by name, such as `harness-update` or `remote-session`. Probed on Claude Code 2.1.319. An edit to a template skill's frontmatter is a local change: `harness-update` reports that file as a CONFLICT if upstream later changes it too.
- The `skillOverrides` setting in your own Claude Code settings (`{"<name>": "on" | "name-only" | "user-invocable-only" | "off"}`) changes how a skill is listed without editing its file, and also covers built-in and account skills. A `Skill(...)` permission deny does not hide a skill from the listing. `deploy.sh` never writes your settings, so this one is entirely yours.
- A skill you never load can be deleted, local or mounted. For a mounted one, delete its row in `VENDORED.tsv` and its `SKILLS/<name>/` mirror folder: the sync writes mirrors and never removes one, so a dropped row leaves its folder in place. The thin context skills (`projects-map`, `harness-deploy`, `harness-readme`) and `grabit-screenshots` are the narrowest entries here; keeping or dropping them is your call.

## Migrating a cloud-only Project

If a Project exists in claude.ai but not here:

1. Export sysprompt from claude.ai Project settings → save as `00_System_Prompt.md`.
2. Download each knowledge file → save as numbered `0X_*.md`.
3. Drop in `SKILLS/<slug>/`.
4. Use `meta-skill-creator` to triage: should this also be a Claude Code Skill? If yes, author `SKILL.md`. The deploy chain picks it up automatically, with no extra symlink work needed.
