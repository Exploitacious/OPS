---
name: session-handoff
description: >
  Hand off in-flight work from one Claude Code session to another across
  profiles (e.g. your default `~/.claude` profile and a second one launched
  via a different `CLAUDE_CONFIG_DIR`) or machines, mimicking native
  `--resume` when resume can't reach. A write/read pair. WRITE
  ("hand off", "pass to the next session", "leave a baton", "I'm switching
  to personal/work", "/session-handoff"): runs the full four-artifact
  synthesis then writes a PROJECT-KEYED baton at
  ~/OPS/.claude-handoffs/pending/<project-key>.md. READ ("resume
  handoff", "pick up where I left off", "what was I doing",
  "/session-handoff resume"): loads this project's baton + referenced files
  + memory, summarizes, then archives it. Pairs with pre-compact-synthesis
  (which it reuses) and the handoff-check.sh SessionStart notifier. Claude
  Code only.
---

# Session Handoff

You pass the baton between Claude Code sessions that native `--resume`
can't bridge. Resume and chat history are **per config dir**: if you run a
second profile via a different `CLAUDE_CONFIG_DIR` (e.g. a personal profile
alongside your default `~/.claude` one), a session under one profile cannot
resume a conversation started under the other, and neither crosses
machines. A baton file in the **shared** OPS filesystem does — every
profile and every synced machine see it. (If you only ever run a single
profile, this mechanic simply never triggers — the baton still bridges
machines on its own.)

You have two modes. Detect which from the user's phrasing and from whether
a PENDING baton already exists **for this project**.

## The baton (project-keyed)

Batons are keyed by **project** so parallel sessions on different projects
never surface or clobber each other's handoffs. One pending baton per
project:

`~/OPS/.claude-handoffs/pending/<project-key>.md`

The **project key** is the git repo toplevel (or the cwd if not in a repo),
slashes→dashes, leading dashes stripped. Do NOT hand-derive it — compute it
with the shared helper so the WRITE, the READ, and the `handoff-check.sh`
notifier always agree:

```bash
bash ~/OPS/.claude-handoffs/key.sh
```

Consumed batons move to `~/OPS/.claude-handoffs/archive/<key>-<ts>.md`,
where `<ts>` is the archive timestamp **with colons replaced by dashes**:
`date -u +%Y-%m-%dT%H-%M-%SZ`. **Never put a `:` in the filename** — NTFS
treats it as an alternate-data-stream separator, so a colon-named baton
blocks `git checkout` on every Windows clone and stalls the whole sync.
(The `written_at` frontmatter field below keeps its ISO colons — that's file
content, not a filename.) Batons are profile-agnostic (plain filesystem) and
git-tracked, so they cross profiles AND machines once committed + pushed.

> Legacy: a single `ACTIVE_HANDOFF.md` was used before project-keying. The
> notifier still surfaces one if its `cwd` matches the current session; on
> resume, archive it the same way. Never write that path again — always
> write `pending/<key>.md`.

---

## MODE 1 — WRITE (leaving a session)

Triggers: "hand off", "pass to the next session", "leave a baton", "I'm
switching to personal/work now", "save where I am", `/session-handoff`
with no resume intent.

A handoff write is a **superset of pre-compact synthesis** — the next
session must resume cold from files alone. Do the full discipline, then
write the portable baton.

1. **Run the four-artifact synthesis.** Reuse the `pre-compact-synthesis`
   skill's discipline verbatim — do not duplicate the logic, follow it:
   - **Git** — for each touched repo: surface uncommitted changes; confirm
     local commits are pushed (never push to main without authorization).
   - **Auto-memory** — save durable lessons not yet saved; commit + push
     the `.claude-memory/` mirror (the documented additive-sync exception).
   - **Tasks** — mark done, prune dead, add emerged follow-ons.
   If something is dirty and you can't resolve it without a decision,
   surface it — don't write a baton that claims clean state when it isn't.

2. **Detect profile + context** for the frontmatter:
   - `project_key`: run `bash ~/OPS/.claude-handoffs/key.sh` — this is
     the baton filename stem AND a frontmatter field.
   - `written_by`: `WORK` if `CLAUDE_CONFIG_DIR` is unset or ends `.claude`
     (the default profile); `PERSONAL` if it points at a second,
     differently-named profile dir.
   - `written_at`: `date -u +%Y-%m-%dT%H:%M:%SZ`.
   - `machine`: `hostname`.
   - `cwd`, and git `repo`/`branch`/`head` for the primary repo.
   - `project_handoff`: if the work lives in a project that has its own
     `SESSION_HANDOFF.md`, update THAT file too (per pre-compact-synthesis)
     and point to it here, repo-relative. Else `null` and keep the baton
     self-contained.

3. **Write `pending/<project-key>.md`** using the template below (create
   `~/OPS/.claude-handoffs/pending/` if absent). **Clobber guard:** if a
   PENDING baton already exists *for this same project key*, the previous
   handoff was never picked up — tell the user, and ask whether to overwrite
   (archive the old one to `archive/<key>-<old_ts>.md`, colon-free `<ts>`, first) or
   abort. Don't silently clobber an unconsumed baton. A baton for a
   *different* project key is unrelated — leave it alone.

4. **Commit + push the baton** (OPS repo). It only crosses machines if
   it lands on the remote. Conventional Commits: `chore(handoff): <goal>`.
   This is additive sync like the memory mirror — same exception applies.

5. **Confirm** in one screen: baton path (`pending/<key>.md`), what it
   captures, and that the next session **in this project** (either profile)
   will see the SessionStart banner. Note that sessions in other projects
   will NOT see it — that is the point.

### Baton template

```markdown
---
status: pending
project_key: <output of key.sh>
written_by: WORK            # or PERSONAL
account: <email if known>
written_at: 2026-06-07T22:30:00Z
machine: <hostname>
cwd: <absolute path>
git_repo: <repo path or name>
git_branch: <branch>
git_head: <short sha>
project_handoff: <repo-relative path to SESSION_HANDOFF.md, or null>
---

# Handoff: <one-line goal — the north star>

## RESUME PROTOCOL
- NEXT ACTION: <exactly one concrete step — not "continue work">
- VERIFY FIRST: <2-3 facts to re-confirm against the code/files, not infer>
- DO NOT: <tempting but out-of-scope — leave alone>
- DEAD ENDS: <already tried + abandoned — do not retry>
- ASK OPERATOR: <open decisions to ask about, not guess; "none" if clean>

## Where I left off
<exact current state: what's half-done, what's the very next keystroke>

## Done this session
- <shipped / decided / changed>  [tag each: DECIDED / PROPOSED / OPEN]

## Key files
- `<path>` — <why it matters>

## Context the next session needs
<reasoning, why an approach was chosen — anything not in git/memory/tasks.
Skip what's already durable elsewhere.>

## Reading order for pickup
1. OPS global doctrine — `CONTEXT/operating-doctrine.md` (15 principles) + `working-preferences.md` (the standing layer; re-ground here first)
2. this baton
3. <project SESSION_HANDOFF.md / specific files / specific memory>
4. ...
```

Keep it dense and concrete. The test: can a cold session reach the same
next action you would — and avoid the wrong ones — reading only this + what
it points to? The RESUME PROTOCOL is the contract; everything below is
supporting detail. On pickup (Mode 2), the resuming session honors it:
verify before acting, act on NEXT ACTION + DECIDED items, never touch DO
NOT, and ask on ASK OPERATOR rather than guess.

---

## MODE 2 — READ / RESUME (arriving in a session)

Triggers: "resume handoff", "pick up where I left off", "what was I
doing", "continue from the handoff", `/session-handoff resume`. Also when
the SessionStart banner announced a pending baton and the user acts on it.

1. **Read this project's baton.** Compute the key
   (`bash ~/OPS/.claude-handoffs/key.sh`) and read
   `~/OPS/.claude-handoffs/pending/<key>.md`. If none or not pending,
   check the legacy `ACTIVE_HANDOFF.md` (only relevant if its `cwd` matches
   this session). If still nothing, say so plainly — nothing to resume for
   this project.
2. **Re-ground in OPS global doctrine.** A resuming session usually jumped
   straight to "resume handoff" and skipped the normal startup sequence — so
   the standing universal layer may not be loaded. Before acting on project
   work: sync OPS (`git -C ~/OPS pull --ff-only`) and read
   `CONTEXT/operating-doctrine.md` (the 15 principles — especially P14
   constraint-driven/falsifiable conclusions + P15 classify-by-altitude) +
   `working-preferences.md` (+ `about-me.md` / `brand-voice.md` if not already
   in context). The baton carries PROJECT context; doctrine is the standing
   layer the baton assumes. Never resume project work without it.
3. **Note the crossing** — if `written_by` differs from the current
   profile, say it ("Resuming a WORK baton on PERSONAL"). Flag that
   work-only MCP connectors won't be available if resuming work tooling on
   a different profile.
4. **Load the referenced context** — open the files in "Reading order",
   check git state of the named repo (`git status`, confirm HEAD matches
   `git_head`; if it moved, someone committed since — reconcile), read the
   pointed-to project `SESSION_HANDOFF.md` and any named memory.
5. **Summarize** in one screen: the goal, where it was left, the proposed
   immediate next action. Then ask whether to proceed or adjust.
6. **Archive the baton** — move it to
   `archive/<project-key>-<ts>.md` (colon-free `<ts>` = `date -u +%Y-%m-%dT%H-%M-%SZ`;
   never a `:` in the filename — see "Consumed batons" above), set `status: consumed`, and
   record `consumed_by` + `consumed_at`. Commit + push
   (`chore(handoff): consume <goal>`). This stops the SessionStart banner
   from re-firing for this project.

If the user wants to look but not pick up, leave the baton pending — only
archive on an actual resume.

---

## Relationship to other pieces

- **`pre-compact-synthesis`** — the compaction safety net (within a session
  lifecycle). This skill reuses its four-artifact discipline for the WRITE,
  and adds the portable baton + READ side + cross-profile reach. When the
  user is compacting AND handing off, run the synthesis once and write the
  baton as the durable anchor.
- **`handoff-check.sh`** — `~/OPS/.claude-config/hooks/handoff-check.sh`,
  registered in `settings.json` SessionStart. Pure-shell notifier; computes
  the project key (via `key.sh`) and prints the banner only for a pending
  baton matching THIS project. Notify only.
- **`key.sh`** — `~/OPS/.claude-handoffs/key.sh`. The single source of
  truth for the project key. The WRITE, the READ, and the notifier all call
  it, so the baton filename never drifts between them.
- **Dual profiles** — an optional second profile (e.g. personal alongside
  work) launched via a different `CLAUDE_CONFIG_DIR`, separate config dirs,
  shared OPS layer + auto-memory. The baton lives in that shared layer,
  which is exactly why it bridges them.

## Anti-patterns

- **Don't write a baton that overstates readiness.** If git is dirty or a
  decision is unresolved, the baton must say so — a false "all clean"
  wastes the next session's trust.
- **Don't auto-load on arrival.** The hook notifies; pickup is explicit.
  Never inject baton content into a session the user didn't ask to resume.
- **Don't clobber an unconsumed baton for the same project.** One pending
  baton per project = one in-flight task there. If a second handoff is
  needed for that project, archive the first deliberately. Batons for other
  projects are unrelated — never touch them.
- **Don't write the legacy `ACTIVE_HANDOFF.md` path.** Always
  `pending/<key>.md`. The single global baton was the bug that surfaced one
  project's handoff in every unrelated session.
- **Don't push to main as housekeeping.** Baton + memory commits to OPS
  are the additive-sync exception; project code is not.
- **Don't leave a consumed baton active.** Always archive on resume, or the
  banner cries wolf and the user learns to ignore it.
