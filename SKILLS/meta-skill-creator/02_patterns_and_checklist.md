# Claude-Specific Patterns & Build Checklist

## Effective Patterns for Claude

### Role Assignment
Claude responds well to a single, clearly defined role with a stated expertise level. The role should imply a decision-making style, not just a knowledge domain.

Weak: "You are a financial expert."
Strong: "You are a trading co-strategist who pressure-tests reasoning and flags contradictions. You bring data, not vibes."

The strong version tells Claude not just WHAT it knows but HOW it thinks and interacts.

### Behavioral Constraints as Identity
Instead of listing rules, frame constraints as part of who Claude is in this project. Rules feel like external limits; identity feels like internal motivation. Claude follows both, but identity-framed instructions produce more natural output.

Rules-style: "Do not use sycophantic language. Do not hedge. Do not add disclaimers."
Identity-style: "You never pad bad news or soften hard truths. You lead with the answer, then support it. If confidence is low, you say so plainly with a number."

Same effect, but the second version reads as character rather than compliance.

### Scope Control with Conditional Triggers
When a project has templates or frameworks in knowledge files, the system prompt needs to tell Claude when to invoke them and when to answer directly.

Pattern:
"This project includes an [Analysis Template] in the knowledge files. Apply the full framework when the user requests a comprehensive analysis or deep-dive. For direct, narrow questions, answer them directly without invoking the template. Scale your response to the question."

Without this, Claude will either ignore the templates or apply them to everything.

### Self-Check Protocols
For high-stakes or judgment-heavy projects, include a reasoning check that runs before Claude responds. This is most effective when it's specific to the domain.

Generic (weak): "Think carefully before responding."
Domain-specific (strong): "Before recommending caution, ask yourself: is this backed by data, or am I defaulting to risk aversion? If the cautious path has costs, name them."

### Graduated Response Frameworks
For decision-support projects, tell Claude to present options with trade-offs rather than single recommendations. This works well when:
- The user is the decision-maker, not Claude
- Multiple valid approaches exist
- Trade-offs are non-obvious

Pattern: "When a decision point arises, present options with trade-offs — not a single directive. Include the cost of each path, including the cost of inaction. [The user] picks the path; you map the decision space."

### Explicit Anti-Patterns (The "Never" List)
Claude follows negative constraints reliably. Use a "Never" list for behaviors that would actively degrade the project's value. Keep it short — 5-7 items maximum. Every item should address a specific failure mode, not a general concern.

Weak: "Never be unhelpful."
Strong: "Never manufacture urgency that doesn't exist. If the decision is still being evaluated, slow the execution discussion down."

### Knowledge File Routing
In the system prompt, include a brief section that tells Claude what each knowledge file contains and when to reference it. Think of it like a table of contents with usage instructions.

Pattern:
"This project includes reference files. Use them as follows:
- [File Name]: Consult this when [specific trigger condition].
- [File Name]: Reference this for [specific type of context].
You don't need to rigidly follow every section of a template every time. Scale to the question."

## Patterns to Avoid in Claude Projects

### Persona Names
Giving Claude a character name ("You are Lyra, a master-level optimizer") adds nothing functional. The name doesn't change behavior — the instructions do. It also creates a jarring experience when Claude sometimes uses the name and sometimes doesn't. Skip it.

### Mode Selection
"Choose BASIC or DETAIL mode" forces a meta-decision before the actual work starts. If you always want maximum depth, just set maximum depth as the default behavior. If you sometimes want quick answers, use scope control (see above) instead of modes.

### Welcome Messages
"When activated, display EXACTLY this greeting..." — Claude Projects don't have activation triggers. Every conversation starts fresh. A scripted welcome message wastes the first response and feels robotic. Let Claude's first response be shaped by the system prompt naturally.

### Overly Prescriptive Output Formats
Locking Claude into rigid response templates ("Always respond with: **Heading**, then bullet points, then **Pro Tip**") produces formulaic output that doesn't adapt to question complexity. Instead, describe the desired information density and let Claude format appropriately. Reserve specific formats for specific deliverables (trade plans, analysis reports).

### Instructions That Restate Defaults
Claude already tries to be helpful, accurate, and thoughtful. Instructions like "provide accurate information," "be thorough," or "think step by step" don't change behavior — they just consume tokens. Only include instructions that REDIRECT Claude from its default behavior.

### Cross-Platform Instructions
"For ChatGPT, use structured sections. For Claude, use reasoning frameworks." If the project is on Claude, it's for Claude. Remove all other platform references. They dilute focus and confuse the instruction set.

---

## Build Checklist

Use this checklist to verify an entry is complete before delivering it to the user.

### Structure
- [ ] Single, clear identity in the system prompt / SKILL.md (no competing roles)
- [ ] System prompt is under 1,500 words; SKILL.md body under 2,000 words
- [ ] Each knowledge file has a single, clear purpose
- [ ] Knowledge files are numbered and named by function
- [ ] System prompt / SKILL.md includes routing instructions for knowledge files
- [ ] Scope control is defined (when to use templates vs. answer directly)

### Content Quality
- [ ] Every instruction changes Claude's behavior (no default-restating)
- [ ] Behavioral constraints are specific, not vague ("never say X" not "be careful")
- [ ] No competing or contradictory instructions
- [ ] Anti-patterns list is short and addresses real failure modes
- [ ] Templates/frameworks include all sections needed for a complete output
- [ ] Self-check protocol is domain-specific, not generic

### Audience
- [ ] Personal vs. shared determination has been made
- [ ] If shared: no names, personal preferences, or individual context baked in
- [ ] If personal: user context is in a knowledge file, not the system prompt (so it's easy to update)

### Deployment
- [ ] Skill vs. Project vs. Both determination has been made (see `03_skills_vs_projects.md`)
- [ ] If skill: `SKILL.md` has valid frontmatter (`name`, `description` with trigger keywords)
- [ ] If skill: `allowed-tools` set if MCP/tool restrictions needed
- [ ] If project: `00_System_Prompt.md` ready to paste into Project instructions
- [ ] If both: shared knowledge files work for both consumers (no GUI-only or CLI-only assumptions baked in)

### Platform Fit
- [ ] No persona names unless specifically requested
- [ ] No mode selection (always maximum depth)
- [ ] No welcome messages or activation scripts
- [ ] No cross-platform instructions (other AI vendors)
- [ ] No memory management instructions (irrelevant in project context; handled separately in CC)
- [ ] Output format guidance is flexible, not rigid templates

### Completeness
- [ ] A user unfamiliar with this conversation could deploy and immediately get useful results
- [ ] `README.md` in the entry folder explains: purpose, files, deployment, last-updated
- [ ] Edge cases have been considered (simple questions, ambiguous requests, conflicting inputs)
- [ ] If deployed as skill: entry sits in `SKILLS/<name>/`. No per-entry symlink needed — `~/.claude/skills/` symlinks the whole SKILLS folder.
