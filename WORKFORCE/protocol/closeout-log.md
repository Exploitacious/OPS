# Closeout log

Append-only registry of closed projects. Single source of "what
has the fleet completed and what did it learn." Every new Captain
reads this on activation to inherit institutional memory.

Entries are appended by `bin/ac-close-project` on the close
transition. Do not edit historical entries — write a follow-up if
something changes.

Format per entry (extended 2026-05-13 with cross-cutting fields per
decision `2026-05-13__closeout-scope-aware`):

```markdown
## <project-slug> — closed <YYYY-MM-DD>

- **Active:** <opened-date> → <closed-date>  (<duration>)
- **Agents:** <list>
- **Tasks:** <done-count> done, <cancelled-count> cancelled, <rolled-forward-count> rolled forward
- **Decisions:** <count> filed
- **Operator-directions:** <count> captured
- **Cross-cutting artifacts auto-promoted:** <count>
    - protocol/lessons/<file>.md
    - protocol/standing-directions/<file>.md
- **Open cross-cutting threads at close:** <count>
    - <decision-id> (settled, linked READY IDEA)
- **Manual-review candidates:** see CLOSEOUT.md § Manual-review promotion candidates (heuristic legacy)
- **Closeout artifact:** FLEETPROJECTS/<slug>/CLOSEOUT.md (gitignored, machine-local)
- **Closeout decision:** runtime/decisions/<date>__project-closed-<slug>.md (gitignored)

Summary (1-3 lines): <what shipped, what was learned, what was deferred>
```

Pre-2026-05-13 closeouts use the legacy format (lessons-promoted is a
single list, no cross-cutting accounting). Both formats are valid;
`ac-close-project` writes the extended format going forward.

---

<!-- entries below this line, newest first -->


## EXAMPLE — sample-pipeline — closed 2026-01-15

- **Active:** 2026-01-02T09:00:00Z → 2026-01-15
- **Agents:** Bravo, Captain, Charlie
- **Tasks:** 6 done, 1 cancelled, 1 rolled forward
- **Decisions:** 5 filed
- **Operator-directions:** 3 captured
- **Cross-cutting artifacts auto-promoted:** 1
    - protocol/lessons/2026-01-15__example-cross-cutting-lesson.md
- **Open cross-cutting threads at close:** 0
    (none)
- **Manual-review candidates:** see CLOSEOUT.md § Manual-review promotion candidates (heuristic legacy)
- **Closeout artifact:** FLEETPROJECTS/sample-pipeline/CLOSEOUT.md (gitignored)
- **Closeout decision:** runtime/decisions/2026-01-15__project-closed-sample-pipeline.md (gitignored)

Closed by: Captain

Summary: Illustrative entry only — replace with your first real closeout.
Shipped the initial integration + a normalizer fix. Surfaced 5 architectural
decisions and 3 verbatim Operator directions. 1 lesson promoted to fleet.
Open work rolled forward: a follow-on task (ready) that didn't fit this
project's scope.

