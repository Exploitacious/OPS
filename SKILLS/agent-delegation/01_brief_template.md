# Brief Template — The 8 Sections

Use this when you are writing a brief for a sub-agent and want the full
template with examples + common failures. The 8 sections are
guideline-rigor (per fleet-doctrine F5), not mandatory — missing
sections flag F6 audit, they don't abort the spawn.

The template is the recommended shape. Tune section weight to the
pattern (parallel-research briefs are short and parallel; heavy-build
briefs are long and detailed).

---

## Section 1 — Working directory + parent commit + target branch

So the sub-agent knows the starting state and what NOT to push.

**What to include:**

- Absolute path to the repo or worktree
- Parent commit SHA (so the sub-agent can verify state on entry)
- Target branch name (or "create new branch from parent commit")
- Explicit do-not-push policy if relevant

**Example:**

```
Working dir: ~/OPS/PROJECTS/ExampleOrg/sample-app
Parent commit: 814db71 (main)
Target branch: feat/signal-history-retention
Do NOT push. Do NOT merge. Open PR locally only; foreman will push.
```

**Common failure if skipped:** sub-agent pushes to wrong branch,
merges prematurely, or starts from an unclean working tree.

---

## Section 2 — Files to read first

Stops the sub-agent from re-discovering structure. Lists paths in
the order the sub-agent should read them.

**What to include:**

- 3-10 file paths, ordered by relevance
- For each, a one-line "why this matters" if non-obvious
- `CONTEXT/worker-digest.md` (mandatory) plus the specific
  principle/section numbers this brief actually invokes, named by number
  — not a full-file doctrine read by default. Full-file reads of
  `operating-doctrine.md` / `fleet-doctrine.md` are the escalation for
  lanes that are genuinely doctrine-heavy (e.g. a brief that turns on
  judgment calls across many principles at once), not the standard
  Section 2 entry.

**Why:** `operating-doctrine.md` alone runs ~48KB — burying the 6
principles a given brief needs inside it dilutes the sub-agent's
attention instead of sharpening it. This is a compliance fix (the
sub-agent actually reads and applies the cited principles), not a
token-savings move.

**Example:**

```
Files to read first (in order):

1. CONTEXT/worker-digest.md — distilled doctrine index (mandatory);
   this brief invokes operating-doctrine P1, P3, P6 and fleet-doctrine F7
2. app/signals/retention.py       — current retention logic
3. app/signals/tests/test_retention.py — test surface to extend
4. docs/decisions/2026-05-18__retention-keep-forever.md — settled
   call you are implementing
```

**Common failure if skipped:** sub-agent burns 30 min surveying the
codebase instead of starting work.

---

## Section 3 — Numbered deliverables

Verifiable artifacts, not vague goals. Each deliverable is something
the auditor can verify exists.

**What to include:**

- Numbered list (so report-back can map 1:1)
- Each item: what file(s) it produces, what behavior changes
- No "improve X" — replace with "X behavior must do Y, tested by Z"

**Example:**

```
Deliverables:

1. app/signals/retention.py — add `retention_days_override` env var
   handling; default = 0 = keep forever
2. app/signals/tests/test_retention.py — 4 new tests covering:
   default keep-forever, env-var override, override = 0 ignored,
   prune logging
3. docs/decisions/2026-05-21__retention-env-override.md — decision
   record citing the operator direction
4. lint rule update — drift-check refuses unrgated DELETE statements
   against retention-protected tables
```

**Common failure if skipped:** sub-agent ships something that
"feels right" but doesn't match the actual ask.

---

## Section 4 — Required tests + doctrine cited by number + name

Per P7 — quote doctrine by number + name. Activates the principle
in the sub-agent's context.

**What to include:**

- Test count expected per deliverable
- Doctrine principles relevant to the work, by number + name
- Quoted lines if the principle has a specific clause that applies

**Example:**

```
Required tests: 4 new tests in test_retention.py (see deliverable 2).

Doctrine governing this work:

- P1 (Document the why) — decision record (deliverable 3) is part
  of the same commit. "I'll fix the docs in a follow-up" is a
  P1 violation.
- P3 (Trust + audit) — additive over destructive: env-var-gated,
  default = preserve. Don't ship destructive default.
- P6 (Best effort is the floor) — no swallowed exceptions on
  retention failures. Log at ERROR with exc_info=True.
- F7 of retention-keep-forever decision — pruning requires env-var
  gate; default = 0 = keep forever.
```

**Common failure if skipped:** sub-agent picks generic best
practices that conflict with project doctrine.

---

## Section 5 — Verification commands

Exact commands the sub-agent runs before reporting back. Same
commands the foreman runs in audit (F6).

**What to include:**

- Test commands (pytest path / args)
- Lint commands
- Doc invariant commands (e.g., `verify-docs.sh`)
- Any project-specific drift checks

**Example:**

```
Before reporting back, run:

  pytest tests/test_retention.py -v
  pytest                         # full suite, must be green
  ./scripts/drift-check.sh
  ./scripts/verify-docs.sh

All four must exit 0. Paste the output summaries in the report.
```

**Common failure if skipped:** sub-agent reports done without
running the full suite. Regressions ship.

---

## Section 6 — Style + accuracy bar with quoted principles

Per P6 + P8 — best effort is the floor; quote the principles.

**What to include:**

- Specific style requirements (logging level, exception handling,
  doc commit-pairing)
- Quoted doctrine clauses ("Per P6 — failures must be loud — log
  at WARNING or ERROR with exc_info=True")
- Project-specific accuracy expectations

**Example:**

```
Style + accuracy bar:

- Per P6 — no swallowed exceptions. Every except: clause logs at
  WARNING or ERROR with exc_info=True.
- Per P6 — no silent degradation. If retention is misconfigured,
  raise; do not default to "good enough."
- Per P1 — decision record (deliverable 3) lands in the same
  commit as the code change. Not as a follow-up PR.
- Per F5 brief template — your report-back uses the format in
  section 8 of this brief.
```

**Common failure if skipped:** sub-agent ships minimum-bar code
that "works" but violates project doctrine.

---

## Section 7 — Banned anti-patterns

Stops the cheapest shortcut at source. Per P6 + P8.

**What to include:**

- Specific strings the sub-agent must not produce
- Specific behaviors the sub-agent must not exhibit
- Why each is banned (so judgment can extrapolate)

**Example:**

```
Banned (these are absolutes, not preferences):

- "TBD" / "to be determined" / "see source" / "placeholder" /
  empty function bodies. If you cannot ship a real implementation,
  defer the item and document the blocker. See P6 (no silent
  degradation).
- `--no-verify` / `--no-gpg-sign` on commits. P3 hard gate.
- Silent except: pass. P6.
- Pruning DELETE without env-var gate. F7 retention.
- The word "just" in code comments or PR descriptions. P8 (avoid
  "just" — calibrates effort downward).
```

**Common failure if skipped:** sub-agent ships placeholder code,
defers the work without surfacing the blocker, or commits with
`--no-verify` when a hook fails.

---

## Section 8 — Report-back format

Every required field spelled out. Sub-agent fills in; foreman
appends to journal.

**What to include:**

- A literal template the sub-agent fills in
- All required fields named
- Format: markdown headings + bullet points, not freeform prose

**Example:**

```
Report back in this exact format:

## Sub-agent report — <task name>
Working dir: <path>
Branch: <branch name>
Commit SHAs: <list of new commits>

### Deliverables status
1. <deliverable 1>: <done | partial | deferred>. Files: <paths>.
2. <deliverable 2>: <done | partial | deferred>. Files: <paths>.
3. <deliverable 3>: <done | partial | deferred>. Files: <paths>.
4. <deliverable 4>: <done | partial | deferred>. Files: <paths>.

### Verification output
pytest tests/test_retention.py -v: <PASS / FAIL — paste summary>
pytest (full suite): <PASS / FAIL — paste summary>
drift-check.sh: <exit code>
verify-docs.sh: <exit code>

### Blockers / deferrals
<none | list each blocker with reason + recommended follow-on
task spec>

### Findings to capture in journal
<bullet list of anything the foreman should know that wasn't in
the brief — schema observations, surprising behavior, doctrine
gaps>
```

**Common failure if skipped:** sub-agent reports back in freeform
prose; foreman can't audit, can't journal, can't roll up.

---

## Worked example — full brief (heavy-build pattern)

```
BRIEF — Signal-history retention env-var override

Working dir: ~/OPS/PROJECTS/ExampleOrg/sample-app
Parent commit: 814db71 (main)
Target branch: feat/signal-history-retention
Do NOT push. Do NOT merge.

Files to read first:
1. CONTEXT/worker-digest.md (mandatory) — this brief invokes
   operating-doctrine P1, P3, P6 and fleet-doctrine F7
2. app/signals/retention.py
3. tests/test_retention.py
4. docs/decisions/2026-05-18__retention-keep-forever.md

Deliverables:
1. retention.py — env var `RETENTION_DAYS_OVERRIDE` handling,
   default = 0 (keep forever)
2. test_retention.py — 4 new tests covering default, override > 0,
   override = 0 ignored, prune logging
3. docs/decisions/2026-05-21__retention-env-override.md — decision
   record
4. scripts/drift-check.sh update — refuse ungated DELETE statements
   against signal_history table

Required tests: 4 new tests in test_retention.py.

Doctrine governing this work:
- P1 — decision record same-commit
- P3 — additive over destructive, env-var-gated default = preserve
- P6 — no swallowed exceptions, no silent degradation
- F7 of retention-keep-forever — pruning requires env-var gate

Verification commands:
  pytest tests/test_retention.py -v
  pytest
  ./scripts/drift-check.sh
  ./scripts/verify-docs.sh
All four must exit 0.

Style + accuracy bar:
- Per P6 — failures loud, log at ERROR with exc_info=True
- Per P1 — decision record in same commit as code
- Per F5 — report back in section 8 format

Banned:
- TBD / placeholder / see source / empty bodies
- `--no-verify`
- Silent except: pass
- Pruning DELETE without env-var gate
- "just" in code comments or PR descriptions

Stakes: production trading platform. 25+ traders consult
signal_history during market hours; a quiet prune would destroy
multi-year base-rate matcher substrate (per
2026-05-18__retention-keep-forever.md). Treat this as the
load-bearing safety mechanism it is.

Escalation grant: if you discover a schema gap or test environment
issue that would force shipping a silently-degraded version, defer
the item and document the blocker as a follow-on task — do not
ship the degradation (per P6, P4).

Report back in this format:

## Sub-agent report — signal-history retention env-var override
Working dir: <path>
Branch: feat/signal-history-retention
Commit SHAs: <list>

### Deliverables status
[fill in per template]

### Verification output
[fill in per template]

### Blockers / deferrals
[fill in per template]

### Findings to capture in journal
[fill in per template]
```

---

## Brief sizing guide by pattern

| Pattern | Brief length | Time to write |
|---------|--------------|---------------|
| parallel-research | 300-600 words | 5-10 min |
| registry-driven | 400-800 words template + per-item params | 10-15 min (template once) |
| surgical-pack | 400-700 words shared rationale + per-edit specs | 10-15 min |
| heavy-build | 800-1500 words | 20-30 min |
| reviewer-fix | n/a (foreman does it) | n/a |

If brief time > 50% of expected sub-agent time, you are probably in
reviewer-fix territory — do it yourself.

---

## Common failures in briefs

- **No doctrine citations.** Vague "follow best practices" = vague
  output. Quote P6, P8, relevant F-rules by number.
- **No stakes framing.** "Implement X" calibrates effort downward.
  Name the real users + real consequence.
- **No escalation grant.** Sub-agents under pressure ship silent
  degradation. Grant explicit "defer over degrade" permission.
- **No report-back format.** Sub-agent returns prose; foreman can't
  audit. Spell out fields.
- **"Just."** Avoid the word entirely. Use precise verbs.
- **Open-ended deliverables.** "Improve retention" is not a
  deliverable. "Add `RETENTION_DAYS_OVERRIDE` env var handling" is.
