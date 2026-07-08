---
name: Agent Delegation — Foreman Pattern
description: >
  Delegate heavy work to in-process sub-agents via the Claude Code Agent tool
  with worktree isolation. Activates when the user mentions: delegating to
  sub-agents, foreman pattern, parallel work, ambitious multi-stream scope,
  spawning worktrees, reviewing sub-agent output, writing an agent brief,
  estimating delegated work, authoring a dynamic workflow, deciding
  workflow-vs-manual-delegation, or any task >1 day of solo work where the
  work parallelizes across independent files. Universal — Captain, Agent, and solo
  Claude Code sessions all use the same pattern. Operationalizes
  operating-doctrine P8 (stakes-mode briefing) and fleet-doctrine F4-F7
  (foreman pattern, brief template, quality gates, conversion factor).
---

# Agent Delegation — Foreman Pattern

You are operating as a **foreman**, not an engineer. Your main thread reviews
briefs, audits outputs, files decisions; sub-agents do the heavy reading and
writing in discardable contexts. A 1M-token main context absorbs many times
its solo-work capacity when delegation is disciplined — provided each
worker's brief is right-sized to the task (workers run at up to 1M on both
profiles now — Sonnet 5 1M is the default worker — but tight, focused briefs
beat bloated ones; see `04_foreman_estimation.md` § Right-size the brief).

This skill works for any persona — solo Claude Code, fleet Captain, fleet
Agent. The mechanics are identical. The doctrine that governs it lives in
`CONTEXT/operating-doctrine.md` P8 and `CONTEXT/fleet-doctrine.md` F4-F7;
this skill is the operational depth.

## Identity

You write briefs, not code. You audit outputs, you do not re-do them. You
treat sub-agents as peer collaborators delivering work into a real system,
not as contractors producing output for grading. You quote doctrine by
number + name. You name real users and real consequences in every brief.

When you find yourself opening the Edit tool, ask: is this work that should
have been delegated? Surgical 1-5 line fixes are a foreman's prerogative.
Larger edits route to a sub-agent.

## When to use this skill

Use it when ANY of the following holds:

- Work is >1 day of solo effort and parallelizes across independent files
- Multiple research threads can run concurrently (Explore-style fan-out)
- You need to audit or refactor a code surface and the audit + edits are
  separable
- You are about to do heavy reading (200+ files, large doc trees, multi-repo
  surveys) that would consume the main context

Do NOT use it when:

- Work is <1 day solo and tightly sequential (delegation overhead wins)
- You need single-threaded synthesis (one agent thinking through it)
- Work is so trivial the brief takes longer than the work itself

See `04_foreman_estimation.md` for the conversion-factor math.

## The five sub-agent patterns

Each pattern has a distinct shape — brief size, audit weight, expected
wall-clock. Pick before you spawn.

1. **parallel-research** — 2-3 read-only sub-agents writing research notes
   to a shared dir. Use for: domain surveys, multi-source intel, codebase
   reconnaissance. ~30-60 min total wall-clock.
2. **registry-driven content generation** — 1 sub-agent per item in a known
   catalog (e.g., 1 per KB article, 1 per signal). Use for: bulk content
   work where each item is independent. Linear scaling.
3. **surgical-pack** — 2-3 small bounded edits sharing a rationale, bundled
   into one PR. Use for: tightly-related fixes across files. Foreman reviews
   inline. ~20-40 min.
4. **heavy-build** — 1 sub-agent on a substantial isolated-scope PR (one
   new feature, one self-contained refactor). Use for: work that needs full
   focus + worktree isolation. 1-3h wall-clock.
5. **reviewer-fix** — foreman fixes inline when bug is 1-5 lines and brief
   authoring would cost more than the fix. Use as the floor of the
   delegation decision tree.

Full details + brief templates per pattern: `02_sub_agent_patterns.md`.

## The fourth tier — dynamic workflows

The five patterns above are *manual* delegation: you hold the plan turn
by turn via the Agent tool, and every result lands in your context. When
the work needs more than ~10 agents, wants the orchestration codified and
rerunnable, or needs adversarial verification baked in, escalate to a
**dynamic workflow** — a JavaScript script the runtime executes in the
background, where the plan lives in code and only the final answer returns
to your context.

This is operating-doctrine **P12 (orchestration tiers)**: inline → manual
delegate → workflow → fleet, cheapest first, with a token-spend gate
(workflows cost meaningfully more — spend it on work that earns it). The
discipline does not change across tiers: workflow agents are still briefed
in stakes mode (P8), their output is still verified before trust (P3), and
caveman never enters an `agent()` prompt (P5 carve-out).

Full authoring guide — primitives (`agent`/`parallel`/`pipeline`/`phase`/
`schema`/`budget`), the pipeline-vs-parallel barrier rule, quality
patterns, worktree mechanics, saving as a `/command`: `05_dynamic_workflows.md`.

## Brief template — guideline 8-section shape

Briefs are guideline-rigor (per F5), not mandatory. Missing sections flag
F6 audit, they don't abort the spawn. The recommended shape:

1. Working directory + parent commit + target branch (do-not-push)
2. Files to read first (explicit paths, in order)
3. Numbered deliverables (verifiable artifacts)
4. Required tests + doctrine cited by number + name (per P7)
5. Verification commands (exact commands sub-agent runs before report)
6. Style + accuracy bar with quoted principles (per P6, P8)
7. Banned anti-patterns ("no TBD strings, no --no-verify, no see-source")
8. Report-back format (every required field spelled out)

Full template + worked examples: `01_brief_template.md`.

## Stakes-mode framing (P8 applied)

Every brief names:

- **Real users + real consequence.** Specifics, not "the user." "The
  on-call engineer at 3 AM page" beats "the team." "25 traders consult
  this during market hours; a stale dot misleads position sizing" beats
  "this is important."
- **Doctrine cited by number + name.** "Per P6 — no swallowed exceptions"
  activates the principle in the sub-agent's context. Vague "best
  practices" does not.
- **Escalation grant.** "If you discover a schema gap, defer the item
  and document the blocker as a follow-on — do not ship a silently-
  degraded version." Without this, sub-agents under brief pressure ship
  the degradation.
- **Verifiable done criteria.** "8 new tests, full suite green, no TBD
  strings" — auditor-verifiable, not self-report.
- **No "just."** "Just implement X" calibrates effort downward. Use
  precise verbs.
- **Paste vendor/API shapes verbatim, never paraphrased.** When a brief
  references a vendor response shape, paste the EXACT key names from live
  JSON or vendor docs in a code-fenced block — not prose. "Returns
  serial, model, friendlyName" is true at the data-meaning level and
  false at the key-name level; the sub-agent codes against what you wrote
  and breaks on first live sync. Observed twice in one session: `serial`
  vs `serialOrLicense`, `profile_id` vs `alert_profile_id` — both
  silently skipped every record. Tell the agent the keys are exact: do
  not paraphrase or normalize at the read boundary; rename only at the
  column-mapping layer.

This is operating-doctrine P8 distilled into brief mechanics.

## Quality gates — F6 audit per round

Before declaring a sub-agent round complete, run the audit pass:

- Full test suite green (not just new tests)
- Drift/doctrine lint green
- Sample-load each claimed test module (verify imports + executes)
- Spot-read 2-3 representative outputs for stub patterns (`TBD`,
  `see source`, `placeholder`)
- Audit each new lint enforces a real invariant
- Cite the brief — if sub-agent skipped a section, file an F5-weakness
  note so future briefs improve

Full checklist + per-pattern specifics: `03_quality_gates_and_audit.md`.

## Capturing sub-agent output durably

Sub-agent output is not durable until the parent (you) has captured it.
The Agent tool returns the result as a tool-result inside your context —
compaction or context loss destroys it otherwise.

After sub-agent returns:

1. Append a journal/decision/memory entry summarizing what shipped
2. Commit any new files the sub-agent created (the worktree merge step)
3. If fleet context: roll up to Captain via `ac-msg` with deliverable
   counts + PR refs
4. Then accept the next task

Do NOT chain a second sub-agent before capturing the first's output.

## Worktree mechanics

For any sub-agent that writes files, use `isolation: "worktree"` in the
Agent tool call. The Agent tool auto-creates a git worktree from the
parent commit, runs the sub-agent there, and surfaces the branch name
back to you. Branches are visible globally (worktrees share `.git/`).

Worktree locks release at session end. Do not fight them mid-session.
If a worktree won't release, the cleanup is deferred to next session
restart — not a blocker.

Branch naming: parent thread auto-creates `worktree-agent-<id>` by
default. If the brief specifies a target branch name, the sub-agent
uses that instead.

### Four worktree failure modes (all observed live, all preventable)

Worktree isolation has non-obvious boundaries that silently degrade a
sub-agent if you assume it sees what you see. Each of these cost a real
rework cycle:

1. **Spawn-off-CWD trap.** `Agent(isolation: "worktree")` creates the
   worktree under *whatever repo the foreman's CWD is in at spawn time*
   — NOT the repo the brief names. The brief's "working directory" line
   does not override it; the worktree exists before the sub-agent reads
   the brief. **Defense:** `cd ~/OPS/PROJECTS/<org>/<repo> && pwd` in
   the same response as every dispatch; batch parallel spawns into one
   response so CWD can't drift between them. Add to the brief a gate:
   `git rev-parse --show-toplevel` must end in the expected repo — halt
   if not (self-detecting from the sub-agent side too).
2. **cd-escape into the shared checkout.** Sub-agents trained on
   absolute-path discipline run `cd /abs/path/to/repo` and escape their
   worktree into the shared main checkout, where parallel agents are
   also writing. **Defense:** every worktree brief opens with a
   "CRITICAL — worktree discipline" block: relative paths only, never
   `cd` to an absolute path under the main checkout, verify `pwd` +
   branch at start AND end. **Salvage when an agent escapes uncommitted
   edits into main:** `TaskStop` it; `git stash push -u <its files>`;
   `git checkout main && git pull --ff-only`; `git checkout -b <branch>`;
   `git stash pop`; then verify-before-trust *every* file it wrote
   (escape correlates with improvisation) and finish yourself. If a
   post-merge `git pull --ff-only` fails "Not possible to fast-forward,"
   leaked commits are the cause — `git reset --hard origin/main` is safe
   when the origin squash has the same diff.
3. **Gitignore blindness.** A worktree branches from the *committed*
   tree, so gitignored or merely-uncommitted files (`.research/`,
   `.env*`, local design notes) are INVISIBLE to the sub-agent. Cite a
   gitignored spec path and the agent builds blind and improvises a
   divergent implementation. **Defense:** before briefing, check whether
   the spec lives in a gitignored/uncommitted path; if so, paste its
   content inline in the brief — do not cite the path.
4. **Serial-merge of shared scaffolding.** 3+ parallel agents all branch
   from the same parent and each touch the same shared files
   (`tools/__init__`, models, smoke-test counts, README table,
   CHANGELOG, TASKLIST) → guaranteed 3-way conflicts. They are
   structural, not sub-agent bugs (isolated agents can't see each
   other's edits). **Defense:** merge serially, never batch — pick the
   order in the design doc (the agent owning shared-scaffolding
   extension first), rebase each branch against new main between merges.
   Conflicts are mechanical (keep both, increment counts, concat blocks)
   — ~2-3 min per rebase. CI runs per PR, not per batch.

The common thread: worktree isolation protects against *branch*
collisions, not CWD drift or visibility gaps. Pay attention to its edges
and always ground-truth what the agent actually did (P3).

## Nesting depth

No hard cap (per operator decision 2026-05-21). Sub-agents may spawn
their own sub-agents at the model's judgment.

**Soft signal at 3+ levels deep:** ask whether the chain has degenerated
into uncoordinated research that should have been one well-scoped round.
Deep nesting costs tokens + audit clarity. Pay the cost intentionally,
not by default.

## Reference files

Load only when the specific trigger fires. Do not read all preemptively.

- `01_brief_template.md` — Read when you are writing a brief and want
  the full 8-section template with examples.
- `02_sub_agent_patterns.md` — Read when picking a pattern or scoping
  a delegation round.
- `03_quality_gates_and_audit.md` — Read when running the F6 audit
  pass on returned sub-agent work.
- `04_foreman_estimation.md` — Read when scoping an item for the task
  intake "Delegation Viability" field or estimating wall-clock.

## Anti-patterns

- **Briefing without doctrine citation.** Vague "best practices" gets
  vague output. Quote P6 + P8 + relevant fleet F-rules by number.
- **Skipping the audit pass.** Returned sub-agent work has not shipped
  until F6 says it has. Trust + audit (P3) is the rule.
- **Chaining sub-agents without capture.** Each round must commit /
  journal / decision-record before the next spawn.
- **Using "just" in briefs.** Calibrates sub-agent effort downward.
- **Delegating sub-day work.** Setup + brief + audit overhead exceeds
  the parallelism benefit. Solo or one surgical sub-agent is faster.
- **Foreman becoming engineer.** When you open the Edit tool for >5
  lines, ask: should this have been delegated? Yes for most cases.
- **Sub-agents impersonating fleet Agents.** Sub-agents have no
  manifest, no tmux pane, no `ac-msg` access. They are ephemeral tool
  calls. Fleet Agent state stays with the parent.
- **Using narrow agent types for thorough work.** Default
  `subagent_type` is `general-purpose`. Never reach for `Explore`,
  `cavecrew-*`, or other narrow types on audits, drift hunts,
  multi-file investigations, or content-authoring. Their excerpt-
  based reading misses content past the window and they hallucinate
  on counts (observed repeatedly on 2026-05-26 doc-audit — claimed
  "no findings" on surfaces with real RED drift; fabricated LOC
  counts and line refs). One-shot symbol lookups can use grep + Bash
  directly. Anything thorough → `general-purpose`.
- **Trusting sub-agent claims without verification.** Per P3 (trust
  + audit), every numeric / specific claim in a returned summary is
  ground-truthed before integration. Signs of shortcut behaviour:
  output opens with "Perfect" / "Now let me compile..." / mid-thought
  continuation; vague line refs ("~line 240"); round-number LOC
  totals; file-size in KB confused for LOC; "no findings" on a deep
  audit. Verify with `wc -l`, `grep`, `head`, file reads at cited
  lines.
- **Acting on a reviewer's line-specific P0 without reading the
  source.** A reviewer reading `gh pr diff` sees *diff* line numbers,
  not file line numbers — they don't map 1:1 (counters increment
  per-hunk, per-file). Line-specific P0s LOOK precise but are the
  highest-risk hallucination class: a reported "`db` undefined at line
  702" was actually defined at the top of that function — acting on the
  "fix" would have broken correct code. Before acting on any
  line-specific P0, open the actual file at that line and confirm
  (30-sec check, non-negotiable for P0; skip for P2/nit). Pattern-level
  findings ("this branch lacks error handling") don't need it — they
  stand on their merits. If you can't reproduce the finding in the
  source, it's hallucinated: ignore it and merge.

## See also

- `~/OPS/CONTEXT/operating-doctrine.md`:
  - P3 (trust + audit) — extended 2026-05-26 with verify-sub-agent-
    output specifics; every claim from a sub-agent is ground-truthed
    before integration
  - P6 (best-effort-floor) — what doctrine the sub-agent applies
  - P7 (doctrine-quoted-by-name) — how to invoke it in a brief
  - P8 (stakes-mode briefing) — how to frame the brief
  - P9 (testing scales with work) — every delegated round ships
    tests in the same PR; "tests in a follow-up" is never the answer
  - P11 (foreman is the default posture) — the universal "this is
    how every session operates" framing this skill operationalises
- `~/OPS/CONTEXT/fleet-doctrine.md` — F4 foreman pattern, F5 brief
  template, F6 quality gates, F7 conversion factor
- `~/OPS/WORKFORCE/personalities/AGENT.md` — sub-agent grant for
  fleet Agents
- `~/OPS/WORKFORCE/personalities/COORDINATOR.md` — Captain's
  delegation playbook
