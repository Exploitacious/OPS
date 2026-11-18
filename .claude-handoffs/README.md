# .claude-handoffs

Cross-session, cross-profile **handoff batons**: the manual proxy for
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
toplevel (or the cwd if not in a repo), computed by `key.sh`, the single
source of truth used by the notifier hook, `session-end move` (which prints
the baton path) and the agent writing the baton, so they never drift.

## Layout

- `key.sh`: emits the project key for the current cwd. Used by
  `handoff-check.sh` and `.claude-config/bin/session-end`.
- `pending/<project-key>.md`: the in-flight baton for one project. At most
  one pending per project; concurrent projects each get their own file. YAML
  frontmatter: `status: pending | consumed`, `project_key`, who wrote it
  (WORK/PERSONAL), timestamp, machine, cwd, git position, and an optional
  pointer to a project's own `SESSION_HANDOFF.md`.
- `archive/<project-key>-<ts>.md`: consumed batons, for history. `<ts>` is
  `date -u +%Y-%m-%dT%H-%M-%SZ`, dashes and never colons: NTFS reads a colon in
  a file name as a stream separator, so one colon-named baton blocks `git
  checkout` on every Windows clone. The `written_at` field inside keeps its ISO
  colons (content, not a name).
- `ACTIVE_HANDOFF.md`: **legacy** single-baton path. No longer written.
  `handoff-check.sh` still surfaces one IF its recorded `cwd` matches the
  current session (graceful migration); resume archives it like any other.

## Flow

1. **Write**: the leaving session runs `session-end move`, which prints the
   baton path and whether an unread baton already sits there (never overwrite
   one; archive it deliberately first). The agent writes `pending/<key>.md`
   with the resume note at the top (the `harness` skill, "Ending a thread"),
   commits it, and pushes it when `.claude-config/bin/origin-private-check`
   verifies the OPS origin private (the git-guard hook blocks the push
   otherwise). Until it is pushed, no other machine sees it.
2. **Notify**: the next session in **that same project** (either profile,
   any machine) fires the shared `handoff-check.sh` SessionStart hook, which
   prints a one-line banner if a PENDING baton exists for the project's key.
   Sessions in other projects see nothing. Notify only; it never auto-loads.
3. **Resume**: say *"resume handoff"* / *"pick up where I left off"*.
   Read the project's baton and the files it points at, confirm the repo's
   HEAD still matches its `git_head` (if it moved, reconcile first), and treat
   its claims as hypotheses to re-check. Then, only on an actual resume, move
   it to `archive/` with `status: consumed`, `consumed_by` and `consumed_at`,
   commit and push under the same rule, so the banner stops firing. A look
   without a resume leaves it pending.
4. **Crossing profiles**: when the baton's writer differs from the current
   profile, say so; that profile's MCP connectors may differ.
