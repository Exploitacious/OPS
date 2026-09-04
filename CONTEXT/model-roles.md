# Model roles

Single source for the harness model tiers. This file is canonical. `CLAUDE.md`, `foreman-charter.md`, and the delegation skill set point here instead of restating the table, so the tiers live in one place and cannot drift between copies. Applies to both profiles.

This is policy, not a per-operator config. The model *ids* below are the harness defaults; swap them at the aliases in the Stage-1 `settings.json` if your plan carries different tiers.

## The four jobs

Four models, four jobs, and Opus 5 is banned (see below; observed usage data retired it). The distinction that matters most: the foreman tier and the worker tier are different models, and nothing is allowed to blur them.

| role | model | how it is reached |
|---|---|---|
| Primary foreman (main session) | Fable 5, `claude-fable-5[1m]`, where the plan allows it | the top-level `"model"` pin in `settings.json`; `model-probe.sh` settles it per machine |
| Fallback foreman | Opus 4.8, `claude-opus-4-8[1m]` | `/model` to the Opus entry (`ANTHROPIC_DEFAULT_OPUS_MODEL`); the pin on any machine where the Fable probe fails |
| Default build/review/audit worker | Opus 4.8, `claude-opus-4-8[1m]` | the `ops-worker` / `ops-reviewer` / `ops-auditor` agent types (hard-pinned in their frontmatter), or `model: "claude-opus-4-8[1m]"` in a Workflow lane |
| Light/routine worker | Sonnet 5, `claude-sonnet-5[1m]` | `model: "sonnet"` (the `ops-investigator` type pins it) |
| Banned | Haiku (any version), Opus 5 (`claude-opus-5`) | Haiku routes through the `ANTHROPIC_DEFAULT_HAIKU_MODEL` tripwire; Opus 5 has nothing pinning it plus a drift-gate grep, see below |

## Fable, the primary foreman where the plan carries it

Fable is the foreman because it reads context and nuance best. It follows instructions closely, holds the big picture, and orchestrates well. Availability is plan-dependent, so the main-session pin is not hand-set: `model-probe.sh` checks whether Fable can run on this machine and pins `claude-fable-5[1m]` where the probe succeeds and `claude-opus-4-8[1m]` on anything else. The charter is identical either way; nothing in the harness branches on which one answered.

Where Fable is available it is usage-capped at roughly half the subscription allowance, which makes it the scarce tier and forces thrift: Fable orchestrates only. It writes briefs, delegates, decides, and reviews worker output, all in the main thread. It does not read, build, or verify inline beyond a handful of tool calls; that work goes to workers. Never spawn Fable as a subagent: a Fable subagent burns the capped tier on work Opus 4.8 does fine, and reviewing worker output is the main thread's job. There is no `model: "fable"` worker alias wired for subagent spawns; passing one fails.

## Opus 4.8, the fallback foreman and default worker

Opus 4.8 is the primary foreman on plans without Fable and the fallback on plans with it: taken when Fable's usage is exhausted, or when the task is not complex and the decisions are already planned. Its known limitation versus Fable is weaker big-picture judgment and fewer proactive "there is a better way" suggestions; compensate with explicit written plans and mandatory review of every worker lane. It is reliable at fan-out, follow-through, and review. It is also the default build/review/audit worker, since the `ops-*` agent types pin it, so the same model backstops the foreman and does the delegated labor. Foreman switch: `/model` to the Opus entry to drop back; `/model claude-fable-5[1m]` (or restart on a plan whose pin is Fable) to return.

## Opus 5 is banned harness-wide

Opus 5 was the default worker until it was retired; observed usage data retired it. Against Opus 4.8 on identical fan-out work, Opus 5 churns roughly 6 to 7 times more cache-write per output token and many times the message round-trips. It self-checks redundantly against a harness that already runs its own review and verify lanes, runs output-token-heavy, and takes longer to reach done. Net: it burned a disproportionate share of the weekly limit for no quality edge the review workflow was not already supplying. Do not pin `claude-opus-5` in any agent frontmatter, Workflow lane, spawn override, config, doc, or script. The fanout worker tier is Opus 4.8: the `ops-worker` / `ops-reviewer` / `ops-auditor` types and the `harness-audit.js` judgment lanes pin `claude-opus-4-8[1m]` (needs the `[1m]` suffix; unlike Opus 5, 1M is not Opus 4.8's default). Enforcement mirrors the Haiku tripwire: nothing in config references `claude-opus-5`, and the drift gate greps for it (a reappearance fails the gate). Effort defaults to `xhigh`; drop it only on operator request. Do not pass alias model overrides on `ops-*` spawns, with one exception: a deliberate `model: "sonnet"` downshift for a light lane.

## Sonnet 5, the light and routine lanes

Sonnet 5 takes the light and routine lanes: investigation, mechanical edits, doc sweeps, anything where top-tier judgment is not the constraint (`ops-investigator` is pinned here). Foremen rotate Opus 4.8 and Sonnet 5 autonomously by job complexity; that call does not need the operator.

## Haiku is banned harness-wide

No Haiku model may run anywhere. `ANTHROPIC_DEFAULT_HAIKU_MODEL` stays pinned to `claude-sonnet-5` as a tripwire: anything that asks for haiku (a third-party plugin, a stray `model: "haiku"`) silently gets Sonnet 5 instead. Never reference the haiku alias in configs, docs, or scripts, and never remove that env key: removing it resurrects real Haiku 4.5.

## 1M fan-out

Both profiles run 1M-context subagents. If 1M spawns ever start failing with `API Error: Usage credits required for 1M context`, a per-account credit gate is forcing sub-agents down to <=200K; re-point the `ANTHROPIC_DEFAULT_*_MODEL` aliases at non-`[1m]` models until it lifts. The `[1m]` suffix is only load-bearing where 1M is not a model's default context (Opus 4.8), and inert where it is.

> General fallback wisdom (any model): if a top-level `"model"` pin in `settings.json` names a model that has genuinely gone unavailable, remove the key so Claude Code falls back to the `ANTHROPIC_DEFAULT_*_MODEL` aliases; do not guess a replacement. First-launch gotcha: the first boot on a newly-pinned model can reset effort to default once despite the settings pin; re-pin with `/effort xhigh` if the statusline shows a downgrade. That rule covers first boot after a model swap only: an operator-chosen `/effort` decrease mid-session is a deliberate token-saving move, never "correct" it back up; `xhigh` returns on its own at next boot via the settings default (`effortLevel: "xhigh"`).

The harness layer is model-agnostic: the launch append flag, the SessionStart matchers, and the context skills carry no per-model text and no branch forks by model, so a tier change is a settings and pin change, never a rewrite of the harness prose. To change tiers, re-point the `ANTHROPIC_DEFAULT_*_MODEL` env keys in the shared `settings.json`.
