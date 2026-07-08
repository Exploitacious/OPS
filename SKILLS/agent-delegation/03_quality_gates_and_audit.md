# Quality Gates and the F6 Audit Pass

Read this when running the F6 audit pass on returned sub-agent work.
This is the catch mechanism for guideline-rigor briefs (F5). Brief
weakness is acceptable; unaudited weakness is not.

Per fleet-doctrine F6 and operating-doctrine P3 (trust + audit):
default trust on sub-agent output, but the safety net is git +
decision records + the audit pass below.

The audit happens AFTER the sub-agent reports back and BEFORE you
declare the round complete (and before you spawn the next round).

---

## The F6 audit checklist

Run all of these. Each is a gate; failing any one means the round
is not complete.

### Gate 1 — Full test suite green

Not "the tests the sub-agent added." The whole suite. New work
can regress old.

```bash
# Project-specific test command — examples:
pytest                          # Python
npm test                        # Node
go test ./...                   # Go
```

If RED: identify whether the regression is in sub-agent's diff
or pre-existing. Pre-existing regression is not the sub-agent's
problem; capture it as a follow-on. Sub-agent regression goes
back to the sub-agent or foreman fixes inline (reviewer-fix).

### Gate 2 — Drift / doctrine lint green

Whatever lint enforces project invariants. Examples:

```bash
./scripts/drift-check.sh        # custom doctrine lint
ruff check                      # Python style
eslint .                        # JS style
verify-docs.sh                  # doc invariants
```

If RED: same triage — sub-agent diff or pre-existing.

### Gate 3 — Sample-load each claimed test module

Verify the test files actually import + execute, not just exist.
Catches stubs that pass by being skipped.

```bash
# For each test module the sub-agent claimed:
python -c "import tests.test_X"  # does it import?
pytest tests/test_X.py -v        # do tests actually run?
```

If any test module has 0 tests collected or all-skipped: that's
a stub. Sub-agent shipped a placeholder. F5-weakness signal.

### Gate 4 — Spot-read 2-3 representative outputs for stub patterns

Look for:

- `TBD`
- `to be determined`
- `placeholder`
- `see source`
- `# implement me`
- `pass  # implement` (Python)
- empty function bodies (only `pass` or `...`)
- suspicious unicode (smart quotes, em-dashes — sub-agent
  copy-pasted from a chat instead of writing)
- copy-pasted doctrine without adaptation (verbatim doctrine
  phrases in code comments)

```bash
# Grep across the diff:
git diff <parent-commit> -- '*.py' | grep -E 'TBD|placeholder|see source|implement me'
```

Each hit is an F5-weakness signal. Decide: send back for fix, or
foreman fixes inline.

### Gate 5 — Audit each new lint / invariant enforces a real rule

If sub-agent added a lint, does it catch a real violation?
Construct a known-bad input and verify the lint catches it.

```bash
# Example: sub-agent added drift-check rule for retention-protected.
# Verify it rejects an ungated DELETE:
echo "DELETE FROM signal_history WHERE created_at < '2026-01-01';" > /tmp/bad.sql
./scripts/drift-check.sh --file /tmp/bad.sql && echo "FAIL — lint missed bad input"
```

Lint that doesn't catch a known violation is a no-op. F5-weakness
signal.

### Gate 6 — Cite the brief

For each section of the brief, did the sub-agent deliver against
it? If a section was skipped or delivered against an undefined
criterion, that's an F5-weakness — file a journal note so future
briefs improve.

```
F5-weakness signals to capture:
- Sub-agent skipped section 7 (banned anti-patterns) entirely
- Section 3 deliverable 4 was vague — sub-agent shipped something
  that "feels right" but doesn't match any stated criterion
- Section 8 report-back format was loose — sub-agent returned
  freeform prose
```

These don't fail the round if the work is otherwise good. They
improve future briefs.

### Gate 6 — Ground-truth the sub-agent's claims

This is the loudest gate added 2026-05-26 after a doc-audit round
returned two parallel sub-agent reports with confident specifics
that turned out to be fabricated. Per operating-doctrine P3
(trust + audit): every numeric or specific claim in a sub-agent
summary is a claim, not a fact, until you verify it.

**What to verify:**
- Line counts (`wc -l <file>`)
- File counts (`find ... | wc -l`)
- Cited line numbers (`sed -n 'Np' <file>` — confirm the claim
  matches the actual line)
- "No findings" / "all clean" / "consistent" assertions on deep
  audits (these are improbable at scale — spot-check 3-5 cases)
- Symbol existence (`grep -r <symbol>`)
- LOC totals (especially round-number ones)
- Schema versions (read the actual file)

**Signs the sub-agent took a shortcut and the gate must fire:**
- Output opens with "Perfect" / "Now let me compile..." / mid-
  thought continuation — the agent didn't actually do the work
- Vague line references ("~line 240" instead of exact)
- Round-number LOC counts ending in 0 with no source quote
- "No findings" / "all healthy" on a brief that asked for an
  exhaustive audit
- File-size figures in KB confused for LOC, or vice versa
- Agent claims it "already had" or "previously verified" context
  it shouldn't have

**Disposition when verification surfaces hallucinations:**

1. Mark the round incomplete; do NOT integrate any output from
   that agent without verification.
2. Either redo the work inline (faster for small surfaces) OR
   respawn with a tighter brief that explicitly bans the
   shortcut pattern observed.
3. File the hallucination class as a brief-improvement note for
   future rounds.
4. Never paste an unverified summary to the Operator as findings.

**Gate enforcement is non-optional.** Sub-agent quality is
inconsistent across rounds; the audit pass is what keeps trust
calibrated. Skipping this gate is how stale "facts" enter the
codebase narrative.

---

## Per-pattern audit specifics

### parallel-research

- Each report file exists and is non-empty
- Reports cite files with line numbers (`path:line`), not vague
  references
- Reports don't contradict each other on factual claims (if they
  do, foreman investigates which is right)
- Reports stay in their scope — sub-agent A didn't drift into
  sub-agent B's territory

Skip: full test suite (no code changed)

### registry-driven content generation

- All items in the registry have a corresponding output file
- Each output has all required sections (per template)
- Cross-item references are explicit + consistent
- No stub strings across the set
- Full doc-lint pass (verify-docs.sh or equivalent)

Skip: code test suite if items are docs only

### surgical-pack

- All named edits made (file:line ranges match the brief)
- No drift edits (sub-agent only touched the named files)
- Shared rationale visible in commit message + PR description
- Full suite green
- Lint green
- Each edit has a corresponding test (or test was added in same
  pack)

### heavy-build

- Every deliverable maps to a real artifact (file + behavior)
- PR description is thorough, not generic
- Decision record exists if section 3 named one
- Worktree branch matches section 1
- Full suite green
- All named verification commands ran + passed
- 3+ outputs spot-read for stubs

### reviewer-fix

- Foreman ran the relevant test before commit
- Commit message clear
- If non-obvious, journal entry filed

---

## Capturing F6 results

The audit pass itself produces an artifact. Don't just run the
gates mentally — file the results.

For solo Claude Code sessions:

- Append to your auto-memory or session notes:
  `## Audit pass — <round name> — <date> — PASS / PASS with notes / FAIL`
- Note any F5-weakness signals so future briefs improve
- Commit the round's work after audit passes

For fleet sessions (Captain or Agent):

- Append to journal: `## YYYY-MM-DDTHH:MMZ — F6 audit pass on <round>`
- Include each gate's PASS/FAIL + any signals
- Roll up to Captain via `ac-msg` with deliverable counts + PR refs
- For Captain: file a decision record if the round changed an
  architectural surface

---

## When audit fails

Triage:

1. **Sub-agent diff regression.** Send back to sub-agent with
   the specific failure + the gate that caught it. Brief
   addendum: "F6 gate <N> failed: <evidence>. Fix and re-report."
2. **Pre-existing failure surfaced by new code.** Capture as
   follow-on task. Not the sub-agent's problem; foreman triages
   priority.
3. **F5-weakness in the brief itself.** Foreman owns this.
   Capture in journal; improve next brief.

Do NOT:

- Override the gate by saying "good enough." P6 (best effort is
  the floor) forbids.
- Skip a gate because the round is "small." Gates apply to all
  patterns except where explicitly skipped above.
- Ship the round and "fix in follow-up." P1 (same-commit) +
  P6 forbid.

---

## Audit time budget

| Pattern | Audit time |
|---------|------------|
| parallel-research | 10-20 min |
| registry-driven | 20-30 min (batch + spot-checks) |
| surgical-pack | 5-10 min |
| heavy-build | 10-20 min |
| reviewer-fix | n/a (foreman is the worker) |

If audit is taking longer than this consistently, the briefs are
too weak — invest more in section 6 (style bar) and section 7
(banned anti-patterns) up front. Audit time and brief time trade
off; better briefs = faster audits.
