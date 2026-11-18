# Model roles

Single source for the harness model tiers. This file is canonical. [Core: Models](core.md#models), [foreman: Model choice](foreman.md#model-choice), and the delegation skill set point here instead of restating the table, so the tiers live in one place and cannot drift between copies. Applies to both profiles. History lives in `CHANGELOG.md`, not here.

This is policy, not a per-operator config. The model *ids* below are the ones the Stage-1 `settings.json` (linuxploitacious) pins today. If your plan carries different tiers, see "Settings, pins, and the shared Stage-1 file" below before you change anything: that file is shared, and editing it in place has side effects.

Catalog facts checked 2026-11-09 against Anthropic's [model overview](https://platform.claude.com/docs/en/models/overview), [pricing](https://platform.claude.com/docs/en/about-claude/pricing), and [Opus 5.5 API changes](https://platform.claude.com/docs/en/models/opus-5-5/whats-new-opus-5-5). These are API list rates and defaults; subscription usage and Claude Code defaults can differ. Recheck these sources before a price or API behavior drives a new decision.

## Tiers

| Role | Model | Id | How it is reached |
|---|---|---|---|
| Foreman (main session) | Opus 5.5 | `claude-opus-5-5[1m]` | the top-level `"model"` pin in the Stage-1 `settings.json`; also `ANTHROPIC_DEFAULT_OPUS_MODEL` (`/model opus`, `model: "opus"`) |
| Default lane: builds, fixes, docs, research, recon, refutation, mechanical work | Sonnet 5.5 | `claude-sonnet-5-5[1m]` | `CLAUDE_CODE_SUBAGENT_MODEL` in the Stage-1 `env` (every spawn or workflow `agent()` that names no model); `ANTHROPIC_DEFAULT_SONNET_MODEL` (`model: "sonnet"`); the `ops-worker` and `ops-auditor` pins (full id) and `ops-investigator` (`model: sonnet`) |
| High-criticality build lane | Opus 5.5 | `claude-opus-5-5[1m]` | `model: "opus"` on a spawn, with the reason stated in the brief; the judgment lanes of `harness-audit.js` pin the full id |
| Cheap reading | Haiku 5.5 | `claude-haiku-5-5` (the exact id) | `ANTHROPIC_DEFAULT_HAIKU_MODEL` in the Stage-1 `env` (the haiku alias and Claude Code's background requests); `model: 'claude-haiku-5-5'` named on a workflow stage; never the bare `haiku` alias |
| Consult, the second mind (optional) | Fable 5.2 | `claude-fable-5-2` | Agent tool `model: "fable"` (the alias resolves to `claude-fable-5-2`); `delegate_task` with that id and an effort option for a consult that needs its own thread; see [Fable 5.2, the second mind](#fable-52-the-second-mind) |
| Retired | Sonnet 5; Opus 4.8 | `claude-sonnet-5`; `claude-opus-4-8` | pinned nowhere; `verify-ops.sh` check 15b fails on a live pin |
| Banned | Opus 5; every Haiku except 5.5 | `claude-opus-5` (the exact id); every haiku id except `claude-haiku-5-5` | see Bans |

Sonnet 5.5 is the default lane, refutation lanes included: spawn on it without asking and leave `model` unset, because the `CLAUDE_CODE_SUBAGENT_MODEL` env default already makes an unpinned spawn Sonnet. Upshift to Opus 5.5 only for a high-criticality build, and say why in the brief. The test is "Sonnet is likely to get this wrong", not "this is important". Why Sonnet by default: it holds quality on ordinary lane work at half Opus 5.5's list price, and a lane that inherits the foreman's model instead silently doubles what most of the work costs.

## Opus 5.5, the foreman and high-stakes lane

Opus 5.5 is the foreman (the `"model"` pin) and the lane for work where Sonnet is likely to get it wrong: guards and deploy code, secrets and auth logic, subtle concurrency or state-machine logic, novel design, a second attempt after a Sonnet lane stalled or got it wrong, and refuting a high-criticality claim set. Refutation otherwise runs on the Sonnet 5.5 `ops-auditor`; a spawn passes `model: "opus"` only for such a set, with the reason in the brief. Opus 5.5 is also the review for code where a miss is expensive when no second vendor's model is available: an Opus refutation lane plus the Operator's own read (`how-i-work.md`, Review pickup). With a second vendor, that code goes there instead; no Claude lane is that review. Its known weakness is big-picture judgment and fewer unprompted "there is a better way" suggestions; compensate with explicit written plans and the foreman's verification of every returned lane. It lists at $4 / $20 per MTok (cache reads $0.20) with a 1M window and 128K output, twice Sonnet 5.5's price.

API behavior that touches the harness:

- Its effort default is `medium`, so the saved per-model `high` level (see Effort) is what keeps it at the harness default.
- Thinking cannot be disabled; the CLI never tries to.
- Forced `tool_choice` (`any` or `tool`) returns a 400. Claude Code's structured output does not depend on it; a script of yours that calls the API directly must use `auto` and say which tool to call.
- Thinking blocks are bound to the model and conversation that produced them; the CLI handles that binding.

## Context windows

Opus 5.5, Sonnet 5.5, and Fable 5.2 run with a 1M-token window; the 4.6-era ids reach 1M only through their `[1m]` variants. Haiku 5.5 has a native 1M window, but every rate is 5x once a request passes 100K tokens, so the harness holds it under 100K: the Stage-1 settings give `claude-haiku-5-5` a 100K auto-compaction window. The context-watch hook sizes each sub-agent lane from its own model on this basis (a reminder at 60% and a wrap-up at 80% of a 1M window, one backstop at 95K for Haiku 5.5); its `LANE_WINDOWS` table is the per-id record, and a new model id gets a row there before a lane runs on it.

## Sonnet 5.5, the workhorse

Sonnet 5.5 is the default lane for builds, fixes, docs, research, recon, migrations, mechanical work, and refutation. It has a 1M window and 128K max output and lists at $2 / $10 per MTok. Claude Code learned the `claude-sonnet-5-5` id in 2.1.284; an older build runs it as an unknown model with a 200K window, so update Claude Code on a host before relying on the pin. Its effort default on the [Claude API](https://platform.claude.com/docs/en/models/sonnet-5-5/overview) is `high` (Claude Code defaults to `medium`), so the saved `high` level stays explicit.

Overturn condition (P14). The constraint is the shared usage window, and this default bets that Sonnet 5.5 holds quality on ordinary lane work at half Opus 5.5's list price. Two readings would falsify it: churn, meaning Sonnet 5.5 lanes write more cache per output token than Opus 5.5 lanes on comparable work (the reading that got Opus 5 banned); and rework, meaning lanes the foreman must respawn on Opus 5.5 after verification fails, against all Sonnet 5.5 lanes of the same week. Read churn with `.claude-config/bin/transcript-usage.py --since <ISO time> ~/.claude/projects` (lane rows: `ccr` against `out`, with the `models` column naming the model); rework is the foreman's own count of respawns, since no tool records it. A reasonable line: churn above Opus 5.5's, or more than one lane in four respawned on Opus. If either holds, bring the Operator the figures with a recommendation. New input that reopens the question: a cheaper model that clears the same bar, or a price change on any tier.

## Haiku 5.5, cheap reading

Haiku 5.5 is for cheap, bounded reading: searches, summaries, digging through tedious material, a workflow stage whose input you can size. Keep its lanes under 100K tokens of context: the Stage-1 settings give `claude-haiku-5-5` a 100K auto-compaction window (`modelSettings`), so a Haiku lane compacts on its own before it reaches the long-context price, and its brief should still size the input to fit, because each compaction drops detail. Pins name the full id. The bare `haiku` alias resolves to Haiku 5.5 only while the Stage-1 `ANTHROPIC_DEFAULT_HAIKU_MODEL` pin is live and on Claude Code 2.1.293 or later; elsewhere it resolves to Haiku 4.5, which is banned. Never remove that env key: without it, the haiku alias and Claude Code's background requests (session titles, fetch summaries) fall back to Haiku 4.5.

Price and the 100K step. For a prompt up to 100K tokens Haiku 5.5 lists at $0.10 in and $0.50 out per MTok; past 100K every rate is five times that. A request's prompt length counts all of its input tokens, cache reads and writes included, and each request is priced on its own. Even past the step its input and output rates are a quarter of Sonnet 5.5's, so the 100K ceiling is a further saving, not a break-even line.

Where it runs:

- Background requests, through the pin. The haiku alias and Claude Code's small background requests (session titles, WebFetch page summaries) run on it. No code is involved, and these requests are small.
- Workflow stages that locate, count, extract named facts, answer explicit questions over two or three named documents, or classify into a closed label set whose definitions are in the brief, plus digests for the foreman's own use that keep the source's reason for each point. Name `model: 'claude-haiku-5-5'` on the stage (check 15b refuses the bare alias) and size the input so the stage stays under 100K tokens with its boot. The pattern that fits: a Haiku stage gathers quoted evidence, and a Sonnet or Opus stage decides on it.

Measured, not assumed: a blind comparison in the harness OPS is ported from (tasks with independently checked answers, judged without model names) found Haiku 5.5 level with Sonnet 5.5 on locate, count, and fact extraction, with no fabrications, at about a twelfth of the cost. Its summaries dropped reasons more often, and one of its code-behavior answers inverted a rule, so summaries that are the deliverable or carry reasons into a decision, and code-behavior answers that gate a change, stay on Sonnet.

Never on Haiku: builds, refutation, review, security triage, or other judgment-heavy work. It has no server-side refusal fallback, so a declined Haiku lane simply fails.

How the 100K ceiling holds. Claude Code's own auto-compaction holds it, so a Haiku lane never has to watch its context. The Stage-1 settings turn auto-compaction on harness-wide (`autoCompactEnabled: true` and `DISABLE_AUTO_COMPACT` set to `"0"`; both switches are process-wide, and either one closed stops every compaction) and pin `modelSettings: {"claude-haiku-5-5": {"autoCompactWindow": 100000}}`. The env switch is `"0"` rather than absent because a removed key leaves an old `"1"` in force: a running session keeps it through a settings reload, and a `claude` started from that session inherits it. Opus and Sonnet keep their 1M window; for them auto-compaction near the end of the window is a backstop, and manual compaction at natural breaks stays the norm (`session-end pause`, the `harness` skill). Stage-1 also sets `idleCompaction: false`, so an idle main thread is never compacted early.

What would break it: `CLAUDE_CODE_AUTO_COMPACT_WINDOW` outranks every per-model window; `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` lowers every model's threshold; a removed `DISABLE_AUTO_COMPACT` leaves an inherited `"1"` in force; Claude Code drops a malformed per-model value without a word, and `claude doctor` does not flag it; `/autocompact` saves a window for the current model into the user settings file, which on a linuxploitacious host is the shared Stage-1 file; and a top-level `autoCompactWindow` in a higher-precedence settings file (`settings.local.json`, managed settings) replaces the per-model windows of lower files. No OPS check reads these keys today, so when a Haiku lane runs past 100K, read them in that order.

Effort. The Stage-1 settings save `high` for `claude-haiku-5-5`, so a Haiku lane runs at `high` unless its agent frontmatter or the spawn sets another level. That spends more tokens than its default (`medium`), which fills the 100K ceiling sooner.

Overturn condition (P14). The constraint is Haiku's accuracy on retrieval and summaries against its price. A same-brief comparison in which Haiku misses or fabricates more than Sonnet on the same lookups would falsify a placement; a price change on either tier reopens it.

## Fable 5.2, the second mind

Fable 5.2 (`claude-fable-5-2`) is the consult: a second mind beside the Opus 5.5 foreman, called at set moments, never a reviewer and never a volume worker. Opus is meticulous and misses little, but it rarely challenges the premise it was handed, and its options cluster. Fable has range: the premise, a structural shortcut, a real spread of options. Work that can be hill-climbed to a check is Opus work; work judged by taste, premise, or a spread of options is consult work. Its answer is advice the foreman verifies before acting on it or reporting it (P3).

Call it at three moments, without asking, and name which in the brief:

1. Before: a multi-lane build plan or a new system, ahead of its plan review (routine fixes skip both); options going to the Operator on a design decision; a visual or UX direction the Operator will judge by eye, before it is built.
2. After a miss: a problem that beat Opus once (a fix that did not hold, evidence against the answer, or two answers that disagree); a third review round coming on one workstream; or an item carried "not done" across two rest stops. The question is why it keeps happening and whether the shape is wrong (split, cut, restart smaller). Send the attempt and the evidence, not a fresh start; an error a retry fixes is an ordinary obstacle, not a miss.
3. Security: a security design before it is built, or a high-stakes conclusion ("safe to expose", "contained") as a refutation with numbered claims.

Elsewhere, call it when the open question is which shape, and no check can settle it.

How to call it: the Agent tool with `model: "fable"` (it runs at Fable's saved `medium`; pass the tool's `effort` when the question needs more), or `delegate_task` with model `claude-fable-5-2` and the effort option in the call for a consult that needs its own thread. Word the brief as a challenge ("what is wrong with the premise of the plan at <path>"), never "review this" or "is it safe to merge". Give it the Operator's own words for the ask, one question, the evidence paths (a cheaper lane gathers them first), and a capped return: the recommendation, what would falsify it, and what would reopen it.

What does not move: a consult challenges plans and refutes conclusions; it never reviews a code change and never stands in for the second-vendor review or a refutation lane. No volume work (build lanes, bulk reading, fan-out); a small patch that is the finding comes back as a diff the foreman lands.

Cost. Fable lists at $8 / $40 per MTok, twice Opus 5.5, on the same shared usage windows, and each lane carries about 30K tokens of fixed overhead (system prompt and tool schemas), so give it one substantive question and a complete brief. A single consult needs no usage check; volume work on Fable has drained whole usage windows and stays out. Where a seat also offers Mythos 5.2 (`claude-mythos-5-2`), it can take the same role at the same settings.

Nobody is required to have Fable: not every account or seat includes it, and a copy that lacks it skips the consult and loses nothing the harness needs, because Opus 5.5 takes that work.

## Bans

Opus 5 (`claude-opus-5`, the exact id) is banned harness-wide. As a fan-out worker it churned roughly 6 to 7 times more cache-write per output token than the worker tier it replaced, with many times the message round-trips, self-checking redundantly against a harness that already runs its own review and verify lanes, and burned a disproportionate share of the weekly limit for no quality edge. Do not pin it in any agent frontmatter, Workflow lane, spawn override, config, doc, or script. `verify-ops.sh` check 15 matches the exact id at its boundary (`claude-opus-5` followed by `[1m]`, a quote, whitespace, or end of line), so the allowed `claude-opus-5-5` pins do not trip it; anchor any new grep the same way, because the bare prefix matches the new id.

Every Haiku except Haiku 5.5 is banned: Haiku 4.5 in any form (dated, Bedrock or Vertex naming), the older `claude-3-5-haiku-*` naming, a dated 5.5 snapshot, and any later Haiku until the policy names it. Only the exact id `claude-haiku-5-5` is allowed. `verify-ops.sh` check 15b fails when the `ANTHROPIC_DEFAULT_HAIKU_MODEL` pin is anything but exactly `claude-haiku-5-5`, and when another Haiku id, or the bare `haiku` alias as a value, appears in an agent definition, a workflow script (`SKILLS/**/*.js` included), a command, or a Claude settings file. In those files, name a banned Haiku in words ("Haiku 4.5"), never by id.

Sonnet 5 and Opus 4.8 are retired, not banned: nothing may pin them, because a retired id left in a pin keeps lanes quietly running the retired model. Check 15b fails on a live pin in agent frontmatter, workflow lanes, and the Claude settings files, matching each id at its end so that `claude-sonnet-5-5` does not trip `claude-sonnet-5`. It does not scan prose. One platform exception: Claude Code's safety-refusal fallback (`switchModelsOnFlag` in the Stage-1 settings) can move a refused turn to an older model on its own; no pin of ours chooses it. Fable 5.2 widens it: Anthropic answers a blocked Fable request with Opus 4.8 for cyber topics and with Opus 5, the banned id, for biology and a small set of AI-development topics (the Fable 5.2 launch page, 2026-11-09). Both reroutes stay platform behavior, and the Stop hook `model-fallback-watch.sh` flags every one, so the agent tells the Operator which work ran on the fallback model (`.claude-config/bin/README.md`); word a Fable consult on a security question neutrally (the engineering question restated honestly, never the work hidden or altered), which narrows them.

## Effort

Effort defaults to `high` on Opus 5.5, Sonnet 5.5, and Haiku 5.5 and to `medium` on Fable 5.2 (and Mythos 5.2 where a seat has it). `max` is never used on a Claude model. The levels are defaults, not caps: the foreman sets a thread's or lane's effort, `low` to `xhigh`, when the work needs it (the Agent tool's `effort` on a native lane, the effort option in a `delegate_task` call, T3's picker for a thread it starts), and says why in the brief. A hard design, a security read, or a second attempt is the usual reason to raise it; mechanical volume work is the reason to lower it. An effort decrease is also the Operator's token-saving lever: honor a `/effort` drop, never auto-restore it mid-session, and never autonomously downgrade a review or verify lane.

How the levels are held. The Stage-1 `settings.json` saves one level per model under `modelSettings` and sets no effort variable, because `CLAUDE_CODE_EFFORT_LEVEL` outranks every pick, T3's picker included: the backend sets defaults and never overrides a choice. Claude Code resolves effort in this order (measured on 2.1.322 by reading the level each run sends): the `CLAUDE_CODE_EFFORT_LEVEL` variable, a level picked in the session, `--effort` at launch, the saved per-model level, then the model's own default, which is `medium` for these models. A top-level `effortLevel` in the user file is ignored by them, and a saved `max` or a misspelled level falls to `medium` without a warning.

What follows from the order:

- T3 passes `--effort` on every launch from the thread's selection, so T3's picker decides a thread's effort; a selection with no effort option becomes T3's own default.
- A `delegate_task` child on its parent's model inherits the parent's effort. A child that names a different model gets T3's default unless the call passes the effort option, so always pass it.
- A native lane that names a different model than its parent runs at that model's saved level: `model: "fable"` under an Opus foreman runs at `medium`, and a lane that names no model runs on Sonnet 5.5 at `high`. A lane on its parent's own model inherits the parent's level. An agent's `effort` frontmatter overrides both, and the Agent tool's `effort` on the spawn overrides all three.
- A Stage-1 checkout from before 2026-11-16 still carries the old `xhigh` variable and pins until that checkout is updated; a template sync does not touch it.

First-launch gotcha: the first boot on a newly pinned model can reset effort to the model default once despite the saved level; re-pin with `/effort` to the saved level only for that unintended reset, never for the Operator's deliberate change.

## Settings, pins, and the shared Stage-1 file

- The top-level `"model"` pin in `settings.json` is what boots. On Linux and macOS, `~/.claude/settings.json` is a symlink into your linuxploitacious checkout (`~/linuxploitacious/claude/.claude/settings.json`), shared by every profile on the host. A `/model` or `/config` save writes that tracked file: it leaves a diff in the checkout, and a later `git pull --ff-only` that touches the file fails until you resolve it. Nothing in OPS writes that file; deploy and the drift gate only read it.
- To change tiers on your own copy, change the `ANTHROPIC_DEFAULT_*_MODEL` and `CLAUDE_CODE_SUBAGENT_MODEL` env keys and the `"model"` pin together, in a fork of linuxploitacious or in managed settings, so a later Stage-1 pull does not undo or conflict with it. The harness layer is model-agnostic: the SessionStart matchers and the skills carry no per-model text, so a tier change is a settings and pin change plus this file, never a rewrite of the harness prose.
- Pins are the owner's. Deploy and the template sync never edit a copy's `"model"` pin, its env keys, or an agent pin the owner changed. The drift gate FAILs on a retired or banned id, edits nothing, and says how to fix it (the stated exception in `how-i-work.md`, "The template and a copy's owner"). An administrator who wants every box on the current tiers can set them through managed settings (`/etc/claude-code/managed-settings.json` on Linux), which outrank the user's own settings without editing the user's files. Offer that route; do not impose it on a copy whose owner chose a different pin, and never require a tier the owner's plan lacks (Fable above all).
- To check that the models your settings pin answer on your plan, run `.claude-config/bin/model-probe.sh` (one short request per distinct id; `--list` shows what it would probe without calling the API). It reports only; it never edits a settings file.
- If a pinned model has genuinely gone unavailable, remove the `"model"` key so Claude Code falls back to the `ANTHROPIC_DEFAULT_*_MODEL` aliases; do not guess a replacement.
- T3 Code pickers. List `claude-opus-5-5` and `claude-sonnet-5-5` under `providerInstances.<instance>.config.customModels` in `~/.t3/userdata/settings.json` (a plain list of id strings, hot-reloaded), so the live tiers stay pickable whatever T3's built-in catalog lists; T3 appends `[1m]` itself when the thread's 1M option is on. Haiku 5.5 is allowed and already in the built-in list, so it needs no entry. Hide the banned and retired ids per instance (`providerModelPreferences.<instanceId>.hiddenModels`, set in the T3 UI and kept by the server in the same file since T3 0.1.0). The picker never hides a custom model, so never add a banned or retired id to `customModels`.
- 1M fan-out works on both profiles. If 1M spawns ever start failing with `API Error: Usage credits required for 1M context`, a per-account credit gate is forcing subagents down to 200K or less; re-point the aliases at non-`[1m]` ids until it lifts.
