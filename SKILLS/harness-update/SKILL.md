---
name: harness-update
description: >
  Safely sync a private, personalized OPS copy with the public upstream OPS
  template. Use when the Operator says "update the harness", "sync from the
  template", "pull upstream OPS changes", "what's new upstream", or asks to bring
  in a specific upstream improvement. Template copies share NO git history with
  upstream, so plain merge is impossible — this is the supported update path. It
  runs the mechanical scan (.claude-config/bin/harness-update-scan.sh) to classify
  every file NEW / UPDATE / CONFLICT / IDENTICAL, summarizes the upstream CHANGELOG
  in plain terms, asks the Operator what to apply, fast-forwards the safe classes,
  ports conflicts by pattern, runs the gates, and lands one commit. Identity,
  memory, and handoff surfaces are hard-excluded; CONFLICT is never auto-applied.
  Claude Code only.
---

# Harness Update

You pull PUBLIC template code into a PRIVATE, personalized OPS copy. That one
fact sets every rule below.

A copy of OPS is made from the template, then it diverges: `BOOTSTRAP.md` fills
in the Operator's identity, memory accumulates, projects land, the Operator tunes
hooks and doctrine. The template keeps evolving too. But a template copy shares
**no git history** with upstream — `git merge` has no common ancestor to work
from. This skill is the safe path across that gap.

**The risk direction is one-way, and it is not "miss an update" — it is "break
the Operator's personalization."** So:

- Identity, memory, and private working surfaces are **hard-excluded in both
  directions** and never even named in the scan (see the exclusion list below).
- The **CONFLICT** class — a file that changed upstream *and* locally — is
  **never auto-applied**. You port it by pattern (per `CONTRIBUTING.md`'s "port
  patterns, never paste files"), or you skip it. A machine never guesses here.
- Only **NEW** (upstream-only) and **UPDATE** (local still matches the last
  synced version) fast-forward automatically, and only after the Operator says so.

## The sync-state marker

`.claude-config/ops-upstream-ref` — two lines, per copy:

```
upstream=Exploitacious/OPS
last_synced=<sha of the upstream commit last pulled>
```

It is created on the first successful sync and updated at commit time (step 7).
Without it, the scan runs in **first-sync mode**: a full tree compare with no
baseline, so every difference is a CONFLICT (UPDATE is not computable). With it,
the scan diffs only what upstream changed since `last_synced` and can tell an
untouched-local UPDATE from a diverged-local CONFLICT. It lives under
`.claude-config/` deliberately — the repo root is canonical-file-gated
(`CONTEXT/project-kata.md` rule 1).

## The flow

1. **Scan, report-only.** Run the mechanical half:

   ```
   ~/OPS/.claude-config/bin/harness-update-scan.sh
   ```

   It ensures the `ops-template` remote exists (adds
   `https://github.com/<upstream>.git` over HTTPS — no SSH key needed to read a
   public template), fetches it, and prints a classified report plus a summary
   line. It touches nothing and commits nothing. Add `--verbose` if you want the
   IDENTICAL files listed too (default: counted, not listed). Read the classes
   with the table below.

2. **Summarize the upstream CHANGELOG for the Operator, in plain terms.** The
   scan already fetched `ops-template`, so read what changed since the last sync
   and translate it out of repo-speak:

   ```
   # with a marker:
   git -C ~/OPS diff <last_synced>..ops-template/main -- CHANGELOG.md
   # first sync (no marker):
   git -C ~/OPS show ops-template/main:CHANGELOG.md
   ```

   Tell the Operator what the update *does for them* — "remote sessions now
   resume with history after a reboot", not "3 files changed". This is the
   decision input; the scan is the file-level detail behind it.

3. **Ask what to apply (AskUserQuestion).** Two decisions:
   - Apply the safe classes (NEW + UPDATE) now? These are non-destructive to
     personalization by construction, but the Operator still owns the call.
   - For **each CONFLICT**, how: **port by pattern** (recommended — carry the
     mechanic, not the bytes), **skip** (leave the local version), or **show the
     diff** first (`git -C ~/OPS diff ops-template/main -- <path>`) then decide.
   Never bundle conflicts into a single yes/no — each one is its own judgment.

4. **Apply.** Safe classes in one shot:

   ```
   ~/OPS/.claude-config/bin/harness-update-scan.sh --apply-safe
   ```

   It copies NEW + UPDATE only — never CONFLICT, never a hard-excluded file,
   never a deletion, never a commit. Then hand-port each approved CONFLICT: read
   the upstream version for structure and intent, rewrite it against the local
   tree's shape, and leave the unapproved ones alone. Follow `CONTRIBUTING.md`'s
   porting discipline in reverse (public → private): port the pattern, don't
   paste the file.

5. **Translate paths and names on a renamed fork.** Upstream assumes a root of
   `~/OPS` and `ops-*` unit/agent names. If this copy renamed itself, detect it
   by comparing the root that local `CLAUDE.md` states against upstream's `~/OPS`.
   When they differ, every copied *and* ported file needs a translation pass —
   the scan copies verbatim, so after `--apply-safe` sweep the applied NEW/UPDATE
   files for `~/OPS`, `ops-template`, and `ops-*` names and rewrite them to the
   local convention. A verbatim upstream path in a renamed fork is a silent
   breakage (P6 — best effort is the floor).

6. **Run the gates on what changed.** Before committing:

   ```
   ~/OPS/.claude-config/bin/verify-ops.sh          # or the local equivalent
   ~/OPS/.claude-config/bin/secrets-scan.sh <changed files>
   bash -n <each changed shell script>
   node --check <each changed .js>
   ```

   `verify-ops.sh` is the drift gate; `secrets-scan.sh` catches a credential
   riding in on a ported file. All green before step 7 — a red gate is a stop,
   not a note (P6).

7. **One commit; update the marker.** Land a single Conventional Commit that
   lists the features pulled — e.g.
   `chore(harness): sync upstream OPS (remote-session reboot-resume, secrets-scan hardening)`.
   In the same commit, write the marker's `last_synced` to the fetched
   `ops-template/main` sha (`git -C ~/OPS rev-parse ops-template/main`; the scan
   also prints it), creating `.claude-config/ops-upstream-ref` if this was the
   first sync. The marker is the memory that makes the *next* sync a clean delta.

8. **Remind: ported conflicts earn a CHANGELOG entry.** A CONFLICT you ported by
   pattern is a real change to this copy's behavior — it belongs in the local
   `CHANGELOG.md` (`CONTEXT/project-kata.md` rule 5, docs match reality). Safe
   fast-forwards of NEW/UPDATE are the routine sync and don't each need a line,
   but a hand-port does.

## Reading the scan report

| Class     | Meaning                                                        | Action                                             |
| --------- | -------------------------------------------------------------- | -------------------------------------------------- |
| NEW       | Upstream has it, local doesn't                                 | Safe copy (`--apply-safe`)                         |
| UPDATE    | Upstream changed it; local still matches the last synced copy  | Safe fast-forward (`--apply-safe`)                 |
| CONFLICT  | Changed upstream **and** locally (or first sync, no baseline)  | Port by pattern, skip, or diff — never auto-apply  |
| IDENTICAL | Same on both sides                                             | Nothing                                            |
| REMOVED   | Upstream deleted it; local still has it                        | Manual call — the scan never auto-deletes          |

Local-only files (the Operator's own content, absent upstream) are never listed
— they are none of the sync's business.

## The exclusion boundary

These never sync in either direction and never appear in the report, because
naming a private file is itself a boundary crossing:

- `CONTEXT/` identity files — `about-me.md`, `brand-voice.md`,
  `working-preferences.md`, `.bootstrapped`, and everything under
  `CONTEXT/projects/` (per-project lessons name real projects). The *doctrine*
  files in `CONTEXT/` (`operating-doctrine.md`, `project-kata.md`, etc.) are
  portable and **do** sync — they show up as UPDATE/CONFLICT like any other
  template file.
- `.claude-memory/`, `.claude-handoffs/` — memory and in-flight batons.
- `NOTES/`, `DELIVERABLES/`, `PROJECTS/`, `ARCHIVE/` — the Operator's work.

The scan prints these categories in its header so the boundary is visible on
every run.

## Anti-patterns

- **Don't auto-apply a CONFLICT.** The whole point of the class is that a machine
  can't safely resolve it. Port or skip — never let `--apply-safe` near it (it
  won't touch it; don't hand-copy it either without reading both sides).
- **Don't paste a conflicting file wholesale.** Even public → private, carry the
  mechanic and fit it to the local tree. A pasted file re-introduces upstream's
  assumptions (root path, names) that this copy may have changed.
- **Don't skip the CHANGELOG summary (step 2).** The Operator decides on *what
  the update does*, not on a file count. Report-only scan output alone is not a
  decision the Operator can make.
- **Don't forget the marker.** A sync that lands files but doesn't advance
  `last_synced` turns the next scan back into a first-sync CONFLICT storm.
- **Don't commit before the gates are green.** `verify-ops.sh` and
  `secrets-scan.sh` are the contract, not a formality.
