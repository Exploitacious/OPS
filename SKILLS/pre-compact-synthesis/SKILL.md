---
name: pre-compact-synthesis
description: Synthesize durable state before a /compact, then closeout. On compact, pre-compact, wrap up, do the thing, or any milestone or natural-break rest stop.
---

# Pre compact synthesis

You make sure the next Claude, the one that wakes post compact reading only the compaction summary plus durable files, continues without losing the thread. Compaction is a pause, not death (operating-doctrine P2).

Four places survive a compact verbatim: git, auto-memory, the task list, and durable anchor files. The conversation does not. So anything worth carrying forward lands in one of those four before the compact fires. A perfect compact is one where post-compact-you resumes cold from files alone and reaches the same decisions.

The PreCompact shell hook (`~/OPS/.claude-config/hooks/pre-compact.sh`) already wrote the mechanical snapshot (git state, branch, recent commits) under `${CLAUDE_CONFIG_DIR:-~/.claude}/projects/<workspace>/pre-compact-<ts>.md`. Your job is the thoughtful synthesis on top of it, plus the closeout hygiene pass. Work fast and complete: 60 to 90 seconds on a light session, five minutes on a heavy one. Speed never outranks completeness. Knowledge that dies with the context is the one loss this skill prevents.

## Pause or close first

This is the PAUSE ritual. The session continues after `/compact`, so it does NOT touch work-tracking: time, tickets, or the board. That reconciliation belongs at the end of the work, in session-close.

"Close out", "wrap up", and "done" are ambiguous. If the operator was actually finished and you pause-and-compact, their time and WIP never get reconciled. So on an ambiguous end-of-work phrase, ask one question first:

- Continuing this work next session? Then PAUSE: run this skill, compact, leave work-tracking alone.
- Done for the day or this purpose? Then hand to session-close, which runs this same synthesis, then reconciles time, tickets, and board per `CONTEXT/work-tracking.md`, then tears the session down.

Explicit "compact" / "pre-compact" and the `[context-watch]` nag are unambiguous pause signals. Proceed, no need to ask.

## The four artifacts

Walk in order. State each one's state in a sentence, then act, or surface for confirmation when the action is irreversible.

1. Git. `git status --short` per repo touched. Uncommitted changes? Local commits ahead of remote? Messages meaningful to a cold reader? Surface dirty state, never silently commit or push. Push to main is irreversible; never assume authorization.
2. Auto-memory. Walk the session's moments for lessons worth keeping (operator feedback, a surprising discovery, a non-obvious project fact, an external-system reference). Save anything unsaved under `~/.claude/projects/<workspace>/memory/` with the standard four-type frontmatter, and index it. Skip code patterns, ephemeral state, CLAUDE.md duplicates. Then commit and push the mirror at `~/OPS/.claude-memory/`, or it dies at the next clean clone (see anti-patterns for why this one commit is allowed).
3. Task list. Mark done tasks completed, delete speculative ones, add follow-on work that emerged. The summary preserves the list verbatim, so a clean list means a clean summary.
4. Durable anchor. Choose ONE by session type:
   - Fleet (AC_ROOT + AC_NAME set, journal exists): run `ac-pre-compact --silent`. Do not duplicate elsewhere.
   - Solo project with a `SESSION_HANDOFF.md`: update it with what shipped, what is queued, and pointers, then commit and push it.
   - Solo project without one: offer to create it if the session was significant. Do not impose.
   - Solo outside a project: git plus memory plus the task list carry it.

Lead every anchor's reading order with the OPS standing layer (`CONTEXT/operating-doctrine.md`, `working-preferences.md`) before project state, and confirm OPS is synced (`git -C ~/OPS pull --ff-only`). A session that re-grounds in project facts but not the doctrine drifts from how the operator wants work done.

## The resume protocol block

Post-compact sessions over-assume: the summary states positive next-steps but leaves the negative space unstated, and it flattens "we were considering X" into "we decided X". Name the vacuums. Put this at the TOP of every anchor you write:

```markdown
## RESUME PROTOCOL
- NEXT ACTION: <exactly one concrete step, not "continue work">
- VERIFY FIRST: <2-3 facts to re-confirm against code/files, not infer>
- DO NOT: <tempting but out-of-scope things to leave alone>
- DEAD ENDS: <already tried and abandoned, do not retry>
- ASK OPERATOR: <open decisions to ask about, "none" if clean>
```

Tag every carried item DECIDED (act on it), PROPOSED (do not execute, it was only weighed), or OPEN (ask). This keeps autonomy on verified ground; the bias still stays toward acting.

Ban session-boundary vocabulary from every artifact: no "stopping point", "wind-down", "ready for next session", "pick up later", "compact-ready". Post-compact, that language reads as a cue to pause and re-ask "stop or keep going?". Naming what is finished is not that vocabulary and is fine: a clean baton may say a task closed, a PR merged, or a plan settled (P2). The ban targets the stop-or-continue cue, not a factual record of what is done. NEXT ACTION is an instruction to execute, never a choice to deliberate. Frame the next session as continuing one body of work across the compact.

If you hit a decision you cannot resolve from code plus context, do not bake a guess in. Surface it. When the operator answers, write the resolution to a `project` memory so the question dies permanently, not just into the anchor.

## Closeout hygiene

The fifth stage makes the workspace clean and the docs true. Run on every closeout after substantive work; skip on bare conversation. One line each; the full procedure, the memory-routing table, and the migration vectors live in `closeout-hygiene.md`.

1. Run the machine gate: `~/OPS/.claude-config/bin/verify-ops.sh --quiet`. Fix every FAIL now or surface it with a reason.
2. Flush the memory cache. Every flush-queue line gets one of five dispositions (folded, split, kept, promoted-to-doctrine, promoted-to-standing-orders) and is then deleted. This is a gate, not a suggestion.
3. Docs reflect reality, per repo touched: CHANGELOG line, no doc claim made false, shipped IDEAS entries removed. "Fix it in a follow-up" is the violation this kills.
4. Sweep scratch files this session created.
5. Stamp it: `mkdir -p ~/.local/state/ops && date -Is > ~/.local/state/ops/last-closeout`.

Before you flush, feed the work-log: one narrative line so a multi-compact session's eventual close reads what happened. Compaction never logs time or touches a ticket. If the session shipped a migration or refactor, prose docs are not enough; see the migration vectors in `closeout-hygiene.md`.

## Process and exit

1. Read the latest `pre-compact-<ts>.md` snapshot if it exists; do not redo its mechanical work. If it is missing, run the hook manually, then continue.
2. Diagnose session type (fleet, solo-with-handoff, solo-bare) and branch.
3. Walk the four artifacts in order, acting or surfacing per artifact.
4. Append the work-log line, then run closeout hygiene.
5. Print the readiness summary.
6. Choose the exit. In tmux, a wrap-up trigger IS the go: run the whole self-compact cycle (`self-compact-cycle.md`), do not prepare and wait. Take the manual exit (print the summary, let the operator fire `/compact`) only when not in tmux, when the operator explicitly claimed the compact ("I'll compact myself", "hold off"), or when an ASK OPERATOR item is still open. Never compact over an unanswered question. On the manual exit, have the operator fire `/compact <instruction>` with the preservation instruction so a manual compact keeps the same detail the automated cycle does; the single source of that text is the `PRESERVE` variable in `~/OPS/.claude-config/bin/compact-cycle.sh`, so point at it rather than restating the points here.

## Readiness summary

```
Pre-compact synthesis complete.

1. Git: <state>. <action or "nothing to do">.
2. Auto-memory: <state>. <new memories or "none worth keeping">.
3. TaskCreate: <state>. <cleanups>.
4. Durable anchor: <type>. <action>.
5. Hygiene: verify-ops <ok/warn/fail>; <memories routed / docs fixed / scratch swept or "clean">.

Ready to /compact when you are.
```

Keep it tight. Four to five lines, no wall of text.

## Anti-patterns

- Never silently commit, push, or merge during synthesis, with one exception: the `~/OPS/.claude-memory/` mirror, which is pure additive sync the operator wants automated. Surface even that before committing; if told to skip, skip.
- Never push to main without authorization. An earlier in-conversation "push to main" does not cover pre-compact housekeeping commits.
- Never invent a handoff doc for a project without one. Offer, do not impose.
- Never duplicate fleet `ac-pre-compact` work. If AC_ROOT is set and the script exists, dispatch to it.
- Do not over-save memories. A bare session produces zero new ones, and that is correct.

## Edge cases

- Context low (<30%) but the user says compact: confirm they want it now; synthesis is fine to run regardless.
- Dirty tree, user mid-thought: surface, do not act. They may want the work-in-progress to die with the session.
