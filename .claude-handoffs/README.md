# .claude-handoffs

Cross-session, cross-profile **handoff batons** — the manual proxy for
Claude Code's native `--resume` when resume can't reach (switching
accounts/profiles, or moving between machines).

Native `--resume` and chat history are **per config dir**, so a second
profile (e.g. run via a custom launcher with `CLAUDE_CONFIG_DIR` pointed at
a different config directory) can't resume your primary profile's
conversation, and vice versa. A baton file here is profile-agnostic (plain
filesystem, both profiles see it) and git-synced (so it crosses machines
too).

## Project-keyed (one baton per project)

Batons are keyed by **project** so parallel sessions on different projects
never surface or clobber each other's handoffs. The key is the git repo
toplevel (or the cwd if not in a repo), computed by `key.sh` — the single
source of truth used by **both** the notifier hook and the skill, so they
never drift.

## Layout

- `key.sh` — emits the project key for the current cwd. Used by
  `handoff-check.sh` and the `session-handoff` skill.
- `pending/<project-key>.md` — the in-flight baton for one project. At most
  one pending per project; concurrent projects each get their own file. YAML
  frontmatter: `status: pending | consumed`, `project_key`, who wrote it
  (WORK/PERSONAL), timestamp, machine, cwd, git position, and an optional
  pointer to a project's own `SESSION_HANDOFF.md`.
- `archive/<project-key>-<written_at>.md` — consumed batons, for history.
- `ACTIVE_HANDOFF.md` — **legacy** single-baton path. No longer written.
  `handoff-check.sh` still surfaces one IF its recorded `cwd` matches the
  current session (graceful migration); resume archives it like any other.

## Flow

1. **Write** — in the leaving session: say *"hand off"* / *"pass to the
   next session"* (or `/session-handoff`). Runs the full four-artifact
   synthesis (git, memory, tasks), computes the project key, then writes
   `pending/<key>.md` and commits + pushes it.
2. **Notify** — the next session in **that same project** (either profile,
   any machine) fires the shared `handoff-check.sh` SessionStart hook, which
   prints a one-line banner if a PENDING baton exists for the project's key.
   Sessions in other projects see nothing. Notify only — never auto-loads.
3. **Resume** — say *"resume handoff"* / *"pick up where I left off"*.
   Reads the project's baton + referenced files + memory, summarizes state,
   then moves it to `archive/` (marked consumed) so it won't re-fire.

Driven by the `session-handoff` skill. See
`~/OPS/SKILLS/session-handoff/SKILL.md`.
