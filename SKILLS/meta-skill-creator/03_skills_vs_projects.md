# Skills vs Projects — Dual-Track Doctrine

Reference this when deciding **where** a new capability should live, or when migrating an existing capability between deployment surfaces.

## The Two Surfaces

### Claude Code Skills
- **Where**: Files on disk. `SKILL.md` + optional reference files. Deployed at `~/.claude/skills/<name>/`.
- **Loading**: Lazy. Only `name` + `description` injected at session start (tiny token cost). The full `SKILL.md` body and any reference files load only when Claude judges the user's request matches the description.
- **Trigger**: Model-invoked. Claude reads description, decides "this fits", reads `SKILL.md`, may then `Read references/<file>.md` for deeper context.
- **Capabilities**: Can ship executable scripts, enforce workflows via tool restrictions (`allowed-tools` frontmatter), call MCP servers, run code, edit files.
- **Portability**: Files in git. Symlink/junction across machines. Share via repo (e.g. OPS).
- **Versioning**: Yes (git).
- **Composability**: Multiple skills can be loaded per session and fire independently.
- **Cost model**: You pay tokens only when the skill activates. 99% of sessions: zero cost for skills that don't match.

### Claude.ai GUI Projects
- **Where**: Anthropic cloud. Tied to your account. Visible at claude.ai → Projects.
- **Loading**: Eager. System prompt is prepended to every conversation in the project. Knowledge files are retrievable via the project's vector store on demand.
- **Trigger**: Manual. You pick the project before starting a chat.
- **Capabilities**: Text-only. No scripts, no MCP, no file-system access (unless Anthropic adds connectors in the cloud).
- **Portability**: Not portable. Locked to your Anthropic account. No git, no export beyond manual.
- **Versioning**: No.
- **Composability**: One project per conversation. Switch projects = switch context.
- **Cost model**: System prompt tokens charged every turn (cached, but still loaded).

## Decision Matrix

| Need | Best surface |
|------|--------------|
| CLI / headless Linux / multi-machine dev workflow | **Skill** |
| Mobile use (phone, on the go) | **Project** |
| Casual chat / browse-and-think workflow | **Project** |
| Triggered by clear keywords in conversation | **Skill** |
| Requires executing code, calling APIs, file ops | **Skill** |
| Reused across many machines via git | **Skill** |
| One-off persistent workspace for a specific topic | **Project** |
| Needs to enforce tool restrictions | **Skill** (`allowed-tools`) |
| Shared with non-CLI team members | **Project** (or both) |

## Default: Build Both

The Operator's default is **build both**, in this order:

1. Author the source folder in `SKILLS/<name>/` with shared knowledge files.
2. Write `SKILL.md` for Claude Code (lazy load, trigger-based).
3. Write `00_System_Prompt.md` for GUI Project (always-on framing).
4. Deploy skill: nothing to do per-entry. `~/.claude/skills/` symlinks `SKILLS/`, so it loads on next session.
5. Mirror to GUI Project manually (paste sysprompt, upload knowledge files).

Reason: the Operator uses both surfaces. Mobile Claude doesn't see skills. Headless Linux doesn't see projects. Building both makes the capability available everywhere.

**Exceptions where you skip one:**

- **Skill-only**: Capability requires tool execution (MCP, scripts, file ops). GUI can't run these. No point mirroring.
- **Project-only**: Capability is conversational / advisory only and is used almost exclusively on mobile or in casual chat. No CLI use case. (Rare.)

## Same content, different framing

The numbered `0X_*.md` knowledge files are shared between surfaces. The two wrappers differ:

| Aspect | `SKILL.md` (Skill) | `00_System_Prompt.md` (Project) |
|--------|--------------------|----------------------------------|
| Loaded | Lazy, on trigger | Eager, every turn |
| Frontmatter | YAML: `name`, `description`, `allowed-tools` | None (paste body into Project field) |
| Trigger | Description matched by Claude | Manual (user picks project) |
| References | Lazy: `Read references/01_*.md` when needed | Routing instructions: "consult `01_*.md` when..." |
| Token budget | Body < 2,000 words; refs unlimited | Body < 1,500 words; knowledge files unlimited |

When you write the wrappers, keep them parallel. Same identity. Same behavioral constraints. Same scope control. The only differences should be the loading mechanic and frontmatter.

## Migration paths

### Cloud Project → Skill (+ keep both)

When you have an existing Project in claude.ai with no portable backup:

1. Open Project in claude.ai → settings.
2. Copy the system prompt → save to `SKILLS/<slug>/00_System_Prompt.md`.
3. Download each knowledge file → save to `SKILLS/<slug>/0X_*.md` (preserve numbering).
4. Author `SKILL.md` based on the sysprompt — lazy-load framing, frontmatter with trigger description.
5. Author `README.md` for the entry.
6. No junction needed per-entry. Entry auto-loads via the `~/.claude/skills/ → SKILLS/` symlink.
7. Test the skill in a new Claude Code session.
8. The GUI Project stays as-is (already deployed). Updates flow: edit files in `SKILLS/`, then manually re-paste sysprompt + re-upload knowledge files to refresh the cloud Project.

### Skill → Project (mirror)

When a Skill exists and you want GUI access:

1. Open `SKILLS/<name>/`.
2. Adapt `SKILL.md` body → `00_System_Prompt.md`. Remove Claude Code specifics (`Read references/...`). Replace with GUI-style file routing ("consult `01_*.md` when...").
3. Knowledge files are already shared.
4. In claude.ai: create Project → paste sysprompt → upload knowledge files.

### Project-only → Archive

Some Projects are mobile-only or experimental. Don't force a skill build for those:

1. Drop content into `SKILLS/<slug>/` for backup + cross-machine visibility.
2. No `SKILL.md`. Set status in `README.md`: "archive-only — used as GUI Project on mobile, no CLI use case."
3. Skip the `SKILL.md` file. Claude Code's loader ignores entries without `SKILL.md`, so it won't activate as a skill.

## Updating the cloud after a skill change

This is the manual cost of dual-track. After editing files in `SKILLS/<name>/`:

- **Skill**: Already live. Next Claude Code session picks up the changes via the symlink chain.
- **GUI Project**: Manual refresh required.
  - Re-paste `00_System_Prompt.md` into the Project's instructions field.
  - Delete and re-upload changed knowledge files.

Acceptable cost. Skills are the primary surface; the GUI Project is the mobile fallback.

## When NOT to mirror

Skip the GUI Project if:

- The skill's value is entirely tool execution (`mcp:*` calls, file edits). The GUI can't replicate this. A Project version would be a hollow shell.
- The skill is project-scoped (lives inside a specific repo, references that repo's structure). Not useful as a freestanding mobile capability.
- The skill is meta-tooling (e.g., `meta-skill-creator` arguably needs both — you author capabilities from your phone too — but a skill like `db-backup-runner` is CLI-only by definition).

Use the decision matrix above. When in doubt: build both. The marginal cost of writing the second wrapper is low.
