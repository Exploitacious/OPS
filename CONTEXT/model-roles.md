# Model roles

Single source for the harness model tiers. This file is canonical. `CLAUDE.md`, `foreman-charter.md`, and the delegation skill set point here instead of restating the table, so the tiers live in one place and cannot drift between copies. Applies to both profiles. History lives in `CHANGELOG.md`, not here.

This is policy, not a per-operator config. The model *ids* below are the ones the Stage-1 `settings.json` (linuxploitacious) pins today. If your plan carries different tiers, see "Settings, pins, and the shared Stage-1 file" below before you change anything: that file is shared, and editing it in place has side effects.

## Tiers

| Role | Model | Id | How it is reached |
|---|---|---|---|
| Foreman (main session) | Opus 5.5 | `claude-opus-5-5[1m]` | the top-level `"model"` pin in the Stage-1 `settings.json`; also `ANTHROPIC_DEFAULT_OPUS_MODEL` (`/model opus`, `model: "opus"`) |
| Default lane: builds, fixes, docs, research, recon, refutation, mechanical work | Sonnet 5.5 | `claude-sonnet-5-5[1m]` | `CLAUDE_CODE_SUBAGENT_MODEL` in the Stage-1 `env` (every spawn or workflow `agent()` that names no model); `ANTHROPIC_DEFAULT_SONNET_MODEL` (`model: "sonnet"`); the `ops-worker`, `ops-reviewer`, and `ops-auditor` pins (full id) and `ops-investigator` (`model: sonnet`) |
| High-criticality build lane | Opus 5.5 | `claude-opus-5-5[1m]` | `model: "opus"` on a spawn, with the reason stated in the brief; the judgment lanes of `harness-audit.js` pin the full id |
| Cheap reading | Haiku 5.5 | `claude-haiku-5-5` (the exact id) | `ANTHROPIC_DEFAULT_HAIKU_MODEL` in the Stage-1 `env` (the haiku alias and Claude Code's background requests); `model: 'claude-haiku-5-5'` named on a workflow stage; never the bare `haiku` alias |
| Rare | Fable 5.1 | `claude-fable-5-1` | Agent tool `model: "fable"`; `/model claude-fable-5-1[1m]` for a session that needs it at the top |
| Retired | Sonnet 5; Opus 4.8 | `claude-sonnet-5`; `claude-opus-4-8` | pinned nowhere; `verify-ops.sh` check 15b fails on a live pin |
| Banned | Opus 5; every Haiku except 5.5 | `claude-opus-5` (the exact id); every haiku id except `claude-haiku-5-5` | see Bans |

Sonnet 5.5 is the default lane, refutation lanes included: spawn on it without asking and leave `model` unset, because the `CLAUDE_CODE_SUBAGENT_MODEL` env default already makes an unpinned spawn Sonnet. Upshift to Opus 5.5 only for a high-criticality build, and say why in the brief. The test is "Sonnet is likely to get this wrong", not "this is important". Why Sonnet by default: it holds quality on ordinary lane work at half Opus 5.5's list price, and a lane that inherits the foreman's model instead silently doubles what most of the work costs.

## Opus 5.5, the foreman and high-stakes lane

Opus 5.5 is the foreman (the `"model"` pin) and the lane for work where Sonnet is likely to get it wrong: guards and deploy code, secrets and auth logic, subtle concurrency or state-machine logic, novel design, a second attempt after a Sonnet lane stalled or got it wrong, and refuting a high-stakes claim. Its known weakness is big-picture judgment and fewer unprompted "there is a better way" suggestions; compensate with explicit written plans and the foreman's verification of every returned lane. Its API effort default is `medium`, so the explicit `xhigh` pin (see Effort) is what keeps it at the harness default.

## Sonnet 5.5, the workhorse

Sonnet 5.5 is the default lane for builds, fixes, docs, research, recon, migrations, mechanical work, and refutation. Claude Code learned the `claude-sonnet-5-5` id in 2.1.284; an older build runs it as an unknown model with a 200K window, so update Claude Code on a host before relying on the pin. Like Opus 5.5, its effort default is `medium`, so the `xhigh` pin stays explicit.

## Haiku 5.5, cheap reading

Haiku 5.5 is for cheap, bounded reading: searches, summaries, digging through tedious material, a workflow stage whose input you can size. Keep its lanes under 100K tokens of context: the Stage-1 settings give `claude-haiku-5-5` a 100K auto-compaction window (`modelSettings`), so a Haiku lane compacts on its own before it reaches the long-context price, and its brief should still size the input to fit, because each compaction drops detail. Pins name the full id. The bare `haiku` alias resolves to Haiku 5.5 only while the Stage-1 `ANTHROPIC_DEFAULT_HAIKU_MODEL` pin is live and on Claude Code 2.1.293 or later; elsewhere it resolves to Haiku 4.5, which is banned. Never remove that env key: without it, the haiku alias and Claude Code's background requests (session titles, fetch summaries) fall back to Haiku 4.5.

## Fable 5.1, rare

Spawn Fable only for deep, high-impact design or infrastructure planning and for some front-end work. It lists at 2.5 times Opus 5.5's price and spends the shared usage window several times faster per token, and each lane carries a fixed overhead of system prompt and tool schemas, so give it substantive work and a complete brief. The cases that once justified a top-tier lane (concurrency, security, guards and deploy code, a second attempt) go to Opus 5.5. A code review is never a Fable lane.

## Bans

Opus 5 (`claude-opus-5`, the exact id) is banned harness-wide. As a fan-out worker it churned roughly 6 to 7 times more cache-write per output token than the worker tier it replaced, with many times the message round-trips, self-checking redundantly against a harness that already runs its own review and verify lanes, and burned a disproportionate share of the weekly limit for no quality edge. Do not pin it in any agent frontmatter, Workflow lane, spawn override, config, doc, or script. `verify-ops.sh` check 15 matches the exact id at its boundary (`claude-opus-5` followed by `[1m]`, a quote, whitespace, or end of line), so the allowed `claude-opus-5-5` pins do not trip it; anchor any new grep the same way, because the bare prefix matches the new id.

Every Haiku except Haiku 5.5 is banned: Haiku 4.5 in any form (dated, Bedrock or Vertex naming), the older `claude-3-5-haiku-*` naming, a dated 5.5 snapshot, and any later Haiku until the policy names it. Only the exact id `claude-haiku-5-5` is allowed. `verify-ops.sh` check 15b fails when the `ANTHROPIC_DEFAULT_HAIKU_MODEL` pin is anything but exactly `claude-haiku-5-5`, and when another Haiku id, or the bare `haiku` alias as a value, appears in an agent definition, a workflow script (`SKILLS/**/*.js` included), a command, or a Claude settings file. In those files, name a banned Haiku in words ("Haiku 4.5"), never by id.

Sonnet 5 and Opus 4.8 are retired, not banned: nothing may pin them, because a retired id left in a pin keeps lanes quietly running the retired model. Check 15b fails on a live pin in agent frontmatter, workflow lanes, and the Claude settings files, matching each id at its end so that `claude-sonnet-5-5` does not trip `claude-sonnet-5`. It does not scan prose. One platform exception: Claude Code's safety-refusal fallback (`switchModelsOnFlag` in the Stage-1 settings) can move a refused turn to an older model on its own; no pin of ours chooses it.

## Effort

Effort is `xhigh` on every tier, Haiku 5.5 included (`effortLevel` and `CLAUDE_CODE_EFFORT_LEVEL` in the Stage-1 settings). The 5.5 models default to `medium` without that pin, so it must stay explicit. `max` is not used on a Claude model. An effort decrease is the Operator's token-saving lever: honor a `/effort` drop, never auto-restore it mid-session, and never autonomously downgrade a lane (least of all a review or verify lane). First-launch gotcha: the first boot on a newly pinned model can reset effort to default once despite the settings pin; re-pin with `/effort xhigh` only for that unintended reset. `xhigh` returns on its own at the next boot via the settings default.

## Settings, pins, and the shared Stage-1 file

- The top-level `"model"` pin in `settings.json` is what boots. On Linux and macOS, `~/.claude/settings.json` is a symlink into your linuxploitacious checkout (`~/linuxploitacious/claude/.claude/settings.json`), shared by every profile on the host. A `/model` or `/config` save writes that tracked file: it leaves a diff in the checkout, and a later `git pull --ff-only` that touches the file fails until you resolve it. Nothing in OPS writes that file; deploy and the drift gate only read it.
- To change tiers on your own copy, change the `ANTHROPIC_DEFAULT_*_MODEL` and `CLAUDE_CODE_SUBAGENT_MODEL` env keys and the `"model"` pin together, in a fork of linuxploitacious or in managed settings, so a later Stage-1 pull does not undo or conflict with it. The harness layer is model-agnostic: the SessionStart matchers and the context skills carry no per-model text, so a tier change is a settings and pin change plus this file, never a rewrite of the harness prose.
- To check that the models your settings pin answer on your plan, run `.claude-config/bin/model-probe.sh` (one short request per distinct id; `--list` shows what it would probe without calling the API). It reports only; it never edits a settings file.
- If a pinned model has genuinely gone unavailable, remove the `"model"` key so Claude Code falls back to the `ANTHROPIC_DEFAULT_*_MODEL` aliases; do not guess a replacement.
- 1M fan-out works on both profiles. If 1M spawns ever start failing with `API Error: Usage credits required for 1M context`, a per-account credit gate is forcing subagents down to 200K or less; re-point the aliases at non-`[1m]` ids until it lifts.
