# SKILLS: source library for Claude skills and GUI projects

This folder is the **authoritative source** for the local, OPS-specific Claude capabilities the Operator maintains across machines. A skill holds only what a capable agent with a fresh context could not know (this copy's systems, house standards), never procedure: a behavior rule goes to doctrine (`CONTEXT/core.md`), a repo fact to the repo, a mechanical step to a script or tool. Shared skills come from their one source repo instead (see "Skill sources" below). Each subfolder is one "library entry" that can deploy in two places:

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

A shared skill lives in exactly one repo; a template copy of a same-named skill would block the shared one. What lives in *this* `SKILLS/` folder is the template's own set: glue that binds to OPS's own hooks, scripts, and layout. An organization's shared skills are delivered separately by that organization, not through this repo. On 2026-11-17 the template removed its thin context skills (the core's "Where to look" table names those files directly), its two generic method skills, and the skills that restated what a capable agent already knows, and deploy stopped cloning and mirroring a public skill source (`DEPLOYMENT.md`, "Leftovers from the skill mounts", lists what an older copy may still hold).

## How to add a new entry

First route the knowledge (`CONTEXT/core.md`, "Memory and where knowledge goes"): a client fact to the documentation system, a repo fact to the repo, a behavior rule to doctrine, a mechanical step to a script or tool. Only what fits none of those becomes a skill. When your organization delivers a `meta-skill-creator` skill, it says how to build one; the template no longer ships it.

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

Local entries live in this folder.

| Entry | Deployed as Skill? | GUI Project? | Notes |
|-------|--------------------|--------------|-------|
| `harness` | yes | no | Claude Code in T3 Code: the facts about the box and T3 an agent cannot work out (how a thread pauses, moves and closes through `session-end`, how to reach the Operator, waiting, helper agents, review, the box's guards and commands). Carries the inline-page starter, a worked example (synthetic data) and a palette validated for colorblind safety on T3's surfaces (`assets/`, `references/palette.md`; `tests/t3-html-render-test.py` checks the pages). |

On 2026-11-17 the `harness` skill replaced six template skills: `pre-compact-synthesis`, `session-close`, `session-handoff`, `grabit`, `t3-html-render` and `harness-update`. The machinery they described now runs in commands (`session-end`, `grabit`, `harness-update-scan.sh`), and the facts they carried live in the `harness` skill and `.claude-config/bin/README.md`. A template sync never deletes a file, so a copy updated from an older template may still hold those six folders under `SKILLS/`; nothing reads them any more, and deleting them is your call (they still load as skills until you do, and their text describes the old procedure).

Domain-partner skills (a vendor-docs assistant, anything tied to your own
stack or business) aren't shipped here; they're yours to build, after the
routing test above says a skill is the right home.

## The skill listing budget (an option, never required)

Every model-invocable skill puts its name and description into the listing each session loads, and Claude Code drops descriptions from the tail of that listing above about 30,000 characters (built-in and account skills share the budget). A skill nobody loads can therefore cost a live one its description. The template never removes a skill from your copy; the levers are yours, and a team can use them without touching OPS:

- `disable-model-invocation: true` in a skill's frontmatter (a standalone `#` comment line or a trailing comment beside it parses) drops the skill from the model's listing and leaves only the human `/name` command; the model cannot load it through the Skill tool. It suits a skill the operator starts by name. To give the model that skill back, delete the line in your copy. Probed on Claude Code 2.1.319. An edit to a template skill's frontmatter is a local change: the template sync reports that file as a CONFLICT if upstream later changes it too.
- The `skillOverrides` setting in your own Claude Code settings (`{"<name>": "on" | "name-only" | "user-invocable-only" | "off"}`) changes how a skill is listed without editing its file, and also covers built-in and account skills. A `Skill(...)` permission deny does not hide a skill from the listing. `deploy.sh` never writes your settings, so this one is entirely yours.
- A skill you never load can be deleted from your copy.

## Migrating a cloud-only Project

If a Project exists in claude.ai but not here:

1. Export sysprompt from claude.ai Project settings → save as `00_System_Prompt.md`.
2. Download each knowledge file → save as numbered `0X_*.md`.
3. Drop in `SKILLS/<slug>/`.
4. Triage with the routing test in "How to add a new entry": should this also be a Claude Code Skill? If yes, author `SKILL.md`. The deploy chain picks it up automatically, with no extra symlink work needed.
