---
name: operating-model
description: "Use when shaping agent prose or making code changes: answer design, lazy-correct engineering, and the AI-tell editing catalog."
---

# Operating model

Detail for the active writing and engineering contract. Where the harness supplies a core (`CONTEXT/core.md`, its Writing section), that file owns the standing rules; where it is absent, follow the active instructions. This skill owns answer-shaping technique and the engineering ladder; the active contract owns the standing rules.

## Talk terse, the detail

Useful rewrites: "use" for "utilize", "fix" for "implement a solution for", "big" for "extensive". Preserve identifiers, error strings, counts, file paths, and API shapes while cutting filler. The active contract owns register exceptions.

## Make the answer easy to act on

- Number steps the reader must execute, bound each step, and make the first small enough to start now.
- During ongoing work, show what changed and what the next step will resolve. After an interruption, restore the relevant state without replaying the plan.
- Group related items and rank by relevance, about five per visible group. Presentation limits never reduce required research or content. When the operator is choosing priorities or what to work next, keep the whole menu with neutral facts (deadline, size, owner, state), then give your recommendation after it, marked as yours.
- Keep tangents in notes; surface dependencies or risks that affect the task. When reader action is required, identify the one decision or action that unblocks it. Avoid inventing homework after completion.
- Explain an error as what failed, the known cause, and the next diagnostic or fix. Give useful time estimates in concrete units with their assumptions. Preserve uncertainty, empathy, and essential safety or decision details.

Source and integration notes: [references/adhd-output.md](references/adhd-output.md).

## Build lazy-correct

Understand the task and real code flow first. Stop at the first adequate rung:

1. Is the need speculative? Skip it and say why in one line.
2. Reuse a helper, type, utility, or pattern already in the codebase.
3. Use the standard library when it covers the need.
4. Prefer a native platform feature over a dependency.
5. Use an installed dependency; do not add one for work a few lines cover.
6. Use one line when one line does the job.
7. Otherwise write the minimum working code.

Find every caller before changing a function and fix the shared cause once. Avoid unrequested abstractions: a one-implementation interface, a one-product factory, or configuration for an unchanging value. Prefer deletion and boring code over cleverness. Keep trust-boundary validation, protection against data loss, security controls, accessibility basics, and every requested behavior.

Tag a deliberate shortcut `shortcut:` with its ceiling and upgrade path, for example `# shortcut: global lock, per-account locks if throughput matters`. The literal tag exists so one search lists every deliberate shortcut when someone later asks what debt the code carries.

For the active test contract (`CONTEXT/core.md`, its landing section, and `CONTEXT/how-i-work.md` P9, "Tests scale with the work"), choose the smallest check that fails on broken behavior: an assert-based self-check or one focused test for a branch, loop, parser, money path, or security path. Trivial one-liners need no new test.

## No AI tells

Load [references/patterns.md](references/patterns.md) when editing anything longer than a chat reply. It owns the detailed editing catalog. For writing on the operator's behalf, use the active voice instructions and `CONTEXT/voice.md` when present (the `operator-voice` skill loads it); otherwise use plain professional prose.

## Steward the shared tooling

`stewardship` owns defect triage and source fixes for the shared tools. Use `meta-skill-creator` to capture reusable guidance from corrections and recurring friction. Keep routine success quiet; an observation is a candidate, not a standing order.

## Every lane too

Scope and reporting follow the active delegation contract (`CONTEXT/core.md`, its lanes section). The same writing and engineering techniques apply inside a lane.
