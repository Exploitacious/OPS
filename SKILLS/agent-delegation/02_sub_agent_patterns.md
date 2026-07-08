# The Five Sub-Agent Patterns

Read this when picking a pattern or scoping a delegation round. Each
pattern has a distinct shape — when to use it, brief size, audit
weight, expected wall-clock. Pick before you spawn; the wrong
pattern wastes the round.

These five emerged empirically across multi-day delegation runs.
They are not exhaustive — your work may fit none of them, in which
case you compose. They are starting points, not constraints.

---

## Agent type — always `general-purpose`

Before picking the pattern, lock the `subagent_type`. The default —
and almost always the correct choice — is **`general-purpose`**.

The Claude Code Agent tool offers several types (`general-purpose`,
`Explore`, `Plan`, cavecrew agents, project-specific types). Reach
only for `general-purpose` when delegating thorough work:

- It has unconstrained tool access (Read, Edit, Write, Bash, Grep,
  Glob, etc.).
- It can complete multi-file investigations, write files end-to-end,
  run lint + tests, and report a structured summary.
- It treats the brief as a contract, not a hint.

Narrow types are **traps** for thorough work:

- `Explore` reads excerpts rather than whole files, misses content
  past its read window, and reports confident-but-fabricated specifics
  on counts ("there are ~60 doc files" when the real answer is 379;
  "no findings" on surfaces with multiple RED drift items). Observed
  2026-05-26 across two parallel audit rounds before the rule was
  codified.
- `cavecrew-*` agents are scoped for specific surgical operations
  (1-2 file edits, single-file reviewers, locator-only lookups). They
  lack the tool surface for anything broader and will silently refuse
  half the brief.
- `Plan` produces plans, not implementations. Useful when you want a
  plan back; wasteful when you wanted shipped work.

**Exception:** one-shot symbol lookups ("where is `X` defined") are
faster with `grep` + Bash directly, no agent needed.

**Default to `general-purpose` unless you have an explicit reason to
narrow.** Per Gate 6 in `03_quality_gates_and_audit.md`, the cost of
re-verifying a narrow agent's hallucinations exceeds the cost of
running `general-purpose` from the start.

---

## Pattern 1 — parallel-research

**Shape:** 2-3 read-only sub-agents writing research notes to a
shared directory. Foreman synthesizes after all return.

**When to use:**

- Domain survey across multiple sources (docs, code, external)
- Multi-source intel gathering (e.g., audit logs + code + decision
  records on the same question)
- Codebase reconnaissance where the question is "what do we
  currently do about X" and you don't yet know which files matter

**Brief shape:**

- Section 3 (deliverables) is a single markdown file per sub-agent
- Section 5 (verification) is "file exists + is non-empty + answers
  the named question"
- Tools restricted to Read, Grep, Glob (no Edit, no Write to
  anywhere but the output file)
- Each sub-agent's brief names the SAME question + a DIFFERENT
  source

**Wall-clock estimate:** 30-60 min total. Each sub-agent ~20-40
min. Foreman synthesis ~10-20 min.

**Example use:**

```
Round goal: "What is the current state of retention logic across
the platform?"

Sub-agent A (codebase scan): Read app/**/*.py, grep for retention
patterns, summarize in research/2026-05-21_retention_codebase.md

Sub-agent B (doc + decision scan): Read docs/ + decisions/, grep
for retention, summarize in
research/2026-05-21_retention_docs.md

Sub-agent C (test scan): Read tests/**/*.py, grep for retention
test coverage, summarize in
research/2026-05-21_retention_tests.md

Foreman synthesizes all three into a single audit document +
decides what to delegate next round.
```

**Audit weight:** light. Read each report, spot-check 2-3 cited
files. Reports are research artifacts, not shipping code; F6 is
relaxed.

**Common failures:**

- Sub-agents duplicate effort (foreman didn't partition cleanly)
- Reports go into chat history instead of files (capture-while-
  running violation, P1)
- Foreman skips synthesis and tries to use raw reports as
  decision input

---

## Pattern 2 — registry-driven content generation

**Shape:** 1 sub-agent per item in a known catalog. Each sub-agent
produces one item; foreman audits the batch.

**When to use:**

- Bulk content work where each item is independent: 1 KB article
  per topic, 1 doc per command, 1 test file per module
- A registry / catalog / list defines the items in advance
- Items don't cross-reference each other (or only reference a
  shared canonical doc)

**Brief shape:**

- Template brief written once
- Per-item parameters injected: item name, slug, target file path,
  any item-specific deliverables
- Section 1-2 + 4-8 are shared template; section 3 (deliverables)
  is per-item
- All sub-agents read the SAME doctrine + the SAME canonical
  reference doc

**Wall-clock estimate:** ~15-30 min per item, parallel. 8 items =
~30-45 min wall-clock + 20 min audit.

**Example use:**

```
Round goal: "Generate KB article for each signal in
app/signals/registry.json (8 entries)."

Template brief covers: doctrine, canonical doc reference, output
file pattern (kb/signals/<slug>.md), required sections (5 fixed
H2s), banned anti-patterns ("no TBD", "no see source"), report-
back format.

Per-item params (8 spawns):
- DIX: slug=dix, file=kb/signals/dix.md, source=app/signals/dix.py
- GEX: slug=gex, file=kb/signals/gex.md, source=app/signals/gex.py
- ... (6 more)

Foreman audits batch: 8 files exist, all 5 required sections
present, no banned strings, all canonical-doc references resolve.
```

**Audit weight:** medium. Per-item spot-check + batch lint. Look
for stub patterns across the set (one sub-agent shipping TBD
suggests others might too).

**Common failures:**

- Template brief drift: each per-item brief diverges, output set
  becomes inconsistent
- Cross-references between items appear silently (one KB article
  mentions another's slug); foreman didn't catch the
  cross-dependency
- Foreman batch-audits but doesn't spot-read individual items
  (stubs slip through)

---

## Pattern 3 — surgical-pack

**Shape:** 2-3 small bounded edits sharing a rationale, bundled
into one PR. Foreman reviews inline.

**When to use:**

- Tightly-related fixes across 2-4 files
- Single rationale ties them together (e.g., "all callers of X
  must pass the new arg")
- Each edit is small enough (5-30 lines) that batching is cleaner
  than separate PRs
- The rationale doc is shared

**Brief shape:**

- Section 6 (style bar) carries the shared rationale
- Section 3 (deliverables) lists each edit as a numbered item
  with file:line range + intended change
- Single PR target; sub-agent opens one branch + one PR
- No separate per-edit verification — full suite + the
  edit-specific test

**Wall-clock estimate:** 20-40 min total. Brief 10 min, sub-agent
work 15-25 min, audit 5-10 min.

**Example use:**

```
Round goal: "Add `retention_protected` flag to all DB tables in
the signal-history domain (4 tables, 1 migration, 1 lint update)."

Brief deliverables:
1. db/migrations/20260521__retention_protected_flag.py — add flag
   col (default true) to signal_history, raw_signals,
   normalized_signals, alert_history
2. app/db/models.py — add the field to each model (4 edits)
3. scripts/drift-check.sh — extend lint to require flag = true on
   any new table in signal-history domain
4. tests/test_drift_lint.py — 2 new tests covering pass + fail
   cases

Shared rationale: per fleet decision 2026-05-18 (retention sacred),
every table touched by signal-history pipeline must opt-in to
retention protection explicitly. Default = protected. Lint
enforces.
```

**Audit weight:** light. Foreman reads the diff inline (small
total size). Full suite must be green. Lint must enforce a real
invariant.

**Common failures:**

- Surgical-pack creep into heavy-build (sub-agent starts adding
  scope). Brief Section 3 must be a closed list.
- Missing one of the related call sites (the "all callers" miss).
  Foreman audit pass should grep for the symbol to confirm
  coverage.
- Tests cover the new edits but the full suite has a regression
  elsewhere. Foreman runs full suite, not just touched files.

---

## Pattern 4 — heavy-build

**Shape:** 1 sub-agent on 1 substantial isolated-scope PR.
Worktree isolation mandatory.

**When to use:**

- One feature, one self-contained refactor, one significant new
  surface
- 2-8 hours of solo work compressed into 30-90 min wall-clock
  via sub-agent focus
- Work that needs full file-edit focus without contamination
- Output is one branch + one PR with multiple commits

**Brief shape:**

- Full 8-section template, longest variant (800-1500 words)
- Section 1 specifies worktree isolation explicitly
- Section 4 lists comprehensive doctrine citations (this is the
  pattern most likely to ship doctrine violations if briefing is
  weak)
- Section 6 + 7 are substantial — full style bar + comprehensive
  banned list
- Section 8 (report-back) is the longest variant — every
  deliverable + every verification + every blocker + findings

**Wall-clock estimate:** 1-3h sub-agent + 10-20 min audit. Brief
authoring 20-30 min.

**Example use:**

The signal-history-retention worked example in
`01_brief_template.md` is a heavy-build brief.

**Audit weight:** heavy. Run full suite. Run all named
verification commands. Spot-read 3+ outputs for stubs. Read the
PR diff in full. Verify each deliverable maps to a real artifact.
Cite the brief in the journal entry.

**Common failures:**

- Brief too short (< 800 words). Heavy-build needs detail.
- Worktree isolation skipped. File contamination ensues if
  multiple sub-agents run concurrently.
- Foreman skips full-suite run, trusts sub-agent's claim. P3
  trust-but-audit violation.
- Sub-agent's PR description is generic. Heavy-build PRs deserve
  thorough descriptions; foreman edits if needed.

---

## Pattern 5 — reviewer-fix

**Shape:** foreman fixes inline. No sub-agent.

**When to use:**

- Bug is 1-5 lines
- Fix is obvious from the bug report or audit finding
- Brief authoring would take longer than the fix
- Single file, no cross-cutting impact

**Brief shape:** none. Foreman:

1. Reads the bug context
2. Edits the file
3. Runs the relevant test
4. Commits with a clear message
5. Files a journal entry if non-obvious

**Wall-clock estimate:** 2-15 min.

**Example use:**

```
Audit found: app/signals/dix.py line 87 logs at INFO, should log
at WARNING per P6 ("failures must be loud").

Foreman: opens Edit, changes INFO → WARNING, runs the test,
commits. Done. 3 min.
```

**Audit weight:** none — foreman IS the worker.

**Common failures:**

- Foreman uses reviewer-fix for >5 line changes. Becomes engineer,
  not foreman. Delegate instead.
- Foreman accumulates many reviewer-fixes in one turn. At >3, ask
  whether this should have been a surgical-pack.
- Foreman skips the test run because "it's obvious." P3 trust-but-
  audit violation. Always run the relevant test.

---

## Pattern composition

Real rounds often mix patterns. Common combos:

- **parallel-research → heavy-build:** research round produces
  the audit; one heavy-build implements the recommendation
- **parallel-research → registry-driven:** research identifies
  the catalog; registry-driven generates the content
- **heavy-build → surgical-pack:** main feature ships in
  heavy-build; the "wire up the call sites" follow-up is
  surgical-pack

Don't try to mix patterns within a single sub-agent. One pattern
per spawn. If a sub-agent's brief implies two patterns, split
into two spawns.

---

## Pattern decision tree

```
Is the work <1 day solo?
├── Yes → reviewer-fix (if <5 lines) or solo
└── No → continue

Is the work mostly research (read-only, multi-source)?
├── Yes → parallel-research
└── No → continue

Is there a catalog/registry with independent items?
├── Yes → registry-driven content generation
└── No → continue

Is the work 2-4 tightly-related edits with shared rationale?
├── Yes → surgical-pack
└── No → heavy-build
```

---

## When to spawn vs not

Spawn a sub-agent when:

- The work parallelizes across independent files / scopes
- The brief can be well-scoped in 5-30 min
- The wall-clock saving > brief + audit overhead
- The main context would otherwise consume tokens on file reads
  that could be discarded

Do NOT spawn when:

- Work is single-threaded synthesis (one mind thinking it through)
- Work is <1 day solo and tightly sequential
- Briefing time > 50% of expected sub-agent time
- You don't yet know what the deliverables are (sub-agent will
  guess; better to think first)

The bottleneck for any foreman is brief authoring + audit pass —
not delegation count. Adding sub-agents past your throughput slows
the round.
