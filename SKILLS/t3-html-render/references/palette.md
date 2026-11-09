# Palette and tokens

The house palette for T3 inline pages. Read it when choosing colors or adding a series.

## The token block

`assets/starter.html` already carries this block on its `.viz` root. T3 sets `color-scheme` on `:root` to match the reader's theme, so `light-dark()` follows a theme switch live, and the `var(--foreground, ...)` fallbacks keep a copy readable on hosts that inject nothing.

```css
.viz{
 --fg:var(--foreground,light-dark(#27272a,#f5f5f5));
 --fg2:var(--muted-foreground,light-dark(#6b6b75,#8a8a8a));
 --bg:var(--background,light-dark(#fcfcfc,#0a0a0a));
 --panel:var(--card,light-dark(#ffffff,#111111));
 --line:color-mix(in oklab,var(--fg) 12%,transparent);
 --grid:color-mix(in oklab,var(--fg) 9%,transparent);
 --axis:color-mix(in oklab,var(--fg) 26%,transparent);
 --rad:var(--radius,10px);
 --s1:light-dark(#2a78d6,#3987e5); /* blue */
 --s2:light-dark(#eb6834,#d95926); /* orange */
 --s3:light-dark(#1baf7a,#199e70); /* aqua */
 --s4:light-dark(#eda100,#c98500); /* yellow */
 --s5:light-dark(#e87ba4,#d55181); /* magenta */
 --s6:#008300;                     /* green */
 --s7:light-dark(#6250d6,#9085e9); /* violet */
 --s8:light-dark(#e34948,#e66767); /* red */
 --ok:light-dark(#08794f,#10b981);
 --bad:light-dark(#c8232c,#fb414a);
 --amber:#fe9a00;
}
```

## Why these and not T3's `--chart-*`

The series slots come from the `dataviz` skill's validated palette and were re-run through its validator against T3's real surfaces (`#fcfcfc` light, `#0a0a0a` dark) on 2026-10-19:

- Slots 1 to 3, all pairs: pass in both modes (worst colorblind separation 9.2 light, 9.4 dark).
- Slots 1 to 8, adjacent pairs: pass in both modes (worst 9.1 light, 8.4 dark).
- T3's own `--chart-*` fail: dark slots 2 and 3 sit outside the lightness band, and light slots 1 and 4 fall under the colorblind floor when all pairs are in play.

T3's dark `--border` (`#191919`) barely shows on a card, which is why `--line` mixes from the foreground instead.

## Rules for using them

1. Assign slots to entities in fixed order and keep them through filters and re-sorts. A color follows the thing, never its rank.
2. Scatter plots, dot plots, and anything where every pair can touch: three series at most. Lines and bars, where only neighbors touch: up to eight in slot order. Past that, fold into "Other" or split into small multiples.
3. Aqua, yellow, and magenta sit under 3:1 contrast on the light surface. Any chart using them carries direct labels or a table view.
4. Text, values, and legends use `--fg` or `--fg2`; a colored swatch beside the text carries identity.
5. Magnitude uses one hue, light to dark. A neutral ramp, `color-mix(in oklab, var(--fg) N%, transparent)` with N from 5 to 38, keeps `--fg` text legible on every step and never reads as a series.
6. `--ok`, `--bad`, and `--amber` are status colors. Pair each with an icon and a word, and never use one as a series.
7. Never two y-axes. Two measures of different scale get two charts.

A new palette is validated, not eyeballed: with the `dataviz` skill available, run its `scripts/validate_palette.js "<hex,...>" --mode light --surface "#fcfcfc"`, then again with `--mode dark --surface "#0a0a0a"`.
