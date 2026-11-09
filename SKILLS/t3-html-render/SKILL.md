---
name: t3-html-render
description: Use when a reply in a T3 Code thread breaks down data, a report, research findings, a comparison, a plan, or a decision that reads faster as a picture, or when the user asks for a chart, dashboard, visual, or artifact. Builds one self-contained interactive HTML page, checks it with html_preview, and shows it inline with html_render.
---

# T3 HTML render

T3 Code's `html_render` tool shows a self-contained HTML page inline in the thread, above the text reply. It is how this harness does what claude.ai Artifacts did: charts, tables, diagrams, timelines, and small interactive what-ifs live in the chat itself. `html_preview` renders the same page headless and returns a screenshot, the content height, and the console log.

Both tools exist only in a T3 Code thread. In a T3 thread the page is the default for data and reports, shown without asking first; elsewhere, offer a page and wait for a yes. Both rules, and the Operator's standing orders that can change them, are in `CONTEXT/how-i-work.md`, "Reporting to the Operator".

## When to use it

Use it when the content has a shape that prose makes the reader rebuild: a quantity over time, items compared on several measures, a ranking, a flow or architecture, a plan with dates, findings with confidence levels. Readers who scan before they read get the answer at a glance.

Keep plain text when the answer is a sentence, a status line, a yes or no, a short list, or code. Use at most one page per reply, and only on the turns where a picture helps.

## Build it

1. Pick the form before the colors: the data's job picks the chart (a line for change over time, a dot plot or bars for comparison, a stat tile for one number, a drawn flow for steps that branch). The `dataviz` skill, when available, carries the form heuristic and mark specs.
2. Start from `assets/starter.html`, which wires the token block, theme fallbacks, tooltip helper, and resize hook. `assets/example-report.html` is a complete worked page: KPI tiles, an animated line chart with a toggle, a log-scale dot plot against targets, weight sliders that re-rank options, a flow diagram, a timeline, tabbed evidence, and a sortable table. Copy its patterns.
3. Take colors from `references/palette.md`. Its series slots are validated for colorblind safety against T3's light and dark surfaces, which T3's own `--chart-*` variables are not.
4. Fit the frame:
   - Leave `html`, `body`, and the outer element without a background, card, border, or banner title; the page sits on the thread's own background.
   - Use fluid width with no horizontal padding on the outer element, fixed pixel heights for charts, and never `100vh` or `height:100%`.
   - Draw SVG in JavaScript from the container's width and redraw on width change, so a phone at about 360 px gets a real layout.
   - Make every hover target answer a tap too (`pointerdown`), give every multi-series chart a legend, and put the numbers in a table somewhere on the page.
5. Label invented or illustrative numbers as example data on the page.
6. Apply the writing rules inside the page: no em dashes or en dashes, sentence-case headings, conclusion first, units on every axis and value.

## Check it

1. Run `html_preview` at width 728 in dark, then at width 390 in light. The console must show zero errors. Log a check for anything an intro animation hides from the screenshot, such as path lengths or row counts, because the screenshot is taken right after load.
2. Look at both screenshots for clipped labels, collisions, and overflow, and fix them before rendering.
3. Call `html_render` with `height` set to the 728 px `contentHeight`, clamped to 80 through 2000 px so it fits the tool's accepted range. Raise it toward 2000 px when the page can grow after load. The frame fits the page and `height` only caps it; past the cap the page scrolls inside its frame.

## Reply after it

The reader already sees the page, so the reply adds only what the page does not say: decisions, caveats, next steps. End it with a link to the saved file, `$T3CODE_HOME/userdata/attachments/<attachmentId>.html` (`~/.t3` by default), using the `attachmentId` from the render result, so the reader can download or share the page.

T3 prepends a theme style and a small script to the saved file. The style keeps the colors right in any browser (dark by default, light under `prefers-color-scheme: light`). The script follows live theme changes, opens `http(s)` links in the reader's browser, and reports height changes to the frame. The starter marks a top-level page `standalone` and centers it only at 960 px and up, because `html_preview` also renders top-level and must still match the chat frame at 728 and 390. It adds `bare` only when no theme was injected, and only then sets its own colors. Setting colors for every top-level page put light backgrounds under dark-theme text in preview. The page needs no server or browser tab; open a browser preview only when the reader asks to see it full size.
