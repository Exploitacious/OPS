---
name: harness-update
description: >
  Use when the Operator says "update the harness", "sync from the template",
  "pull upstream OPS changes", "what's new upstream", or asks to bring in a
  specific upstream improvement. Syncs a private, personalized OPS copy with the
  public upstream OPS template. Template copies share no git history with upstream,
  so plain merge is impossible; this is the supported path. Runs the scan to
  classify every file NEW, UPDATE, CONFLICT, IDENTICAL, summarizes the upstream
  CHANGELOG in plain terms, asks the Operator what to apply, fast-forwards the safe
  classes, ports conflicts by pattern, runs the gates, lands one commit. Identity,
  memory, and handoff surfaces are hard-excluded; CONFLICT is never auto-applied.
  Claude Code only.
---

# Harness update

You pull public template code into a private, personalized OPS copy. That one fact sets every rule below.

A copy of OPS starts from the template, then diverges: `BOOTSTRAP.md` fills in the Operator's identity, memory accumulates, projects land, hooks and doctrine get tuned. The template keeps evolving too. But a template copy shares no git history with upstream, so `git merge` has no common ancestor. This skill is the safe path across that gap.

The risk is one-way. It is not "miss an update," it is "break the Operator's personalization." So:

- Identity, memory, and private working surfaces are hard-excluded in both directions and never named in the scan.
- CONFLICT, a file changed upstream and locally, is never auto-applied. You port it by pattern or skip it. A machine never guesses here.
- Only NEW (upstream-only) and UPDATE (local still matches the last synced version) fast-forward, and only after the Operator says so.

## The sync-state marker

`.claude-config/ops-upstream-ref`, two lines per copy:

```
upstream=Exploitacious/OPS
last_synced=<sha of the upstream commit last pulled>
```

Created on the first successful sync, updated at commit time. Without it the scan runs first-sync mode: a full tree compare with no baseline, so every difference is CONFLICT and UPDATE is not computable. With it, the scan diffs only what upstream changed since `last_synced` and tells an untouched-local UPDATE from a diverged-local CONFLICT. It lives under `.claude-config/` because the repo root is canonical-file-gated (`CONTEXT/project-kata.md` rule 1).

## The flow

1. Scan, report-only. Run `~/OPS/.claude-config/bin/harness-update-scan.sh`. It ensures the `ops-template` remote exists (HTTPS, no SSH key needed to read a public template), fetches it, and prints a classified report plus a summary line. It touches and commits nothing. Add `--verbose` to list IDENTICAL files too.

2. Summarize the upstream CHANGELOG for the Operator in plain terms. The scan already fetched `ops-template`, so read what changed and translate it out of repo-speak:

   ```
   git -C ~/OPS diff <last_synced>..ops-template/main -- CHANGELOG.md   # with a marker
   git -C ~/OPS show ops-template/main:CHANGELOG.md                     # first sync
   ```

   Tell the Operator what the update does for them ("remote sessions now resume with history after a reboot"), not "3 files changed." This is the decision input.

3. Ask the Operator what to apply. Two decisions. Apply the safe classes (NEW + UPDATE) now? For each CONFLICT, how: port by pattern (recommended, carry the mechanic not the bytes), skip (leave the local version), or show the diff first (`git -C ~/OPS diff ops-template/main -- <path>`) then decide. Never bundle conflicts into one yes/no; each is its own judgment.

4. Apply. Safe classes in one shot: `~/OPS/.claude-config/bin/harness-update-scan.sh --apply-safe`. It copies NEW + UPDATE only, never CONFLICT, never a hard-excluded file, never a deletion, never a commit. Then hand-port each approved CONFLICT: read the upstream version for structure and intent, rewrite it against the local tree's shape, leave unapproved ones alone. This is `CONTRIBUTING.md`'s porting discipline run public to private: port the pattern, do not paste the file.

5. Translate paths on a renamed fork. Upstream assumes a root of `~/OPS` and `ops-*` unit and agent names. If this copy renamed itself, detected by comparing the root the local `CLAUDE.md` states against upstream's `~/OPS`, every copied and ported file needs a translation pass. After `--apply-safe`, sweep the applied files for `~/OPS`, `ops-template`, and `ops-*` names and rewrite them to the local convention. A verbatim upstream path in a renamed fork is a silent breakage.

6. Run the gates on what changed, before committing:

   ```
   ~/OPS/.claude-config/bin/verify-ops.sh          # drift gate (or local equivalent)
   ~/OPS/.claude-config/bin/secrets-scan.sh <changed files>
   bash -n <each changed shell script>
   node --check <each changed .js>
   ```

   `verify-ops.sh` is the drift gate; `secrets-scan.sh` catches a credential riding in on a ported file. All green before step 7. A red gate is a stop, not a note.

7. One commit, update the marker. Land a single Conventional Commit listing the features pulled, for example `chore(harness): sync upstream OPS (remote-session reboot-resume, secrets-scan hardening)`. In the same commit, write the marker's `last_synced` to the fetched sha (`git -C ~/OPS rev-parse ops-template/main`; the scan prints it too), creating `.claude-config/ops-upstream-ref` if this was the first sync. The marker makes the next sync a clean delta.

8. Ported conflicts earn a CHANGELOG entry. A CONFLICT you ported is a real change to this copy's behavior, so it belongs in the local `CHANGELOG.md` (`CONTEXT/project-kata.md` rule 5, docs match reality). Safe fast-forwards of NEW/UPDATE are the routine sync and need no line each; a hand-port does.

## Reading the scan report

| Class | Meaning | Action |
|---|---|---|
| NEW | Upstream has it, local doesn't | Safe copy (`--apply-safe`) |
| UPDATE | Upstream changed it; local still matches the last synced copy | Safe fast-forward (`--apply-safe`) |
| CONFLICT | Changed upstream and locally (or first sync, no baseline) | Port by pattern, skip, or diff; never auto-apply |
| IDENTICAL | Same on both sides | Nothing |
| REMOVED | Upstream deleted it; local still has it | Manual call; the scan never auto-deletes |

Local-only files, the Operator's own content absent upstream, are never listed. They are none of the sync's business.

## The exclusion boundary

These never sync in either direction and never appear in the report, because naming a private file is itself a boundary crossing:

- `CONTEXT/` identity files: `about-me.md`, `brand-voice.md`, `working-preferences.md`, `.bootstrapped`, and everything under `CONTEXT/projects/` (per-project lessons name real projects). The doctrine files in `CONTEXT/` (`operating-doctrine.md`, `project-kata.md`, and the rest) are portable and do sync; they show up as UPDATE or CONFLICT like any template file.
- `.claude-memory/`, `.claude-handoffs/`: memory and in-flight batons.
- `NOTES/`, `DELIVERABLES/`, `PROJECTS/`, `ARCHIVE/`: the Operator's work.

The scan prints these categories in its header so the boundary is visible on every run.

## Anti-patterns

- Auto-applying a CONFLICT. The point of the class is that a machine cannot safely resolve it. Port or skip; `--apply-safe` will not touch it, and neither should a hand-copy that skips reading both sides.
- Pasting a conflicting file wholesale, even public to private. Carry the mechanic and fit it to the local tree. A pasted file re-introduces upstream's assumptions, root path and names, this copy may have changed.
- Skipping the CHANGELOG summary. The Operator decides on what the update does, not on a file count.
- Forgetting the marker. A sync that lands files but does not advance `last_synced` turns the next scan back into a first-sync CONFLICT storm.
- Committing before the gates are green. `verify-ops.sh` and `secrets-scan.sh` are the contract, not a formality.
