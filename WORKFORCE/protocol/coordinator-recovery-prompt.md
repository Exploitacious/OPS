# Coordinator recovery prompt

**For the Operator:** paste the section below into your Coordinator
session when you sense alignment slipping (stale anchor, off-track
work, post-compact disorientation, missed gates, drifting from your
direction). The Coordinator reads it as an Operator instruction and
runs the recovery sequence step-by-step.

**For the Coordinator:** if you are reading this section under the
banner below, STOP all in-flight work and follow the steps in order.
This is not optional. Recovery is the priority.

---

## --- BEGIN OPERATOR-PASTABLE RECOVERY PROMPT ---

```
COORDINATOR RECOVERY — alignment may be slipping.

You're reading this because I (the Operator) have determined that
you may be off-anchor. This is not a punishment, it's a system
recovery procedure. Follow it step-by-step. Do not improvise. Do
not skip steps. Do not pivot to other work mid-sequence.

The whole sequence runs in YOUR session and outputs one paragraph
back to me at the end. Total time: 5-10 minutes.

────────────────────────────────────────────────────────────────
STEP 1 — Halt
────────────────────────────────────────────────────────────────
Do not act on any prior pending direction until this sequence
completes. If you are mid-assignment with a peer agent, DO NOT
release them; they continue their own work. You stop coordinator
activity.

Pulse: `$AC_FLEET/bin/ac-pulse --status blocked --blocked-on "recovery-sequence"`

────────────────────────────────────────────────────────────────
STEP 2 — Read sources in order, no shortcuts
────────────────────────────────────────────────────────────────
Re-read these files fully — not just titles, not just first
paragraphs. Treat this like cold-boot:

  1. ALL files in `$AC_ROOT/runtime/operator-directions/` (sorted
     newest first). Note: verbatim quotes from me.
  2. `$AC_FLEET/personalities/captain-standing-orders.md`
  3. `~/OPS/CONTEXT/operating-doctrine.md` — re-read Principle
     7 (alignment primacy) verbatim.
  4. `$AC_FLEET/personalities/COORDINATOR.md` — re-read the
     "Compaction lifecycle — HARD rules" section.
  5. The top of your own journal at
     `$AC_ROOT/runtime/journal/$AC_NAME.md` — current RESUME ANCHOR.
  6. Most recent 5 entries in `$AC_ROOT/runtime/decisions/`.

────────────────────────────────────────────────────────────────
STEP 3 — Peer state check
────────────────────────────────────────────────────────────────
For each manifest entry in `$AC_ROOT/runtime/manifest.d/` (except
`_coordinator.json`):

  - Read pulse via `$AC_FLEET/bin/ac-pulse --show` (set AC_NAME
    per peer).
  - Read last 30 lines of `$AC_ROOT/runtime/journal/<peer>.md`.
  - Check inbox: `find $AC_ROOT/runtime/inbox/<peer> -type f`.

For each peer, you should be able to answer in one sentence:
"What did they last ship, what's their current task, are they
alive/idle/stuck?"

────────────────────────────────────────────────────────────────
STEP 4 — Anchor diagnostic
────────────────────────────────────────────────────────────────
Run: `$AC_FLEET/bin/ac-post-compact-check`

Read the output carefully. One of four results:

  - ALIGNED — anchor matches latest direction; you may be off
    in something other than the quote-diff dimension. Proceed
    to step 5 to surface implicit-direction concerns.
  - STALE — anchor does NOT match latest direction. Proceed
    to step 5; you'll refresh the anchor.
  - AMBIGUOUS — anchor matches but direction is stale relative
    to recent activity. Proceed to step 5 to surface this.
  - no-directions — no operator-directions/*.md exist yet.
    This is an early-project state; refresh the anchor anyway
    and tell me what's happened so I can file a direction.

────────────────────────────────────────────────────────────────
STEP 5 — Refresh anchor
────────────────────────────────────────────────────────────────
Run: `$AC_FLEET/bin/ac-pre-compact`

This rewrites the RESUME ANCHOR block from current filesystem
state. Verify by reading the new top of your journal.

Then re-run: `$AC_FLEET/bin/ac-post-compact-check`

If the second run does NOT return ALIGNED → there's a deeper
problem (ac-pre-compact bug, missing operator-directions file,
parsing error). Pause and surface the error to me directly.

────────────────────────────────────────────────────────────────
STEP 5b — File implicit-direction captures (one file per workflow)
────────────────────────────────────────────────────────────────
If step 6 below reveals implicit directions you've been operating
on, file them BEFORE step 7 reporting — not after.

CRITICAL — one operator-direction file per workflow scope, NOT
per session. Bundling unrelated asks into a single mega-direction
makes the file unparseable as authority. Examples:

  ✓ Right: 2026-05-13__post-debate-build-batch.md (memory-sync +
    claude-wrapper + auto-heal + curl|bash fix — all one workflow)
  ✓ Right: 2026-05-13__machine-recovery-old-host.md (pull-conflict
    on different machine — different scope)
  ✗ Wrong: 2026-05-13__all-the-implicit-directions.md (lumps
    everything into one untraceable mass)

For each ask you cannot quote verbatim from an Operator message:
mark it INFERRED in the file body with a one-line justification.
Future-you needs to know what was quoted vs interpreted.

After filing, run ac-pre-compact + ac-post-compact-check again.
ALIGNED state on a fresh direction is the goal.

────────────────────────────────────────────────────────────────
STEP 6 — Honest self-assessment
────────────────────────────────────────────────────────────────
Answer each of these to yourself before writing the report:

  Q1: Can I quote the latest operator-direction verbatim, with
      a source filename?
  Q2: Do I know each peer's current state (task, pulse, last
      ship)? If any peer is stale or stuck, do I have a plan?
  Q3: Are there any work threads I was mid-flight on that I'd
      forgotten? (Check journal RESUME ANCHOR commitments
      against actual recent activity.)
  Q4: Is there any artifact (decision, improvement, deliverable)
      drafted but not durably saved/promoted?
  Q5: Have I been operating on implicit direction (Operator
      messages that weren't captured as operator-directions/)?
      If yes — list them. They need to be filed verbatim, OR
      surfaced as "I think you meant X, confirm?"

Self-assess drift severity: NONE / LOW / MODERATE / HIGH /
CATASTROPHIC.

  - NONE: anchor was ALIGNED before refresh, no peer drift, no
    forgotten threads, no implicit direction.
  - LOW: minor staleness or one missed checkpoint, no work
    quality impact.
  - MODERATE: stale anchor + implicit direction + some forgotten
    state (the 2026-05-13 case).
  - HIGH: agent-shadowing or workflow editing without trace,
    re-asking known answers, or material work done on
    unauthorized scope.
  - CATASTROPHIC: irreversible action without Operator approval,
    fabricated operator-direction, false claim of task completion.

────────────────────────────────────────────────────────────────
STEP 7 — Report back to me
────────────────────────────────────────────────────────────────
One paragraph (5-8 sentences). No headers, no bullet lists. Send
as a normal turn response. Format:

  Recovery sequence complete. Drift severity: <NONE|LOW|MODERATE|
  HIGH|CATASTROPHIC>. Latest filed Operator direction (verbatim):
  "<quote>" (source: <filename>). Anchor state: <result of second
  post-compact-check>. Peers: <one sentence per active peer with
  current state>. Forgotten threads or drafted-not-saved artifacts:
  <list, or "none">. Implicit directions I've been operating on:
  <list, or "none">. Proposed next action: <one sentence>.

Then STOP and wait for me to respond. Do not resume work, do not
spawn new agents, do not file new decisions until I confirm.

────────────────────────────────────────────────────────────────
After my response
────────────────────────────────────────────────────────────────
If I file a fresh operator-direction → re-run STEP 5 to refresh
anchor against it, then post-compact-check → ALIGNED.
If I confirm the proposed next action → resume.
If I correct → file the correction as a new operator-direction
verbatim, refresh anchor, then ack the new direction inline
before any other action.

Recovery sequence is now complete. Resume normal operation.
```

## --- END OPERATOR-PASTABLE RECOVERY PROMPT ---

---

## When to use this

The Operator pastes the recovery prompt when ANY of these signals
fire, even subtly:

- Coordinator's last reply doesn't reference the latest direction
  the Operator gave.
- Coordinator is mid-task on something the Operator doesn't
  remember authorizing.
- Coordinator just resumed from auto-compact and didn't open with
  the alignment-ack template.
- Peers have been working but the Coordinator hasn't checked their
  state in > 1 hour.
- Coordinator's pulse `status` and `current_task` are
  inconsistent.
- Coordinator is re-asking a known answer (signals stale
  operator-directions awareness).
- Operator just feels off about the trajectory and wants a hard
  re-anchor.

Cost is cheap (5-10 min). Benefit is large (catches drift before
it compounds). Use it liberally.

## Notes on extending the prompt

The prompt above is intentionally self-contained — it doesn't
reference doctrine the Coordinator might have forgotten. Every
step is explicit. If you find a new drift mode worth adding:

1. File an `improvements/<date>__recovery-prompt-extension.md` in
   the active project.
2. Get Operator approval on the addition.
3. Edit this file to add the step.
4. Promote to `protocol/lessons/` at next project close.

Recovery-prompt edits are doctrine-level changes. Treat them with
the same gravity as personality-file edits.
