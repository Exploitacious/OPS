# BOOTSTRAP — first-launch configuration of a fresh OPS copy

You are reading this because `CLAUDE.md` startup step 0 found no
`CONTEXT/.bootstrapped` marker. This copy of OPS has never met its Operator.
Your job this session is to run the bootstrap: interview the new user, write
their identity and preferences into `CONTEXT/`, and hand them a harness that
already knows who they are. On a fresh copy, the bootstrap IS the session —
do not run the normal startup sequence, and do not try to read `about-me.md`
or `brand-voice.md`; they ship as unfilled templates. You are about to rewrite them with the Operator's real content.

## Prime directive

The shipped `CONTEXT/` files (`operating-doctrine.md`, `foreman-charter.md`,
`fleet-doctrine.md`, `project-kata.md`, and the generic `working-preferences.md`)
are already correct doctrine — the *how we work* layer. What's missing is the
*who* layer: `about-me.md`, `brand-voice.md`, and the handful of
Operator-specific knobs inside `working-preferences.md` and `project-kata.md`.
Bootstrap fills the *who* without disturbing the *how*.

Run it in the harness's own idiom, because you are configuring that harness:
- **AskUserQuestion, multiple-choice-first.** Every question is a clickable
  form with concrete options and a pre-filled recommended default, per
  `CONTEXT/working-preferences.md` § "How to Ask Me Questions". Typing is the
  fallback, not the ask.
- **Never ask what you can detect.** Stage 0 recon answers the stack and
  environment questions for free. Asking a user to type what `git config`
  already knows is exactly the friction this harness exists to kill.
- **Document the why as you write.** Files you generate follow the same
  standard as everything else here (`operating-doctrine.md` Principle 1) —
  a non-obvious choice gets its reason next to it.
- **Stages are resumable.** The `.bootstrapped` marker records the last stage
  completed. Stage 1 makes the harness fully usable; Stages 2 and 3 are
  offered, not forced. A user can stop after Stage 1 and come back days later.

---

## Stage 0 — Recon (silent; before any question)

Detect what the machine already knows so you never ask for it. Run these
read-only probes, absorb the results, and use them to pre-populate the stack
section of `about-me.md` and the recommended defaults in every Stage 1
question. Report a one-line summary of what you found before the first
question ("Here's what the box already told me — correct anything wrong"),
so recon is transparent, not spooky.

- **Identity the box already has:**
  ```bash
  git config --get user.name; git config --get user.email
  gh auth status 2>&1 | head
  ```
- **Installed toolchain** (probe presence, don't install anything):
  ```bash
  for t in docker node python3 pwsh go rustc psql terraform kubectl; do \
    command -v "$t" >/dev/null && printf '%s %s\n' "$t" "$($t --version 2>&1 | head -1)"; done
  ```
- **MCP servers already configured:** run `claude mcp list` if available, and
  check the deferred-tool surface (ToolSearch) for connected servers — those
  reveal which platforms the Operator already wired up (data feeds, ticketing,
  finance, cloud). Named MCP servers are strong signal for the domain.
- **Existing Claude Code setup:** list `~/.claude/skills/` and read
  `~/.claude/settings.json` (model aliases, effort, env) if present — a
  returning user may carry preferences worth honoring rather than overwriting.
- **Repos under `~`:** a shallow scan for `.git` dirs (e.g.
  `find ~ -maxdepth 3 -name .git -type d 2>/dev/null | head -40`) sketches
  what the Operator actually builds — languages, org names, project count.

Recon is inference, not truth (P3): everything you infer here is a *default to
confirm* in Stage 1, never a fact you write unverified.

---

## Stage 1 — Core (~15 min; makes the harness usable)

Run as a small number of AskUserQuestion rounds. Lead every option list with
the recon-derived recommendation. Keep it to the decisions that actually
change behavior — resist turning this into a form-filling marathon.

**Round A — Identity.**
- Name (pre-fill from `git config user.name`).
- Role / title, in their words (free text; offer a couple of recon-inferred
  guesses as options).
- Organization type: `Solo / freelance` · `Small team or startup` ·
  `Established company` · `Enterprise` · `Other`.
- Primary domain: infer candidates from repos + MCP servers, offer them plus
  `Other`. This is the single most load-bearing answer — it colors every
  later default and the domain-partner skill.

**Round B — What they'll use the harness for.** Multi-select where useful:
`Building / automation / integration` · `Writing & documents` ·
`Research & analysis` · `Client or stakeholder deliverables` ·
`Ops / infrastructure` · `Data / trading / quant` · `Other`. Their picks set
the emphasis of `about-me.md` and which AskUserQuestion patterns in `CLAUDE.md`
matter most.

**Round C — Autonomy posture.** Explain the trade honestly, then let them
choose:
- `Full autonomy — the go is the switch` **(recommended default)**: plan hard
  up front, then run end-to-end with zero re-prompts, merging green reviewed
  work without asking. This is what the shipped `working-preferences.md` and
  `foreman-charter.md` are tuned for.
- `Checkpoint mode`: pause at each major step for confirmation before
  proceeding.
- `Confirmation-heavy`: confirm before any write, commit, or external action.

  Whatever they pick, edit `working-preferences.md` § "Before Starting Any
  Task" item 3 and the "go is the switch" language to match — and leave a
  one-line note saying which posture was chosen and why, so a future session
  doesn't silently revert it.

**Round D — Prioritization frameworks.** The shipped default is Theory of
Constraints + Improvement Kata + Phoenix Project lens (see
`working-preferences.md` § "Framework Alignment"). Offer: `Keep all three` ·
`Keep some` (multi-select which) · `Swap in my own` (capture theirs) ·
`Drop — no framework overlay`. Rewrite the "Framework Alignment" section to
reflect the choice; don't leave defaults they rejected.

**Round E — Output defaults.** Confirm or override: default document format
(`.docx` / `.md` / other), conversation register (casual vs formal), and
whether they want the rich-Artifact treatment for complex data offered by
default. Fold answers into `working-preferences.md` § "Output Defaults".

### What Stage 1 writes

1. **`CONTEXT/about-me.md`** — created fresh from the answers, with the
   recon-derived stack. Use this section shape (it mirrors what the rest of
   the harness expects to read):
   - Opening: who they are, role, org, domain — one tight paragraph.
   - "What I Actually Do Day to Day" — their real work areas.
   - "Current Priorities" — a short ranked list.
   - "Technical Stack" — populated from Stage 0 recon, confirmed in Round A.
   - Optional "Leadership Structure" only if they named a team/reporting line.
   Write only what they gave you. Do not invent clients, teammates, or
   metrics — an honest short file beats a padded one.

2. **`CONTEXT/brand-voice.md`** — a *starter* file, so the normal startup
   sequence never hits a missing read before Stage 2 runs. Seed it with the
   standard three-register skeleton (see Stage 2 for the full structure) and
   whatever register cues Round E surfaced, and open the changelog with a row
   marked "Stage 1 starter — refine via Stage 2." State in the file that voice
   has not yet been evidence-captured.

3. **`CONTEXT/working-preferences.md`** — edited in place per Rounds C, D, E.
   It already ships generic; you are adjusting the Operator-specific knobs,
   not rewriting it.

4. **`CONTEXT/project-kata.md` § Operator overlays** — fill the overlays
   section at the bottom with what you now know (default LICENSE, which file
   plays the spec slot, default org/cluster name for `PROJECTS/<org>/<repo>`).
   `working-preferences.md` § "Project Work" already promises bootstrap does
   this — deliver on it.

5. **Seed the auto-memory pool.** Write a handful of durable "who the Operator
   is" entries into the cross-project auto-memory pool (`.claude-memory/`,
   adopted via `ac-memory-init`), following `CONTEXT/foreman-charter.md`
   § "Where knowledge goes". Capture role, domain, stack, and the chosen
   autonomy posture — the facts every future session should inherit without
   re-reading. Pointers only, never secret values (secrets-guard blocks those).

6. **Write the marker.** Create `CONTEXT/.bootstrapped` recording the stage and
   date (see "The marker" below). Its presence is what flips `CLAUDE.md`
   startup step 0 from bootstrap to normal operation. After this write, the
   harness is fully usable.

### Closing move of Stage 1 — the first domain partner

Before you finish, offer to scaffold the Operator's first **domain-partner
skill** via the `meta-skill-creator` skill. The pattern: a co-pilot skill
built around THEIR domain (from Round A) — the questions it always asks, the
context it always loads, the outputs it always produces. This is how OPS stops
being a generic harness and becomes *theirs*. Offer it; if they say yes, invoke
`meta-skill-creator` and build it. If not, note that they can ask for it
anytime.

Then offer Stage 2 (voice) — runnable now or whenever they next have writing
samples handy.

---

## Stage 2 — Voice (offered at end of Stage 1; runnable anytime)

Goal: replace the Stage 1 starter `brand-voice.md` with an evidence-based voice
profile, so deliverables actually sound like the Operator instead of like a
model's house style.

**State the privacy boundary first, plainly:** all analysis runs locally on
this machine. You read their writing here, extract patterns here, and write the
result to `CONTEXT/brand-voice.md` here. Nothing is uploaded, sent, or shared.
Say this before you ask them to point at anything.

**Preferred path — mine a real corpus.** Ask them to point you at any local
body of their own writing:
- A sent-mail export (`.mbox`, `.eml`, a folder of saved messages).
- Chat / channel logs they've exported (Slack, Teams, Discord).
- Their own writing already on the box: `README`s, PR descriptions, commit
  messages (`git log --author=<them> --format='%B'`), docs, past deliverables.

Read a representative sample and extract the **three-register structure** the
harness expects — the same shape used across the doctrine:
1. **Tone descriptors** — a few lines on how they read overall.
2. **Code-switching** — the three registers, each with observed traits and a
   verbatim example:
   - *Casual / internal chat* — the rawest register (length, slang, profanity,
     shorthand).
   - *Professional email* — greetings, sign-offs, warmth, how they follow up,
     apologize, give feedback, schedule.
   - *Deliverable* — structure, precision, the quality bar.
3. **Words & phrases they use** / **words & phrases to avoid** — pulled from
   the corpus, not guessed.
4. **Formatting preferences** — inferred from how they actually format.
5. **Writing samples** — a handful of verbatim excerpts, labeled by register,
   as calibration anchors.
6. **Changelog** table — so the profile is explicitly a living document; invite
   the Operator to refine it as you observe more.

Ground every claim in the text (P3) — quote real lines; never fabricate a
"sample." An honest profile built from ten real emails beats an invented one.

**Fallback — no corpus available.** Run a calibration exercise instead: take
one neutral paragraph and, using AskUserQuestion, present three rewrites of it
(terse/direct, warm/casual, formal/structured) as preview options. Have them
pick and react; iterate two or three rounds until the samples read like them.
Record the converged samples and the stated preferences as the starter voice,
and note in the changelog that it's preference-based pending a real corpus.

Overwrite `CONTEXT/brand-voice.md` with the result and bump the marker to
`stage=2`.

---

## Stage 3 — Tune (propose ~a week of real use in)

Once the Operator has actually used the harness for a while, close the loop.
Review what the sessions revealed — the corrections they made, the defaults
they kept overriding, the preferences that showed up in auto-memory — and
propose a concrete set of edits to `working-preferences.md` (and
`brand-voice.md` where voice drifted from the captured profile). Present the
proposal as a diff-style summary via AskUserQuestion (accept / adjust / skip
each item); apply what they approve. Bump the marker to `stage=3`.

Stage 3 is a proposal, not an ambush — surface it when the current task allows,
don't interrupt live work to run it.

---

## The marker

`CONTEXT/.bootstrapped` is a tiny state file. Its presence gates `CLAUDE.md`
startup step 0; its `stage` value tells a later session what remains to offer.
Write it as simple key=value lines, e.g.:

```
stage=1
bootstrapped_at=<ISO-8601 date>
```

Bump `stage` to `2` after voice capture and `3` after the tune pass. Never
delete the marker to "re-run" bootstrap — re-running a stage is a matter of
re-invoking that stage's flow, not tricking the startup gate.

---

When Stage 1 is written and the marker is set, tell the Operator plainly that
OPS is now configured and usable, recap what you captured, and point them at
Stage 2. From the next session on, `CLAUDE.md` startup runs normally.
