# Standing directions — fleet-wide

This directory holds `operator-directions/*.md` files that were filed inside a project but apply fleet-wide. They get auto-promoted here by `ac-close-project` Phase E when a project closes with `scope: cross-cutting` standing directions in its `runtime/operator-directions/`.

Filename convention: `<YYYY-MM-DD>__<slug>.md` — matches the original artifact's filename.

Frontmatter is preserved from the original. A "Promoted from" banner is added by `ac-close-project` documenting which project authored the direction and when.

Reading order for new Captains on activation: AFTER `personalities/captain-standing-orders.md` and BEFORE walking individual `runtime/operator-directions/` of the active project. Standing directions in this directory apply to all projects unless explicitly superseded.

## Difference from `personalities/captain-standing-orders.md`

- `captain-standing-orders.md` is the cumulative interpretation file — narrative, summary, "what does the Operator currently expect."
- This directory holds the verbatim raw operator-directions that fed into that interpretation, promoted out of closed projects so they survive archival.

If a standing direction here changes the interpretation, the Captain SHOULD update `captain-standing-orders.md` accordingly. The two files together form the standing-orders layer.

## Supersession

To retire a standing direction, file a new operator-direction (or decision) in the active project marking the old slug `superseded_by`. Don't edit files here directly.
