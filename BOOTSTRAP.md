# BOOTSTRAP: first-launch configuration of a fresh OPS copy

You are reading this because `CONTEXT/.bootstrapped` does not exist (the
first-launch gate in `AGENTS.md`, also named in `CONTEXT/core.md`). This copy
of OPS has never met its Operator. Your job this session is the bootstrap:
interview the new user, write who they are and how they want work run into
`CONTEXT/`, and hand them a harness that already knows them. On a fresh copy
the bootstrap IS the session: do not start normal work, and do not treat
`USER.md` or `voice.md` as real; they ship as templates you are about to
replace.

## Prime directive

The doctrine already ships and stays generic: `core.md` (always loaded),
`how-i-work.md` (P1-P15 and the situational rules), `model-roles.md`, and
`project-kata.md`. The template sync (`harness-update`) keeps updating those
files, so bootstrap never edits them, with one exception named in Stage 1
(the kata's Operator overlays). What is missing is the *who* layer, and it
lives only in files no template sync touches:

- `CONTEXT/USER.md`: who the Operator is and who matters around them.
- `CONTEXT/voice.md`: how they write (the voice slot).
- `CONTEXT/standing-orders.md`: their rulings, each dated with its why. A
  ruling overrides the matching default in `how-i-work.md` without editing
  it.
- The slots `CONTEXT/work-tracking.md`, `team.md`, and `tools.md`.

Run it in the harness's own idiom, because you are configuring that harness:

- **The structured question tool, multiple-choice first.** Every question is
  a clickable form with concrete options and a recommended default
  (`how-i-work.md` § Intake detail). Typing is the fallback.
- **Never ask what you can detect.** Stage 0 recon answers the stack and
  environment questions for free.
- **Document the why as you write** (P1): a non-obvious choice gets its
  reason next to it, and every standing order carries its why.
- **Stages are resumable.** The marker records the last stage completed.
  Stage 1 makes the harness fully usable; Stages 2 and 3 are offered, not
  forced.

---

## Stage 0: Recon (silent; before any question)

Detect what the machine already knows so you never ask for it. Run these
read-only probes, absorb the results, and use them to pre-fill `USER.md` and
the recommended defaults in every Stage 1 question. Report a one-line summary
before the first question ("Here's what the box already told me; correct
anything wrong"), so recon is transparent.

- **Identity the box already has:**
  ```bash
  git config --get user.name; git config --get user.email
  gh auth status 2>&1 | head
  ```
- **Installed toolchain** (probe presence, install nothing):
  ```bash
  for t in docker node python3 pwsh go rustc psql terraform kubectl; do \
    command -v "$t" >/dev/null && printf '%s %s\n' "$t" "$($t --version 2>&1 | head -1)"; done
  ```
- **MCP servers already configured:** `claude mcp list` if available, and the
  deferred-tool surface (ToolSearch) for connected servers. Named servers are
  strong signal for the domain and for the `tools.md` slot.
- **The boot:** confirm the core is loaded: `~/.claude/rules/ops-core.md`
  should resolve to `CONTEXT/core.md` (`readlink -f`). If it does not, tell
  the Operator to run `.claude-config/deploy.sh` before going on: without it,
  later sessions start without the core.
- **Existing Claude Code setup:** list `~/.claude/skills/` and read
  `~/.claude/settings.json`. Note the values of `permissions.defaultMode`,
  `skipDangerousModePermissionPrompt`, `remoteControlAtStartup`, and
  `autoCompactEnabled`: Round F discloses them and asks about them. Never
  edit this file: on Linux and macOS it is a symlink into the Operator's
  tracked linuxploitacious checkout.
- **Do the pinned models answer on this plan:**
  ```bash
  .claude-config/bin/model-probe.sh --list   # what the settings pin; no API call
  .claude-config/bin/model-probe.sh          # one short request per distinct id
  ```
  Report only: it prints `ok`, `FAIL`, or `UNSURE` per pinned id and never
  edits settings. If an id FAILs, report the CLI error and what that pin
  serves (`CONTEXT/model-roles.md`), and point the Operator at "Settings,
  pins, and the shared Stage-1 file" in that file; do not edit a settings file
  to work around it. A failure can also mean authentication, network, or CLI
  trouble, not a missing entitlement. `UNSURE` (a timeout or a usage limit)
  says nothing about entitlement.
- **T3 Code host:** `ls -d ~/.t3/runtime/versions/*/t3 2>/dev/null` (or a
  `T3CODE_HOME` in the environment). If present, Round G applies.
- **Repos under `~`:** a shallow scan for `.git` dirs
  (`find ~ -maxdepth 3 -name .git -type d 2>/dev/null | head -40`) sketches
  what the Operator builds.

Recon is inference, not truth (P3): everything inferred here is a default to
confirm in Stage 1, never a fact written unverified.

---

## Stage 1: Core (about 15 minutes; makes the harness usable)

Run a small number of question rounds. Lead every option list with the
recon-derived recommendation, and keep to the decisions that change behavior.

**Round A: Identity.**
- Name (pre-fill from `git config user.name`).
- Role or title, in their words (offer a couple of recon-inferred guesses).
- Organization type: `Solo / freelance` · `Small team or startup` ·
  `Established company` · `Enterprise` · `Other`.
- Primary domain: candidates inferred from repos and MCP servers, plus
  `Other`. The most load-bearing answer: it colors every later default.
- People: who gates their decisions, and whether they want a team roster
  now (`team.md`) or later.

**Round B: What they will use the harness for.** Multi-select:
`Building / automation / integration` · `Writing and documents` ·
`Research and analysis` · `Client or stakeholder deliverables` ·
`Ops / infrastructure` · `Data / trading / quant` · `Other`. Their picks set
the emphasis of `USER.md`.

**Round C: Autonomy posture.** Explain the trade honestly, then let them
choose:
- `Full autonomy: the go is the switch` **(recommended default)**: plan hard
  up front, then run end to end with zero re-prompts, merging green reviewed
  work without asking. This is what `core.md` § "Intake, then autonomy"
  describes.
- `Checkpoint mode`: pause at each major step for confirmation.
- `Confirmation-heavy`: confirm before any write, commit, or external action.

  Record anything other than the default as a dated standing order that
  names the posture and why, so a later session neither reverts it nor
  silently applies the core's default over it.

**Round D: Prioritization frameworks.** The shipped defaults are Theory of
Constraints, Improvement Kata, and the Phoenix Project lens
(`how-i-work.md` § Framework alignment). Offer: `Keep all three` ·
`Keep some` (multi-select) · `Swap in my own` (capture theirs) ·
`Drop the framework overlay`. Record any change as a standing order; leave
`how-i-work.md` itself untouched.

**Round E: Output defaults.** Confirm or override the default document
format (`.docx` / `.md` / other), the conversation register (casual or
formal), and whether a rendered visual page for complex data is offered by
default. Record overrides as standing orders.

**Round F: Permission mode (always asked; never skipped or defaulted
silently).** Before the question, tell the Operator plainly what the Stage-1
settings turned on (README "Opinionated by design" has the full list), using
the values recon read:
- `permissions.defaultMode: "bypassPermissions"`: every session starts with no
  permission prompts. Claude Code runs shell commands, file edits and deletes,
  and network requests without asking; only `deny` rules and OPS's two guard
  hooks (git guard, secrets guard) stop a call.
- `skipDangerousModePermissionPrompt: true`: the one-time confirmation Claude
  Code shows before entering bypass mode is skipped.
- `remoteControlAtStartup: true`: every interactive session connects to Remote
  Control at start, reachable from the Claude apps signed in to the Operator's
  own account (no one else gets access).
- Auto-compaction is on as a backstop near the end of the window (not part of
  this choice; the compaction standing order covers it).

Then ask, with these options:
- `Keep the OPS defaults` (the shipped configuration): bypass mode, no launch
  confirmation, Remote Control at startup. Fits the full-autonomy posture.
- `Normal permission prompts in terminal sessions` (no admin rights needed):
  Claude Code asks before edits and shell commands, and Remote Control waits
  for `/remote-control`. Applies to every session launched through the
  `claude()` shell function; IDE extensions and other launchers keep the
  Stage-1 defaults.
- `Managed normal default, bypass disabled` (needs admin rights): set the
  normal starting default and disable Remote Control at startup for every
  launch path and user on the machine. Bypass mode cannot be entered, but
  other explicit CLI or IDE permission-mode choices still apply.

Prompts and the full-autonomy posture pull against each other: with prompts
on, a run stops at each one until the Operator answers. If they pick prompts,
say so and offer to revisit Round C.

Apply the choice without touching the Stage-1 `settings.json` (a tracked file
in their linuxploitacious checkout; an edit there dirties it, and its next
`git pull --ff-only` fails whenever upstream changed the same file):
- **Keep:** no change.
- **Terminal sessions:** in the `claude()` function that `deploy.sh` wrote to
  `~/.zshrc.local` and `~/.bashrc.local` (Windows: the `profile.local.ps1` seam
  `deploy.ps1` wrote), replace each `--settings '{"ultracode":true}'` with
  ```
  --settings '{"ultracode":true,"permissions":{"defaultMode":"default"},"remoteControlAtStartup":false}'
  ```
  Show the Operator the diff before writing it. `--settings` sits above the user
  settings file, so these keys win for that session; a re-deploy leaves the
  edited function alone. When the Operator passes their own `--settings` to a
  launch, the shim adds nothing, so they add `--permission-mode default` to
  that launch and merge `"remoteControlAtStartup":false` into their own
  settings JSON as well. `"acceptEdits"` instead of `"default"` is the middle
  ground (file edits without asking, unapproved shell commands still ask).
- **Managed default, bypass disabled:** give the Operator this file to install
  with admin rights (merge it into an existing file rather than overwrite one) at
  `/etc/claude-code/managed-settings.json` (Linux and WSL),
  `/Library/Application Support/ClaudeCode/managed-settings.json` (macOS), or
  `C:\Program Files\ClaudeCode\managed-settings.json` (Windows):
  ```json
  {
    "permissions": {
      "defaultMode": "default",
      "disableBypassPermissionsMode": "disable"
    },
    "remoteControlAtStartup": false
  }
  ```
  Managed settings outrank every other settings file and `--settings` JSON.
  `disableBypassPermissionsMode` also rejects `--dangerously-skip-permissions`.
  The starting default is not a mode lock: an explicit `--permission-mode`
  or an IDE's saved mode can still select another non-bypass mode, including
  `auto` or `acceptEdits`. Set those launchers to `default` too.
  Do not run the install yourself: it is a system-wide change the Operator
  makes.

Existing permission `allow` rules still apply in normal mode, including broad
shell approvals. Review `/permissions` with the Operator; changing the default
does not erase those approvals. See [permission-mode precedence](https://code.claude.com/docs/en/permission-modes#which-mode-a-session-starts-in)
and [permission rules](https://code.claude.com/docs/en/permissions#manage-permissions).

Check it took: in a new shell, launch `claude`; the footer shows the normal
mode, Remote Control has not connected, and a shell command without an
existing approval asks before it runs. Check IDE launchers separately.
Record the choice in the marker (`permissions=keep`, `permissions=shell`, or
`permissions=managed`) and as a dated row in `CONTEXT/standing-orders.md`,
so a later session never quietly reverts it.

**Round G: T3 Code browser (T3 hosts only; skip when recon found no T3).**
T3 Code's headless browser (its page previews and browser tools) needs a
one-time setup on each host: `sudo <t3 binary> browser setup`, where the
binary is the newest `~/.t3/runtime/versions/<version>/t3`. It installs the
browser's system libraries and, on Ubuntu 23.10 and later, an AppArmor profile
scoped to T3's chrome-headless-shell (`/etc/apparmor.d/t3-chrome-headless-shell`);
it never changes the system-wide user-namespace restriction. Recommend
`Enable it now` and show the exact command:

```bash
t3="$(ls -1d ~/.t3/runtime/versions/*/t3 | sort -V | tail -1)"; sudo "$t3" browser setup
```

On the Operator's yes, run it if passwordless sudo is available
(`sudo -n true`); otherwise hand them the command to run. It is a system-wide
change, so it needs that yes. `DEPLOYMENT.md` § "T3 Code hosts" has the
detail.

On a T3 Code host, note for Round F: T3 sets each thread's permission mode
from its own settings, so the shell-function option above does not reach T3
threads; the managed-settings option does.

### What Stage 1 writes

1. **`CONTEXT/USER.md`**, replacing the template: every EXAMPLE block, the
   banner, and the `USER-TEMPLATE: unfilled` canary line (`verify-ops.sh`
   check 21 fails on a bootstrapped copy that still carries it). Keep the
   section shape; write only what the Operator gave you or confirmed from
   recon. Do not invent clients, teammates, or metrics; an honest short file
   beats a padded one.

2. **`CONTEXT/voice.md`**, a starter, so a writing task never meets an empty
   slot before Stage 2. Keep the section shape, fill the three registers with
   whatever cues Round E and the interview surfaced, mark the rest "not yet
   captured", and open the changelog with a row "Stage 1 starter; refine in
   Stage 2". Remove the template banner and the synthetic samples.

3. **`CONTEXT/standing-orders.md`**: replace the EXAMPLE row with one dated
   row per ruling from Rounds C through F (the permission choice always gets
   a row), each with its why.

4. **`CONTEXT/project-kata.md` § Operator overlays**: the default LICENSE,
   which file plays the spec slot, and the default org or cluster name for
   `PROJECTS/<org>/<repo>`. This is the one doctrine file bootstrap edits;
   a later template sync shows it as a CONFLICT to port by hand.

5. **The slots.** `CONTEXT/work-tracking.md`: the Operator's real time,
   ticket, and board tools (which system, how time is logged), replacing the
   EXAMPLE blocks and deleting any block for a surface they do not use. This
   is the file the `session-close` reconciliation gate reads; leave it
   accurate or empty, never stale EXAMPLE content posing as a real system.
   `team.md` and `tools.md`: fill what Round A and recon gave you, or leave
   the templates (every skill that reads them degrades gracefully).

6. **Seed the auto-memory pool.** Write a few durable "who the Operator is"
   entries into the cross-project memory pool, routed per `core.md`
   § "Memory and where knowledge goes", then make sure the pool is git-synced:
   `.claude-config/bin/memory-init` (deploy runs it; rerun it if this
   session's memory dir is not yet a symlink into `.claude-memory/`).
   Pointers only, never secret values (`secrets-guard` blocks them).

7. **Write the marker.** Create `CONTEXT/.bootstrapped` recording the stage,
   the date, and the Round F choice (see "The marker"). Its presence flips the
   first-launch gate to normal operation. After this write, the harness is
   fully usable.

### Closing move of Stage 1: the first domain partner

Before you finish, offer to scaffold the Operator's first **domain-partner
skill** with `meta-skill-creator`: a co-pilot skill built around their domain
from Round A (the questions it always asks, the context it always loads, the
outputs it always produces). This is how OPS becomes theirs. Offer it; build
it on a yes, or note they can ask anytime. Then offer Stage 2.

---

## Stage 2: Voice (offered at the end of Stage 1; runnable anytime)

Goal: replace the Stage 1 starter `voice.md` with an evidence-based profile,
so deliverables sound like the Operator instead of a model's house style.

**State the privacy boundary first, plainly:** all analysis runs locally on
this machine. You read their writing here, extract patterns here, and write
the result to `CONTEXT/voice.md` here. Nothing is uploaded or shared. Say this
before you ask them to point at anything.

**Preferred path: mine a real corpus.** Ask them to point at local writing of
their own: a sent-mail export (`.mbox`, `.eml`, a folder of saved messages),
exported chat logs, or writing already on the box (READMEs, PR descriptions,
`git log --author=<them> --format='%B'`, docs, past deliverables). Read a
representative sample and fill every section of `voice.md`: tone, the three
registers with a real example each, words they use and avoid (pulled from the
corpus, not guessed), formatting, the client deliverable brand kit (their real
logo file, colors, fonts, section order, contact block; or an honest "no brand
kit yet; ask before styling deliverables"), email and chat patterns, verbatim
writing samples labeled by register, and the changelog.

Ground every claim in the text (P3): quote real lines; never fabricate a
sample. An honest profile from ten real emails beats an invented one.

**Fallback: no corpus.** Run a calibration exercise: take one neutral
paragraph and present three rewrites (terse and direct, warm and casual,
formal and structured) as options. Have them pick and react; iterate two or
three rounds until the samples read like them. Record the converged samples
and stated preferences, and note in the changelog that the profile is
preference-based pending a real corpus.

Overwrite `CONTEXT/voice.md` with the result and bump the marker to
`stage=2`.

---

## Stage 3: Tune (propose after about a week of real use)

Once the Operator has used the harness for a while, close the loop. Review
what the sessions revealed (corrections they made, defaults they kept
overriding, preferences that showed up in auto-memory) and propose concrete
changes: new or revised standing orders, `USER.md` updates, and `voice.md`
where the voice drifted from the captured profile. Present them as a
diff-style list (accept / adjust / skip each); apply what they approve. Bump
the marker to `stage=3`.

Stage 3 is a proposal, not an ambush: surface it when the current task
allows, never in the middle of live work.

---

## The marker

`CONTEXT/.bootstrapped` is a small state file. Its presence gates first
launch; its `stage` value tells a later session what remains to offer. Write
it as key=value lines:

```
stage=1
bootstrapped_at=<ISO-8601 date>
permissions=<keep, shell, or managed: the Round F choice>
```

Bump `stage` to `2` after voice capture and `3` after the tune pass. Never
delete the marker to "re-run" bootstrap; re-running a stage means invoking
that stage's flow, not tricking the gate.

---

When Stage 1 is written and the marker is set, tell the Operator plainly that
OPS is configured and usable, recap what you captured, and point them at
Stage 2. From the next session on, startup runs normally.

A copy that predates this layout (it has `about-me.md`, `brand-voice.md`,
`working-preferences.md`, or `boot-digest.md`) is not a fresh copy: migrate it
per `DEPLOYMENT.md` § "Migrating to the core boot" instead of re-running
bootstrap.
