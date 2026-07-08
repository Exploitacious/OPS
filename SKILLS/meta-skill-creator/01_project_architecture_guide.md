# Claude Project Architecture Guide

Reference this document when making structural decisions about how to organize a Claude Project.

## How Claude Projects Work

A Claude Project consists of:

1. **System Prompt (Project Instructions)**: Text pasted into the project's instruction field. This is prepended to every conversation in the project. It shapes Claude's identity, behavior, and communication style for all interactions.

2. **Knowledge Files**: Documents uploaded to the project. Claude can reference these in any conversation within the project. They function as persistent context — Claude treats them as available reference material.

3. **Conversations**: Individual chat threads within the project. Each conversation gets the system prompt + access to knowledge files, but conversations don't see each other.

## What Goes Where

### System Prompt — The "Always On" Layer

Put content here ONLY if it must influence every single response:

- **Identity**: Who Claude is in this project. One clear role. "You are a trading co-strategist" or "You are a technical documentation writer." Not both.
- **Behavioral rules**: Communication style, tone, things to always/never do. These are the guardrails.
- **Self-check protocols**: Reasoning patterns Claude should apply before responding (e.g., "Before recommending caution, verify there's data supporting it").
- **File routing instructions**: Tell Claude which knowledge files to consult for which types of requests. Without this, Claude may ignore files or over-apply them.

**System prompt should be concise.** It's read in full on every message. A 3,000-word system prompt costs tokens on every turn. Keep it under 1,500 words if possible. If it's getting long, content probably belongs in a knowledge file instead.

### Knowledge Files — The "When Needed" Layer

Put content here if it's reference material, templates, or context that's relevant to SOME conversations but not all:

- **Frameworks and templates**: Analysis structures, report formats, decision matrices. Claude pulls these when the user asks for that type of work.
- **Domain context**: Background information, terminology glossaries, industry knowledge.
- **User/team profiles**: Account details, tools used, preferences, workflows. Things Claude needs to personalize its responses.
- **Procedural guides**: Step-by-step processes for specific tasks.
- **Examples**: Sample outputs showing the expected format or quality bar.

## Common Anti-Patterns

### Competing Identities
**Problem**: "You are an expert financial analyst. You are also a creative writing coach. You are also a code reviewer."
**Fix**: One identity per project. If the user needs multiple specialists, those are separate projects — or the identity is generalized ("You are a senior consultant who...") with specialist frameworks in knowledge files.

### Instruction Bloat
**Problem**: Rules that restate Claude's default behavior. "Be helpful." "Provide accurate information." "Think step by step when the problem is complex." Claude already does these things. Adding them wastes tokens and dilutes the instructions that actually change behavior.
**Fix**: Only include instructions that CHANGE Claude's default behavior. If removing an instruction wouldn't change the output, remove it.

### Everything in the System Prompt
**Problem**: A 5,000-word system prompt containing role definition, three analysis templates, account context, a glossary, and example outputs.
**Fix**: System prompt gets identity + behavioral rules + file routing. Everything else goes in knowledge files. Claude will still use it — that's what knowledge files are for.

### Vague Instructions
**Problem**: "Be detailed when needed." "Use appropriate formatting." "Consider all angles."
**Fix**: Make it concrete. "Include financial metrics from the most recent quarterly report." "Use tables when comparing three or more options." "Present both bull and bear cases with confidence scores."

### Missing Scope Control
**Problem**: A comprehensive analysis template exists in knowledge files, but Claude dumps the full 6-section report every time the user asks a quick yes/no question.
**Fix**: Add scope control to the system prompt: "Apply the full analysis framework when a comprehensive review is requested. For direct questions, answer directly — don't invoke the template."

### Platform-Specific Carry-Over
When migrating prompts from other platforms, watch for:
- **Conversation starters / welcome messages**: Claude Projects don't have these. Remove "When activated, display EXACTLY..." blocks.
- **Memory instructions**: "Do not save to memory" or "Remember this for next time" — Claude's memory system works differently. These instructions are noise in a project context.
- **Mode selection**: "Choose BASIC or DETAIL mode" — if you always want maximum depth (you do), don't make it a choice. Just set the behavior.
- **Platform-specific formatting**: Some platforms have specific markdown rendering. Claude renders standard markdown.
- **Multi-platform targeting**: "For ChatGPT use X, for Claude use Y" — strip this down to Claude-only instructions.

## File Organization Principles

- **One purpose per file.** A file called "Templates and Context and Rules" is a junk drawer. Split it.
- **Number files** for human readability: `01_`, `02_`, etc. Claude doesn't care about the numbers but the user maintaining the project does.
- **Name by function**: `01_Decision_Frameworks.md` tells you what's inside. `01_Additional_Instructions.md` doesn't.
- **Keep files under 5,000 words each.** Longer files are harder for Claude to navigate efficiently. If a file is getting long, it probably covers multiple topics and should be split.
- **Markdown format** for all text files. Claude handles markdown natively and it's human-readable.

## Testing a Finished Project

After building a project, the user should test it with these types of prompts:

1. **A simple, direct question** — Does Claude answer concisely without dumping a full framework?
2. **A request that should trigger a template** — Does Claude pull the right framework and apply it fully?
3. **An edge case** — Does Claude handle ambiguity according to the behavioral rules?
4. **A request that conflicts with a rule** — Does Claude follow the system prompt's constraints?

If any of these fail, the project needs adjustment. Common fixes: tighten scope control, add examples to knowledge files, or simplify competing instructions.

## Shared vs. Personal Projects

**Personal projects** can include:
- User's name and personal preferences
- Specific account details (platforms, account types)
- Communication style tailored to one person
- References to the user's history, habits, or working style

**Shared/team projects** must:
- Use "the user" not a name
- Avoid baked-in personal preferences
- Keep instructions applicable to any team member
- Not assume a specific skill level (or explicitly state the assumed baseline)
- Avoid referencing individual accounts, tools, or workflows unless they're team-wide
