# Baton mechanics

Read before writing or archiving a baton. Paths, the project key, frontmatter fields, the template, the filename rule, and the legacy path.

## Paths and the project key

- Pending baton: `~/OPS/.claude-handoffs/pending/<project-key>.md`. Create the `pending/` dir if it is absent.
- Archived baton: `~/OPS/.claude-handoffs/archive/<project-key>-<ts>.md`.
- The project key is the git repo toplevel, or the cwd when not in a repo, with slashes turned to dashes and leading dashes stripped. Compute it with `bash ~/OPS/.claude-handoffs/key.sh`, never by hand. That helper is the single source of truth the write, the read, and `handoff-check.sh` all call, so the filename can never drift between them.

## The filename colon rule

The archive `<ts>` uses dashes, never colons: `date -u +%Y-%m-%dT%H-%M-%SZ`. Never put a `:` in any baton filename. NTFS reads a colon as an alternate-data-stream separator, so a colon-named file blocks `git checkout` on every Windows clone and stalls the whole sync. The `written_at` frontmatter field keeps its ISO colons because that is file content, not a filename.

Batons are profile-agnostic plain files and git-tracked, so they cross both profiles and every machine once committed and pushed.

## Frontmatter fields

Derive each field, then fill the template.

- `project_key`: output of `key.sh`. This is both the filename stem and a field.
- `written_by`: the profile the baton was written on. `DEFAULT` if `CLAUDE_CONFIG_DIR` is unset or ends in `.claude`; otherwise the config-dir basename (e.g. `PERSONAL` for `~/.claude-personal`).
- `account`: the operator email if known.
- `written_at`: `date -u +%Y-%m-%dT%H:%M:%SZ` (colons kept, it is content).
- `machine`: `hostname`.
- `cwd`: the absolute working directory.
- `git_repo`, `git_branch`, `git_head`: the primary repo's path or name, branch, and short SHA.
- `project_handoff`: if the work lives in a project with its own `SESSION_HANDOFF.md`, update that file too and set this to its repo-relative path. Otherwise `null`, and keep the baton self-contained.

## Baton template

```markdown
---
status: pending
project_key: <output of key.sh>
written_by: DEFAULT         # or the second profile's config-dir basename
account: <email if known>
written_at: 2026-06-07T22:30:00Z
machine: <hostname>
cwd: <absolute path>
git_repo: <repo path or name>
git_branch: <branch>
git_head: <short sha>
project_handoff: <repo-relative path to SESSION_HANDOFF.md, or null>
---

# Handoff: <one-line goal, the north star>

## RESUME PROTOCOL
- NEXT ACTION: <exactly one concrete step, not "continue work">
- VERIFY FIRST: <2-3 facts to re-confirm against the code or files, not infer>
- DO NOT: <tempting but out of scope, leave alone>
- DEAD ENDS: <already tried and abandoned, do not retry>
- ASK OPERATOR: <open decisions to ask about, not guess; "none" if clean>

## Where I left off
<exact current state: what is half-done, what is the very next keystroke>

## Done this session
- <shipped / decided / changed>  [tag each: DECIDED / PROPOSED / OPEN]

## Key files
- `<path>`: <why it matters>

## Context the next session needs
<reasoning, why an approach was chosen, anything not already in git, memory, or
tasks. Skip what is durable elsewhere.>

## Reading order for pickup
1. OPS global doctrine: `CONTEXT/operating-doctrine.md` (15 principles) plus `working-preferences.md`, the standing layer, re-ground here first
2. this baton
3. <project SESSION_HANDOFF.md / specific files / specific memory>
4. ...
```

Keep it dense and concrete. The test: can a cold session reach the same next action you would, and avoid the wrong ones, from this baton plus what it points to? The RESUME PROTOCOL is the contract; everything below is supporting detail. Tag every carried item DECIDED (act on it), PROPOSED (weighed only, do not execute), or OPEN (ask). Lead the reading order with the OPS standing layer before project state, so the resuming session re-grounds in doctrine, not just project facts.

## Legacy ACTIVE_HANDOFF.md

A single `~/OPS/.claude-handoffs/ACTIVE_HANDOFF.md` predates project-keying. The notifier still surfaces it only when its recorded `cwd` matches the current session, a graceful migration. On resume, archive it the same colon-free way as any other baton. Never write that path again. Always write `pending/<key>.md`. The single global baton was the bug that blasted one project's handoff into every unrelated session.
