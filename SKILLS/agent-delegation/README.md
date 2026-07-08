# Agent Delegation — Foreman Pattern

## Purpose

Operationalize the foreman delegation pattern across every Claude
context — solo Claude Code, fleet Captain, fleet Agent. Distills
the breakthroughs from a real multi-session production delegation
run (2026-05-19 → 2026-05-21) into a reusable skill / GUI Project.

This skill is the depth layer behind `CONTEXT/operating-doctrine.md`
P8 (stakes-mode briefing) and `CONTEXT/fleet-doctrine.md` F4-F7
(foreman pattern, brief template, quality gates, conversion
factor). Doctrine is the principle; this is the how-to.

## Files

- `SKILL.md` — Claude Code skill entry (frontmatter description
  drives activation; body loads when triggered)
- `00_System_Prompt.md` — Claude.ai GUI Project system prompt
  (parallel wrapper of SKILL.md)
- `01_brief_template.md` — 8-section brief template with full
  worked examples + common failures
- `02_sub_agent_patterns.md` — The 5 patterns (parallel-research,
  registry-driven, surgical-pack, heavy-build, reviewer-fix) in
  depth, including pattern decision tree
- `03_quality_gates_and_audit.md` — F6 audit checklist + per-
  pattern specifics + when audit fails
- `04_foreman_estimation.md` — F7 conversion factor + worked
  examples + delegation-viability decision rules
- `05_dynamic_workflows.md` — the programmatic delegation tier
  (P12): when to use a Claude Code dynamic workflow, the
  primitives, pipeline-vs-parallel, quality patterns, worktree
  mechanics, saving as a `/command`

## Deployment

Skill is picked up automatically by `~/.claude/skills/` symlink
to `~/OPS/SKILLS/`. No registration step.

GUI Project: upload `00_System_Prompt.md` as the project's system
prompt; upload `01_*.md` through `05_*.md` as knowledge files.

## When to use

This skill activates when the user mentions:

- Delegating to sub-agents
- The foreman pattern
- Parallel work / ambitious multi-stream scope
- Spawning worktrees
- Reviewing sub-agent output
- Writing an agent brief
- Estimating delegated work
- Authoring a dynamic workflow / deciding workflow-vs-manual
- Any task >1 day of solo effort that parallelizes

Universal across personas — Captain, Agent, and solo Claude Code
sessions all use the same pattern.

## Doctrine references

- `~/OPS/CONTEXT/operating-doctrine.md` P6, P7, P8
- `~/OPS/CONTEXT/fleet-doctrine.md` F4, F5, F6, F7
- `~/OPS/WORKFORCE/personalities/AGENT.md` (sub-agent grant)
- `~/OPS/WORKFORCE/personalities/COORDINATOR.md` (Captain
  delegation playbook)

## Last updated

2026-06-01 — added `05_dynamic_workflows.md` (P12 programmatic
delegation tier) after Claude Code shipped native dynamic
workflows. Skill now covers all four orchestration tiers.

2026-05-21 — initial creation as Phase 2 of doctrine integration
into OPS.
