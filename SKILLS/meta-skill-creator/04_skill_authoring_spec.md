# SKILL.md Authoring Spec

Reference this when writing or editing a `SKILL.md` file for Claude Code.

## Anatomy of a Skill

A Claude Code skill is a folder containing:

```
~/.claude/skills/<name>/
├── SKILL.md              # required — body + frontmatter
├── 01_*.md               # optional — reference files for lazy loading
├── 02_*.md
├── scripts/              # optional — executable helpers
└── ...
```

In this setup, the canonical source lives at `~/OPS/SKILLS/<name>/`. `~/.claude/skills/` is a symlink/junction → `~/OPS/SKILLS/`, set up by `.claude-config/deploy.ps1` (Windows) or `.claude-config/deploy.sh` (Linux/macOS). One hop. One source of truth.

## Frontmatter Spec

`SKILL.md` opens with YAML frontmatter. Minimum required fields:

```yaml
---
name: Human Readable Name
description: >
  One to three sentences describing what the skill does AND when it activates.
  Use trigger keywords Claude will match against user intent: "create X", "audit Y",
  "deploy Z". The description IS the trigger. It is the only part Claude sees until
  activation, so write it for retrieval.
---
```

Optional fields:

```yaml
allowed-tools:
  - "Read"
  - "Edit"
  - "Grep"
  - "mcp:vendor_search"
  - "mcp:vendor_get_document"
```

`allowed-tools` restricts the tools Claude can use while this skill is active. Use it when:
- The skill should only call certain MCP servers (e.g., a vendor-docs skill restricted to `mcp:vendor_*`)
- The skill is read-only (no `Edit`, `Write`) — audit/review skills
- The skill enforces a workflow boundary

Skip `allowed-tools` if the skill is general-purpose advisory and shouldn't limit Claude's defaults.

```yaml
context: fork
agent: Explore
```

`context: fork` runs the skill in an isolated subagent instead of inline in the
main conversation — the fork absorbs the skill's token cost and hands back
only the result. Use it when:
- The skill's reference files or workflow are heavy and would otherwise eat
  into the main session's context budget for every activation
- The skill's job is self-contained (research, an audit pass, a bounded
  build) and doesn't need the main thread's running context to do its work

`agent` selects which agent type executes the skill once `context: fork` is
set (e.g. `Explore` for read-heavy investigation). It only does anything
alongside `context: fork` — set without it, it has no effect.

```yaml
disable-model-invocation: true
```

Restricts the skill to user-only invocation (typed `/skill-name`) — Claude
cannot fire it on its own. Use it for skills with side effects (deploy,
send, delete, anything state-changing) where letting Claude decide to
trigger the skill autonomously would be unsafe.

```yaml
user-invocable: false
```

The inverse of `disable-model-invocation`: hides the skill from `/` entirely
and makes it Claude-only — the model applies it automatically as background
knowledge, and the user never invokes it directly. Use it for standing
context (project conventions, house style, a routing rule) that should
always be live in Claude's judgment but has no user-facing action to
trigger.

## Description Writing — The Critical Part

The description is the **only** thing Claude evaluates to decide whether the skill is relevant. The full body doesn't load until then.

**Bad description** (vague, no triggers):
> Helps with documentation tasks.

**Good description** (specific triggers, scope clear):
> Create and edit runbook entries and vendor-contact records in the internal ops wiki following Example Corp's documentation standards. Activates when working with runbook articles, vendor information placement, or internal documentation tasks.

Rules:
- Include 3-6 trigger phrases users might say. ("when creating X", "when reviewing Y", "when deploying Z")
- Name the domain explicitly. ("vendor documentation", "release deployment", "support ticketing")
- State what the skill produces or modifies. ("articles", "vendor entries", "trade plans")
- Mention any constraints that should affect activation. ("Activates only for documentation tasks, not code review.")
- Keep it under 3 sentences. The description is part of the session-start budget.

## Body Structure

After frontmatter, the body of `SKILL.md` is what Claude reads when activated. Standard structure:

```markdown
# Skill Name

You are [identity]. Your job is to [scope]. [Audience note if relevant.]

## Identity

[Behavioral character — how the skill behaves, not just what it does. Same patterns as
01_project_architecture_guide.md and 02_patterns_and_checklist.md.]

## Tools You Have

[If relevant — list MCP tools, scripts, or system access this skill uses. Reference
allowed-tools from frontmatter for the canonical list.]

## Process / Workflow

[Step-by-step or principles for how the skill does its work.]

## Reference Files

This skill includes reference files. Load them only when needed:

- `01_*.md` — Read when [specific trigger].
- `02_*.md` — Read when [specific trigger].

Do not read all reference files preemptively. Identify which is needed for the current
task and Read only that one.

## Anti-Patterns

[Short Never list — 5-7 specific failure modes.]
```

## Arguments and Dynamic Content in the Body

Two substitution patterns fire before Claude ever reads the skill content.

**`$ARGUMENTS`** — when a skill is invoked with trailing text (e.g.
`/my-skill do the thing`), `$ARGUMENTS` anywhere in the body is replaced with
everything after the skill name. If the body never references
`$ARGUMENTS`, Claude Code appends the raw input as `ARGUMENTS: <value>`
instead — input isn't silently dropped even if the substitution is missing.
Use `$ARGUMENTS` for skills that take one free-form instruction (a target
endpoint, a component name, a search query).

Positional `$1`/`$2`-style argument splitting (paired with an
`argument-hint` field) is documented for slash **commands**, not for
skill bodies. If a skill needs several distinct arguments, parse them out
of `$ARGUMENTS` in the body's own instructions rather than assuming
`$1`/`$2` are available.

**Dynamic injection with `` !`command` ``** — a backtick-wrapped shell
command inside the body is executed and its output replaces the
placeholder before Claude reads the skill:

```markdown
## Current State
- Branch: !`git branch --show-current`
- Status: !`git status --short`
```

Use this to hand Claude live state (git branch, a PR diff, recent commits)
pre-populated in the skill body, instead of making the skill's first step a
separate tool call for the same information.

## Progressive Disclosure

The whole point of skills (vs. always-on Project sysprompts) is **lazy loading**. Use it.

- `SKILL.md` body: load every activation. Keep under 2,000 words. Identity + workflow + reference index.
- `0X_*.md` reference files: load only when their specific trigger fires. Can be 5,000+ words each.
- Scripts in `scripts/`: invoked, not read. Output flows back as tool result.

**Bad** (defeats lazy loading):
```markdown
## Background

[Pastes entire 4,000-word domain primer here in SKILL.md body.]
```

**Good** (progressive):
```markdown
## Background

For the full domain primer, Read `01_domain_primer.md` when:
- The user asks about [specific topic]
- You need historical context to make a recommendation
- A term needs disambiguation
```

## Token Budgets (rough)

| Section | Target | Hard limit |
|---------|--------|------------|
| Description (frontmatter) | 50-150 words | 250 words |
| `SKILL.md` body | 800-1,500 words | 2,000 words |
| Each `0X_*.md` | 1,500-3,500 words | 5,000 words |
| Scripts | n/a — invoked, not read | n/a |

Exceeding hard limits doesn't break the skill but degrades responsiveness and increases per-activation cost.

## Tool Restriction Patterns

### Read-only audit skill
```yaml
allowed-tools:
  - "Read"
  - "Grep"
  - "Glob"
```

### MCP-bounded skill
```yaml
allowed-tools:
  - "mcp:vendor_*"
  - "Read"
```

### Editing skill within one tool family
```yaml
allowed-tools:
  - "Read"
  - "Edit"
  - "Write"
  - "Grep"
```

### Workflow-enforcement skill
No `allowed-tools` set. The skill body itself enforces the workflow via instructions, leaving Claude full toolbox access.

## Common Mistakes

### Description too generic
"Helps with code" or "Documentation skill" won't trigger reliably. Be specific about domain + triggers.

### SKILL.md body too long
Anything over 2,000 words is probably reference material that belongs in a `0X_*.md`. Move it.

### Loading all references in SKILL.md
"Read 01_*.md, 02_*.md, and 03_*.md to begin." Defeats lazy loading. Each Read instruction should be conditional on a specific trigger.

### Missing trigger keywords in description
If you can't predict the user phrases that should activate this skill, neither can Claude. Add them explicitly: "Activates when the user says 'create skill', 'new skill', 'audit skill'..."

### `allowed-tools` too restrictive
Locking a skill to only `Read` when it should also `Edit` causes silent failures. Match the tool list to the skill's actual operations.

### Putting personal context in SKILL.md instead of a reference file
Personal context (the Operator's account details, working preferences) should live in a `0X_*.md` so it's easy to update without touching the skill body. Same rule as Projects.

## Testing a Skill

After authoring `SKILL.md`:

1. Re-run `~/OPS/.claude-config/deploy.ps1` (if needed — symlinks should auto-pick up new entries).
2. Start a fresh Claude Code session.
3. Test trigger phrases: phrase the request the way a user would. Does the skill activate?
4. Test progressive disclosure: does Claude only read reference files when the trigger inside SKILL.md fires?
5. Test tool restrictions: if `allowed-tools` is set, confirm Claude refuses to use disallowed tools.
6. Test scope control: ask a simple question. Does Claude apply the skill heavyweight, or scale down?

If any test fails: edit, redeploy (if needed), retest.
