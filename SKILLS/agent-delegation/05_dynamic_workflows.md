# Dynamic Workflows — the programmatic delegation tier

> Read when authoring a Claude Code dynamic workflow, or deciding
> whether a task warrants one over manual Agent-tool delegation. This
> is the operational depth behind operating-doctrine **P12 (orchestration
> tiers)**. The manual foreman patterns in `02_sub_agent_patterns.md`
> still apply — a workflow is the same discipline, codified in a script
> that orchestrates dozens-to-hundreds of agents instead of a few.

## What a workflow is

A dynamic workflow is a **JavaScript script the runtime executes in the
background** while your session stays responsive. You (or the model)
write the script; the runtime fans out subagents (up to 16 concurrent,
1,000 total per run) and the *plan lives in code* — loops, branching,
intermediate results in script variables. Only the final return value
lands back in your context.

The difference from manual delegation, in one line: **with the Agent
tool you hold the plan turn-by-turn and every result hits your context;
with a workflow the script holds the plan and only the answer returns.**
That is what lets a workflow run at a scale one conversation cannot
coordinate, and what makes the orchestration itself repeatable.

## When to reach for a workflow (vs manual delegate, vs fleet)

Per P12, the tiers are: inline → manual delegate → **workflow** → fleet.
Escalate from manual delegation to a workflow when ANY holds:

- The work needs **more than ~10 agents**, or dozens-to-hundreds.
- The orchestration is **worth codifying and rerunning** (a review you
  run on every branch, a recurring audit) → save it as a `/command`.
- You want **adversarial verification baked in** — independent agents
  refuting each other's findings before anything is reported.
- The sweep is **too large for one context to hold** (codebase-wide
  audit, 500-file migration, multi-source research).

Stay at manual delegation when: <10 agents, you need to think between
rounds, the work is exploratory and the shape isn't known yet, or you
need single-threaded synthesis. Stay inline when sub-day / <3 files.

Use the **fleet** (`ACTIVATE`) instead when work spans *sessions* and
needs persistent human-async peers — not a bounded in-session burst.
A fleet foreman can fire workflows; the two compose.

**Token gate (P12).** Workflows cost meaningfully more than a normal
session. The gate is the value of the answer — large sweeps, high
cost-of-failure, repeatable orchestration — not the novelty of the
tool. When unsure, the cheaper tier is the default.

## How to invoke

- **One-off:** include the word `workflow` in your prompt. The model
  writes a script for the task instead of working turn-by-turn.
- **Session-wide:** `/effort ultracode` — `xhigh` reasoning + the model
  plans a workflow for every substantive task. Session-only, resets next
  launch (deliberate cost guard; not persistable via `effortLevel`).
- **Saved/bundled:** run an existing `/command`. `/deep-research` ships
  bundled. Save any run's script with `s` in `/workflows` → it becomes
  `/<name>` from `.claude/workflows/` (project, shared) or
  `~/.claude/workflows/` (personal, all projects).

## The primitives

Every script starts with a pure-literal `meta` block, then an async body:

```javascript
export const meta = {
  name: 'audit-endpoints',
  description: 'Audit every route for missing auth, verify each finding',
  phases: [{ title: 'Find' }, { title: 'Verify' }],   // one per phase()
}
// body — await directly; standard JS built-ins EXCEPT Date.now()/
// Math.random()/argless new Date() (they break resume — pass time via args)
```

- **`agent(prompt, opts?)`** → spawns one subagent. Without `schema`
  returns its final text (string). With `schema` (a JSON Schema) the
  agent is forced to return a validated object — no parsing, the model
  retries on mismatch. Returns `null` if the user skips it; filter with
  `.filter(Boolean)`. Key opts: `label`, `phase` (progress group),
  `schema`, `model` (omit to inherit session model — almost always
  right), `agentType` (e.g. `general-purpose`, or a custom agent),
  `isolation: 'worktree'`.
- **`pipeline(items, stage1, stage2, …)`** → each item flows through all
  stages independently, **no barrier between stages**. Item A can be in
  stage 3 while item B is still in stage 1. Wall-clock = slowest single
  chain, not sum-of-slowest-per-stage. **This is the default for
  multi-stage work.** Each stage callback gets `(prevResult,
  originalItem, index)`.
- **`parallel(thunks)`** → runs all concurrently, **awaits all (a
  barrier)** before returning. A failing thunk resolves to `null` —
  `.filter(Boolean)` before use. Use ONLY when stage N genuinely needs
  ALL of stage N-1 (dedup/merge across the full set, early-exit on zero,
  cross-item comparison).
- **`phase(title)`** → starts a progress group. Inside
  `pipeline`/`parallel` stages, pass `opts.phase` explicitly instead to
  avoid racing the global phase state.
- **`log(msg)`** → narrator line to the user. Use it to surface what was
  dropped/capped — silent truncation reads as "covered everything."
- **`budget`** → `{ total, spent(), remaining() }`. Scale depth to a
  `+500k`-style directive; guard loops with `budget.total && ...`.
- **`workflow(name|{scriptPath}, args?)`** → run another saved workflow
  inline (one level deep).

### pipeline vs parallel — the lesson OPS already paid for

Memory lesson *parallel-subagent-serial-merge*: 3+ agents touching
shared scaffolding always conflict at merge; serialize. That lesson IS
the pipeline-vs-parallel distinction. Default to `pipeline()`. A barrier
(`parallel()` between stages) is justified ONLY by a real cross-item
dependency — dedup across the full result set, early-exit on total
count, "compare against the other findings." It is NOT justified by "I
need to flatten/map/filter first" (do that inside a stage) or "it's
cleaner." Barrier latency is real: if the slowest finder takes 3× the
fastest, a barrier wastes 2/3 of the fast finders' idle time.

## Quality patterns (compose freely)

The canonical shape — **find → verify**, pipelined so each finding
verifies the moment its review completes:

```javascript
const results = await pipeline(
  DIMENSIONS,
  d => agent(d.prompt, { label: `review:${d.key}`, phase: 'Review', schema: FINDINGS }),
  review => parallel(review.findings.map(f => () =>
    agent(`Adversarially verify, default to refuted if uncertain: ${f.title}`,
          { label: `verify:${f.file}`, phase: 'Verify', schema: VERDICT })
      .then(v => ({ ...f, verdict: v })))),
)
const confirmed = results.flat().filter(Boolean).filter(f => f.verdict?.isReal)
```

- **Adversarial verify** — N independent skeptics per finding, prompted
  to REFUTE; kill if ≥majority refute. Stops plausible-but-wrong
  findings. Give each verifier a distinct lens (correctness, security,
  reproduces?) when a finding can fail multiple ways.
- **Judge panel** — generate N independent attempts from different
  angles, score with parallel judges, synthesize from the winner.
- **Loop-until-dry** — for unknown-size discovery, keep spawning finders
  until K consecutive rounds return nothing new; dedup against a `seen`
  set, NOT against the confirmed set (else rejected findings reappear
  forever).
- **Multi-modal sweep** — agents each searching a different way
  (by-container, by-content, by-entity, by-time); one angle won't find
  everything.
- **Completeness critic** — a final agent asking "what's missing?"; its
  output is the next round of work.

## Discipline carries over (do not drop it)

A workflow is the same foreman discipline at scale. The tier changes,
the rules do not:

- **Stakes-mode briefs (P8).** Every `agent()` prompt names the real
  user + consequence, quotes doctrine by number+name, defines done in
  verifiable artifacts, bans the cheap shortcuts, grants escalation.
  **Never caveman-compress an `agent()` prompt** (P5 carve-out) — a
  compressed brief is a degraded brief.
- **Verify before trust (P3).** A workflow's returned findings are
  *claims*. The script's own verify stage is the first defense; you
  still ground-truth the headline numbers before reporting up.
- **`general-purpose` is the default agentType.** Narrow types
  (`Explore`, `cavecrew-*`) read excerpts and hallucinate on counts —
  reserve for one-shot lookups. The caveman `cavecrew-*` agents are
  token-compressed and fine as cheap *finder/reviewer* stages where you
  control the schema, but never for thorough synthesis.
- **Worktree isolation for parallel writers.** `isolation: 'worktree'`
  gives each agent its own git worktree — use it ONLY when agents mutate
  files in parallel and would conflict (it costs ~200-500ms + disk
  each). Remember the paid lessons: a worktree branches from the
  *committed* tree, so gitignored/uncommitted context (`.env`,
  `.research/`) is invisible — paste it inline in the prompt, don't cite
  the path. And the runtime spawns the worktree from the resolved repo,
  not a stale CWD.
- **No mid-run user input.** Workflows cannot call AskUserQuestion (same
  conclusion as the *no-AskUserQuestion-in-agent-mode* lesson, now a
  hard runtime constraint). For sign-off between stages, run each stage
  as its own workflow.

## Resume + iteration

Runs are resumable within the same session: completed `agent()` calls
return cached results, edited/new calls run live. The tool persists each
run's script to a file and returns the path — to iterate, Edit that file
and re-invoke with `{scriptPath, resumeFromRunId}` rather than resending
the whole script. Same script + same args → 100% cache hit.

## deep-research note

Claude Code ships a built-in `deep-research` skill / `/deep-research`
workflow (fan-out web search → cross-check each claim → cited report,
filtering claims that didn't survive cross-checking). There is no
separate OPS deep-research skill — use the built-in one for live web
research; reach for a custom workflow only when the research shape needs
something it doesn't cover.

## See also

- `02_sub_agent_patterns.md` — the manual-delegation patterns a workflow
  scales up.
- `03_quality_gates_and_audit.md` — the F6 audit pass; a workflow's
  verify stage is this, codified.
- `CONTEXT/operating-doctrine.md` P12 (orchestration tiers), P8 (stakes
  briefing), P3 (verify), P5 (caveman carve-out), P11 (foreman default).
- `CONTEXT/foreman-charter.md` — the always-injected posture summary.
