# SKILLS — Source Library for Claude Skills & GUI Projects

This folder is the **authoritative source** for every Claude capability the Operator maintains across machines. Each subfolder is one "library entry" that can deploy in two places:

1. **Claude Code (CLI)** — as a Skill, lazy-loaded by trigger description. Deployed via `~/.claude/skills/` symlinked directly to this folder. One hop. Cross-platform via `.claude-config/deploy.ps1` (Windows) or `.claude-config/deploy.sh` (Linux/macOS).
2. **Claude.ai GUI (web/desktop/mobile)** — as a Project. Files uploaded manually into a project's instructions field + knowledge file slots.

> **`SKILLS/` is the source/library AND the deployment target.** Active Claude Code skills load from here directly via the symlink at `~/.claude/skills/`. GUI Projects live in Anthropic's cloud — this folder is where their content gets authored and backed up for manual upload.

## Why both?

- Skills win for development workflows (CLI, scripted, headless Linux, multi-machine via git).
- GUI Projects win for mobile + casual chat (phone, Claude.ai web, Claude Cowork (Anthropic's desktop app)).
- Most "capabilities" the Operator needs benefit from being available in BOTH places. Default: build the skill, mirror to a Project.

## Folder layout per entry

```
SKILLS/<entry-name>/
├── SKILL.md                    # Claude Code skill body — frontmatter + trigger description + instructions
├── 00_System_Prompt.md         # GUI Project system prompt (pasted into Project instructions field)
├── 01_*.md                     # GUI Project knowledge files (uploaded to Project)
├── 02_*.md
├── ...
└── README.md                   # entry-specific: when to use, deployment notes, last-updated
```

The `SKILL.md` and the `0X_*.md` knowledge files share content but serve different consumers:

- `SKILL.md` follows Claude Code skill spec — frontmatter (`name`, `description`), trigger keywords, instructions that `Read references/...` lazy-load. Token-budgeted.
- `00_System_Prompt.md` follows Claude Project spec — concise identity + behavior + file routing. Pasted as project instructions.
- `0X_*.md` files = knowledge files uploaded to the GUI Project. Same files can be referenced from `SKILL.md` for Claude Code consumption.

## How to add a new entry

Use the `meta-skill-creator` skill/project. It's the single source of doctrine for:

- When to make both (default) vs skill-only vs project-only
- How to structure each
- Anti-patterns
- Build checklist
- How to migrate an existing cloud-only Project here

Trigger Claude Code: ask to "create a new skill" or "build a Claude project" — `meta-skill-creator` activates and walks the build.
For manual reference: `SKILLS/meta-skill-creator/`.

## Deployment

**Claude Code (auto via deploy script):**
```
~/OPS/SKILLS/         ← canonical (this folder)
  └─ symlinked at: ~/.claude/skills/   (by deploy.ps1 or deploy.sh — one hop)
```

Run the deploy script once per machine after cloning OPS:
- Windows: `pwsh ~/OPS/.claude-config/deploy.ps1`
- Linux/macOS: `bash ~/OPS/.claude-config/deploy.sh`

The script is idempotent — safe to re-run anytime.

**Claude.ai GUI (manual):**
1. Open claude.ai → Projects → New (or edit existing).
2. Paste `00_System_Prompt.md` content into the project instructions field.
3. Upload `01_*.md` … `0N_*.md` as knowledge files.
4. After updates: re-paste sysprompt, replace knowledge files. (No GUI sync — manual refresh acceptable.)

## Index

| Entry | Deployed as Skill? | GUI Project? | Notes |
|-------|--------------------|--------------|-------|
| `meta-skill-creator` | yes | yes | Authoritative doctrine for this folder. Reference for all other entries. |
| `agent-delegation` | yes | yes | Foreman delegation pattern — brief template, sub-agent patterns, quality gates, estimation, dynamic workflows. Depth layer behind `operating-doctrine.md` P8 and `fleet-doctrine.md` F4-F7. See [[agent-delegation/README.md]]. |
| `grabit` | yes | no | Claude Code only — Tailscale file courier off a headless box via a local shell binary; a GUI Project can't execute it. See [[grabit/README.md]]. |
| `memory-prune` | yes | no | Claude Code only — fans out a memory audit via the Workflow tool; no GUI Project half exists. |
| `pre-compact-synthesis` | yes | no | Claude Code only — pre-compaction durable-state synthesis; no GUI Project half exists. |
| `session-handoff` | yes | no | Claude Code only — write/read baton pair for handing off sessions across profiles/machines; pairs with `pre-compact-synthesis`. No GUI Project half exists. |
| `remote-session` | yes | no | Claude Code only — spins up always-on `claude --remote-control` sessions in tmux on request; sessions persist + resume across reboots via `.claude-config/remote-sessions/`. |
| `harness-update` | yes | no | Claude Code only — safe template-sync of a private OPS copy from the public upstream (no shared git history); the scan classifies files NEW/UPDATE/CONFLICT/IDENTICAL, hard-excludes identity/memory/handoff surfaces, and never auto-applies a CONFLICT. See [[harness-update/SKILL.md]]. |

Domain-partner skills (a vendor-docs assistant, a trading co-strategist, anything
tied to your own stack or business) aren't shipped here — they're yours to
build. `meta-skill-creator` is the authoring doctrine; `BOOTSTRAP.md` offers to
scaffold your first one when it learns what you do.

## Migrating a cloud-only Project

If a Project exists in claude.ai but not here:

1. Export sysprompt from claude.ai Project settings → save as `00_System_Prompt.md`.
2. Download each knowledge file → save as numbered `0X_*.md`.
3. Drop in `SKILLS/<slug>/`.
4. Use `meta-skill-creator` to triage: should this also be a Claude Code Skill? If yes, author `SKILL.md`. The deploy chain picks it up automatically — no extra symlink work needed.
