---
name: session-handoff
description: Use when handing in-flight work from one Claude Code session to another that native `--resume` cannot reach, across profiles (your default `~/.claude` and a second `CLAUDE_CONFIG_DIR` profile, often a personal `~/.claude-personal`) or across machines. A write/read pair. WRITE ("hand off", "pass to the next session", "leave a baton", "I'm switching profiles", "/session-handoff") runs the four-artifact synthesis then writes a project-keyed baton under ~/OPS/.claude-handoffs/pending/. READ ("resume handoff", "pick up where I left off", "what was I doing", "/session-handoff resume") loads this project's baton plus its referenced files and memory, summarizes, then archives it. Reuses pre-compact-synthesis; pairs with the handoff-check.sh SessionStart notifier. This skill owns the baton DOCUMENT; creating or switching the session container itself is remote-session's job. Claude Code only.
---

# Session handoff

You pass the baton between sessions that native `--resume` cannot bridge. Resume and chat history are per config dir: a session on a second profile (a different `CLAUDE_CONFIG_DIR`, e.g. `~/.claude-personal`) cannot resume a conversation from the default `~/.claude` profile, and neither crosses machines. A baton file in the shared OPS filesystem does, because both profiles and every synced machine see it once it is committed and pushed.

Batons are keyed by project so parallel sessions on different projects never surface or clobber each other's handoffs. One pending baton per project, at `~/OPS/.claude-handoffs/pending/<project-key>.md`. Compute the key with the shared helper, never by hand, so the write, the read, and the notifier always agree:

```bash
bash ~/OPS/.claude-handoffs/key.sh
```

The paths, the frontmatter fields, the baton template, the NTFS colon rule, and the legacy path all live in `mechanics.md`. Read it before you write or archive a baton.

## Two modes

Detect the mode from the user's phrasing, and from whether a pending baton already exists for this project.

## Write, leaving a session

A handoff write is a superset of pre-compact synthesis: the next session must resume cold from files alone. Do the full discipline, then write the portable baton.

1. Run the four-artifact synthesis. Reuse the `pre-compact-synthesis` skill's discipline, do not duplicate it: git committed and pushed (never to main without authorization), durable lessons saved and the `.claude-memory/` mirror pushed, tasks marked done or pruned. If something is dirty and needs a decision, surface it. Never write a baton that claims clean state when it is not.
2. Gather the frontmatter fields and, if the work lives in a project with its own `SESSION_HANDOFF.md`, update that file too and point to it. `mechanics.md` lists every field and how to derive it.
3. Write `pending/<project-key>.md` from the template in `mechanics.md`. Clobber guard: if a pending baton already exists for this same key, the previous handoff was never picked up. Tell the user and ask whether to archive the old one first or abort. Never silently clobber it. A baton for a different key is unrelated, leave it alone.
4. Commit and push the baton to the OPS repo with `chore(handoff): <goal>`. It crosses machines only once it lands on the remote. This is additive sync, the same exception the memory mirror uses.
5. Confirm in one screen: the baton path, what it captures, and that the next session in this project on either profile will see the SessionStart banner. Say plainly that sessions in other projects will not, since that is the point.

## Read, arriving in a session

1. Read this project's baton. Compute the key and read `pending/<key>.md`. If none is pending, check the legacy path per `mechanics.md`. If still nothing, say so: nothing to resume for this project.
2. Re-ground in OPS global doctrine. A resuming session usually jumped straight to "resume handoff" and skipped the normal startup, so the standing layer may not be loaded. Before acting on project work, sync OPS (`git -C ~/OPS pull --ff-only`) and read `CONTEXT/operating-doctrine.md` (the 15 principles, especially P14 falsifiable conclusions and P15 classify-by-altitude) plus `working-preferences.md`, and `about-me.md` and `brand-voice.md` if not already in context. The baton carries project context; doctrine is the standing layer the baton assumes. Never resume project work without it.
3. Note the crossing. If `written_by` differs from the current profile, say it ("resuming a DEFAULT baton on a SECOND profile") and flag that profile-specific MCP connectors may not be available when resuming tooling on the other profile.
4. Load the referenced context. Open the files in the baton's reading order, check git state of the named repo, and confirm HEAD matches `git_head`; if it moved, someone committed since, so reconcile before acting.
5. Summarize in one screen: the goal, where it was left, the proposed next action. Then ask whether to proceed or adjust.
6. Archive the baton only on an actual resume. Move it to `archive/<key>-<ts>.md` (colon-free `<ts>`, see `mechanics.md`), set `status: consumed`, record `consumed_by` and `consumed_at`, then commit and push with `chore(handoff): consume <goal>`. This stops the banner re-firing. If the user only wants to look, leave the baton pending.

The RESUME PROTOCOL block in the baton is the contract. On pickup, verify before acting, act on the NEXT ACTION and DECIDED items, never touch DO NOT, and ask on ASK OPERATOR rather than guess.

## Anti-patterns

- Don't overstate readiness. If git is dirty or a decision is open, the baton says so. A false "all clean" wastes the next session's trust.
- Don't auto-load on arrival. The hook notifies; pickup is explicit. Never inject baton content into a session the user did not ask to resume.
- Don't clobber an unconsumed baton for the same project. One pending baton per project is one in-flight task. Archive the first deliberately before writing a second. Batons for other projects are never yours to touch.
- Don't write the legacy `ACTIVE_HANDOFF.md` path. Always `pending/<key>.md`. The single global baton was the bug that surfaced one project's handoff in every unrelated session.
- Don't push to main as housekeeping. The baton and memory commits to OPS are the additive-sync exception; project code is not.
- Don't leave a consumed baton pending. Archive on resume, or the banner cries wolf and the user learns to ignore it.

## Related pieces

- `pre-compact-synthesis` is the four-artifact discipline the write reuses. When the user is compacting and handing off at once, run the synthesis once and write the baton as the durable anchor.
- `handoff-check.sh` (`~/OPS/.claude-config/hooks/handoff-check.sh`, SessionStart) prints the banner only for a pending baton matching this project's key. Notify only.
- `key.sh` (`~/OPS/.claude-handoffs/key.sh`) is the single source of truth for the project key. Write, read, and notifier all call it so the filename never drifts.
