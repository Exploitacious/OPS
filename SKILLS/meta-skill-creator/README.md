# meta-skill-creator

Authoritative builder + doctrine for new Claude capabilities. Use this when:

- Adding a new entry to `SKILLS/`
- Converting an existing cloud-only Project into a portable Skill (or vice versa)
- Deciding whether something should be a Skill, a Project, or both
- Auditing an existing entry for anti-patterns

## When this activates (Claude Code)

`SKILL.md`'s description triggers when the user says: "create a skill", "new skill", "build a Claude project", "migrate this project", "convert to skill", "audit my skill", "skill from this prompt".

## Files in this entry

| File | Consumer | Purpose |
|------|----------|---------|
| `SKILL.md` | Claude Code | Lazy-loaded body. Frontmatter + identity + instructions + lazy references to numbered files. |
| `00_System_Prompt.md` | GUI Project | Paste into Claude.ai Project instructions field. |
| `01_project_architecture_guide.md` | Both | How Claude Projects work. What goes where. Anti-patterns. |
| `02_patterns_and_checklist.md` | Both | Claude-specific effective patterns + build checklist. |
| `03_skills_vs_projects.md` | Both | Dual-track doctrine. When skill, when project, when both. Migration paths. |
| `04_skill_authoring_spec.md` | Both | Claude Code SKILL.md format. Frontmatter spec. Progressive disclosure. Token budgets. |

## How to use

**Claude Code:** Just ask Claude to "create a new skill for X" or "convert my Y project to a skill". The skill activates and walks the build.

**Claude.ai GUI Project:** Create a Project named "Meta Skill Creator". Paste `00_System_Prompt.md` as instructions. Upload `01_*.md` through `04_*.md` as knowledge files.

## Output

Every build produces:

```
SKILLS/<new-entry>/
├── SKILL.md
├── 00_System_Prompt.md
├── 01_*.md ... 0N_*.md
└── README.md
```

If it's also a deployed skill: no extra step. `~/.claude/skills/` already symlinks the whole `SKILLS/` folder, so any new entry containing a `SKILL.md` auto-loads next session.

## Last updated

2026-05-15 — initial migration from `NOTES/MASTER/Claude/Project Skill Creator/`. Extended with Skills doctrine (files 03, 04) and `SKILL.md`.
