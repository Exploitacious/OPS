# Foreman Estimation — The F7 Conversion Factor

Read this when scoping an item for the task intake "Delegation
Viability" field or estimating wall-clock for a delegated round.

Solo-engineer time estimates assume sequential single-thread
execution. The foreman pattern (F4) changes the multiplier — but
only under specific conditions. This file gives you the math.

---

## The conversion factor

**Solo estimate ÷ 5-10x = foreman estimate**

Only when all three conditions hold:

1. The work parallelizes across independent files / scopes
2. Briefs can be well-scoped (per F5)
3. The item is >1 day of solo work

If any condition fails: solo estimate stands (or partial
delegation, see "Partial viability" below).

---

## Why 5-10x and not larger

The bottleneck is brief authoring + audit pass — not delegation
count. Adding sub-agents past your throughput slows the round.
A single foreman can typically run 2-3 sub-agents per parallel
round; rounds chain serially.

Wall-clock math:

- Brief authoring: 10-30 min per sub-agent (template-shareable
  for registry-driven; per-item for heavy-build)
- Sub-agent execution: 20-180 min depending on pattern
- Audit pass: 5-30 min per round

Parallel rounds with 2-3 sub-agents = ~1-3h wall-clock for what
would be 5-15h solo. That's the 5x at minimum, sometimes 10x
on highly parallel work.

10x is the realistic ceiling for the typical foreman. Beyond 10x,
you are bottlenecked on briefs.

---

## When delegation does NOT pay off

**Sub-day work (< ~6 hours solo).** Setup overhead kills the
conversion:

- Brief authoring: 20 min minimum for a useful brief
- Worktree creation + sub-agent boot: 2-5 min
- Audit pass: 10 min minimum
- Total overhead: 30+ min per sub-agent

If solo work is 2h, overhead alone is 30+ min — net saving is
under 50%, often negative once you factor in coordination cost.

**Solo or single surgical sub-agent is faster.**

**Tightly sequential work.** If step 2 depends on step 1's
output, you cannot parallelize. Delegation here means one
sub-agent doing all steps — no fan-out benefit. Solo is
equivalent in time and lower in overhead.

**Single-threaded synthesis.** Work that needs one mind thinking
through the problem (architectural design, debugging unknown-cause
failures, novel research) does not benefit from delegation. One
sub-agent fully briefed = one mind. The sub-agent is not faster
than you on this work; they just isolate the context.

---

## Worked examples

### Example 1 — Highly delegatable (10x)

**Task:** "Generate KB articles for all 30 signals in the
registry."

- Solo estimate: 30 articles × 30 min each = 15 hours
- Conditions: parallel ✓, briefable ✓, >1 day ✓
- Pattern: registry-driven content generation
- Rounds: 3 rounds of 10 sub-agents in parallel (or 5 rounds of
  6, depending on coordination capacity)
- Per round: 20 min brief (template once + per-item params) +
  ~30 min sub-agent work + 25 min audit = ~75 min
- Total: 3 × 75 min = 3.75h
- **Conversion factor: 15h / 3.75h = 4x**

Why not 10x? The brief authoring + audit don't fully amortize
when you're chaining rounds. Per-item parameter injection still
takes time. 4-5x is realistic for registry-driven at this scale.

### Example 2 — Moderate delegation (3-5x)

**Task:** "Refactor signal-history retention to add env-var
override, plus 4 follow-on changes."

- Solo estimate: 8h
- Conditions: parallel (✓ for the 4 follow-ons), briefable ✓,
  >1 day ✓
- Pattern: heavy-build for main change + surgical-pack for
  follow-ons
- Round 1 (heavy-build): 30 min brief + 90 min sub-agent + 20
  min audit = ~140 min
- Round 2 (surgical-pack): 15 min brief + 30 min sub-agent + 10
  min audit = ~55 min
- Total: ~195 min = ~3.25h
- **Conversion factor: 8h / 3.25h = 2.5x**

Conservative because the two rounds are sequential (round 2
depends on round 1 shipping first). Pure parallel would be
4-5x.

### Example 3 — Not delegatable

**Task:** "Fix a single test that's been flaking."

- Solo estimate: 30 min - 2h (unknown cause)
- Conditions: parallel ✗ (single test), briefable ✗ (unknown
  cause), >1 day ✗
- Pattern: reviewer-fix or solo
- **Don't delegate.** Brief authoring alone is half the work.

### Example 4 — Partial viability

**Task:** "Add metrics dashboards for all 5 trading instruments."

- Solo estimate: 12h
- Sub-tasks:
  - Define metric schema (1.5h) — single-threaded synthesis
  - Implement metric collectors (2h × 5 = 10h) — parallel ✓
  - Wire dashboards (0.5h × 5 = 2.5h) — parallel ✓
- Strategy: solo round 1 (schema), heavy-build round 2 (1
  sub-agent per collector, 5 in parallel), surgical-pack round
  3 (one sub-agent for all 5 dashboard wirings)
- Round 1: 1.5h solo
- Round 2: 30 min brief + 60 min sub-agents in parallel + 20
  min audit = ~110 min
- Round 3: 20 min brief + 30 min sub-agent + 10 min audit = 60 min
- Total: ~3.6h
- **Conversion factor: 12h / 3.6h = 3.3x on the delegated portion,
  ~3x on the whole task**

Partial viability is the most common real-world case. Mark
"Partial" in task intake and name which sub-tasks delegate.

---

## Quantify in deliverables, not hours

Hours imply sequential single-thread work. Deliverable counts
scale with delegation.

Replace:

> "Estimated time: half a day"

With:

> "Deliverables: 5 KB articles + 1 generator + 8 tests + 2 lints.
> Solo estimate: 6h. Foreman estimate: ~2h via registry-driven
> + surgical-pack."

The deliverable count is what scales. Hours are derived.

---

## Brief-time budget

Brief authoring should be <20% of total sub-agent time. If your
brief takes 30 min and the sub-agent will work for 30 min, you
are in reviewer-fix territory — do it yourself.

| Sub-agent pattern | Sub-agent work time | Max brief time |
|-------------------|---------------------|----------------|
| reviewer-fix | n/a | n/a (foreman does it) |
| surgical-pack | 15-30 min | 5-10 min |
| parallel-research | 20-40 min | 5-10 min |
| registry-driven | 20-40 min × N | 10-20 min template + 2 min/item |
| heavy-build | 60-180 min | 20-30 min |

If you find yourself over-budget on a brief, the sub-agent's
scope is too small for the pattern. Consider:

- Switching to reviewer-fix (you do it)
- Combining multiple items into one heavier brief
- Spawning a parallel-research round first to clarify scope, then
  re-brief

---

## Right-size the brief (scope it tight; 1M is headroom, not a target)

Brief-time budget (above) bounds how long you spend *writing* a brief.
This bounds how much you ask the worker to *hold*. Different ceilings;
both bind.

**Workers run at up to 1M on both profiles** — Sonnet 5 1M is the default
worker as of 2026-06-30; the Personal credit gate that used to force ≤200K
fan-out no longer fires (platform change — see linuxploitacious `CLAUDE.md`
§ "Subagent model tiers"). But a bigger window is not a license to dump:
bigger context is not better work, and Sonnet-1M's price premium only applies
past 200K input. Scope every brief as tightly as the task allows — most lanes
should still fit well under 200K and stay there.

Budget every brief:

- **Reserve the fixed overhead.** Every spawn reloads the full system
  prompt + all active MCP tool schemas before it reads a thing — tens of K
  of tokens gone before your brief lands.
- **Count the reading the brief demands.** Instructions + every file the
  worker must open + the diff/output it must produce all share one window. A
  vague "review these 300 files" brief fails even at 1M: the worker skims,
  runs past what it can hold in focus, and fabricates specifics for the rest
  — the narrow-read failure that bans `Explore` for thorough work (see
  SKILL.md anti-patterns). Silent data loss, not a slow worker.
- **The lever is decomposition: more, smaller, sharply-scoped sub-agents** —
  for focus and cost, not a hard cap. Split before you spawn — two workers
  over 150 files each, a registry-driven loop one item per agent, a
  parallel-research round to map a surface before a heavy build touches it.
- **Reserve the 1M headroom for lanes that genuinely need it** — a large
  codebase slice, a long document. Hand those the Sonnet-1M (default) or, for
  hard judgment, Opus-1M worker *deliberately*; don't lean on 1M to rescue a
  lazy brief.
- **The foreman scopes each worker like itself.** Right-sizing the chunk is a
  foreman responsibility, not the worker's to discover mid-task.

Model choice (`haiku` = Sonnet-5 200K trivial / `sonnet` = Sonnet-5 1M default
/ `opus` = Opus-4.8 1M hard) is about reasoning depth + cost (F7 / P12
model-tiering). Same tiers on both profiles.

Depth + the "why": `operating-doctrine.md` P12 (orchestration tiers,
right-size-the-brief bullet) + `CONTEXT/foreman-charter.md`.

---

## Task intake "Delegation Viability" field

Apply the conversion factor when scoping work for the task intake
format (see working-preferences.md).

```
Task: [name]
Estimated Length of Time (solo): [solo estimate]
Delegation Viability: Yes / No / Partial
  - Pattern: [parallel-research / registry-driven / surgical-pack /
    heavy-build / reviewer-fix / mixed / N-A]
  - Foreman estimate: [solo ÷ 5-10x, or N-A if sub-day]
```

Decision rules:

- **Yes** if all three F7 conditions hold (parallel + briefable +
  >1 day)
- **No** if any condition fails materially
- **Partial** if some sub-tasks delegate and others don't —
  name which

When in doubt, mark Partial. Pure Yes is rare; pure No on
multi-day work is unusual once you compose patterns.

---

## What this is not

This is not a tool for inflating estimates to look impressive.
"This 1-day task is now 2 hours via foreman pattern" is only true
when the conditions hold. If they don't, the math is solo.

Honest delegation accounting beats inflated promises. Operator
catches both, and inflation costs trust.
