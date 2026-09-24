---
title: Cell styles
description: The nine ways a cell can draw a reading, their options, and which metrics each accepts.
---

Every style is monochrome — tinted by macOS to match the menu bar, like its own items — and takes
colour only when an [alert](../alerts/) threshold is crossed.

| Style | Editor name | For |
|---|---|---|
| `text.value` | Number | A number, with an optional quiet caption |
| `graph.history`, `"mode": "line"` | Line Graph | Recent history as a stroke |
| `graph.history`, `"mode": "area"` | Area Graph | The same, filled — easier to read at a glance |
| `graph.histogram` | Histogram | Discrete bars; arguably the honest shape for sampled data |
| `gauge.donut` | Donut | A bounded value as a ring |
| `gauge.arc` | Dial | A 270° dial, open at the bottom |
| `gauge.bar` | Bar | A horizontal track; the easiest to compare between cells |
| `matrix.cores` | Core Matrix | One bar per core, grouped by performance cluster |
| `text.dual-rate` | Stacked Rates | Two rates stacked at half height in one cell |

Two more — `text.clock` and the layout cells `layout.spacer` and `layout.divider` — are on their own
pages: [The clock](../clock/) and [Captions, icons and spacing](../adornments/).

To see every style side by side, drawn from synthetic data:

```bash
make gallery     # writes build/gallery.png
```

## Numbers that do not dance

Every cell reserves the width of the widest value it could ever show, and digits are tabular. A
reading going from 9% to 10% moves the digits inside the cell; it never shoves the rest of your menu
bar sideways. The number and its unit are measured as separate columns, so a `%` or `MB/s` stays put
as the magnitude changes.

## Graphs

A graph's scale is part of what it says, so it follows two rules:

- **Percentages never auto-scale.** A 0–100 graph is always 0 to 100, so 5% looks like 5%.
- **Everything else has a floor and steps.** Below about a megabyte a second, a network graph stays
  near the bottom, so background chatter looks like background chatter. Above that, the top of the
  graph moves in steps of 1, 2 or 5 times a power of the unit — and for bytes those are powers of 1024,
  so the top is a round number of megabytes rather than "1.9 MB/s".

Both are worked out from the data on screen alone, so the same widget fed the same numbers draws the
same way on any Mac.

## Shapes that claim a whole

The donut, dial and bar all say "this much of that much", so they accept only metrics with a known
maximum — percentages, a disk's capacity, memory. A ring 3% full when your network is doing 3 MB/s is
not an approximation; it is a claim about a maximum that does not exist. The editor does not offer
these styles for such metrics and says why.

## When there is no reading

A metric this Mac lacks, or one that has stopped reporting — an ejected disk, a dropped VPN — shows an
**en dash** at the cell's full width, in every style. Never a zero, which would be a false reading, and
never a collapsed cell, which would pull a shared layout apart.

A reading counts as stopped when it has not reported within three of its own sampling intervals.

## Options

Everything has a default and can be left out of a [widget file](../format/).

| Style | Option | Default | Range |
|---|---|---|---|
| `text.value` | `decimals` | `0` | 0–3 |
| | `showsUnit` | `true` | |
| `graph.history` | `mode` | `"area"` | `"line"`, `"area"` |
| | `width` | `34` | 16–120 points |
| | `capacity` | `60` | 10–600 samples |
| `graph.histogram` | `width` | `34` | 16–120 points |
| | `barWidth` | `2` | 1–12 points |
| | `barGap` | `0.5` | 0–6 points |
| `gauge.bar` | `width` | `24` | 10–120 points |
| | `thickness` | `6` | 1–22 points |
| `matrix.cores` | `groups` | `[]` — ask this Mac | up to 8 groups of 64 |
| `text.dual-rate` | `decimals` | `0` | 0–2 |
| `gauge.donut`, `gauge.arc` | — | | |

A stacked-rates cell shows its `metric` on the upper row (↓) and the first metric in its `series` on
the lower one (↑).

`matrix.cores` with no `groups` asks the Mac it is running on, which is what makes a shared core
matrix work on hardware with a different number of cores.
