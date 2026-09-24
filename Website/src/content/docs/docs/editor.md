---
title: Widgets and the editor
description: Adding, arranging, renaming, hiding and moving widgets, and what a new cell starts as.
---

A **widget** is a row of **cells**, and each cell shows one reading in one style. Each widget is its
own menu bar item — or a panel on the desktop — so you can have as many as you like and put them
wherever you want them.

Open the editor with **Edit Widgets…** (<kbd>⌘,</kbd>) from any Caliper item's menu — or, with no
item in the menu bar to click, by opening Caliper again from *Applications* while it is running.

## The editor

The editor has three parts:

- **The sidebar** lists your widgets. The checkbox beside a name shows or hides that widget.
- **The preview** at the top is the selected widget, drawn by the same code as the menu bar, with
  live data. It is not a mock-up that can drift from the real thing.
- **The cell list and inspector** below: select a cell to change its metric, style, caption and
  alerts.

Every change applies immediately. There is no OK button — the preview, and the menu bar itself, are
the feedback.

## Widgets

| To | Do |
|---|---|
| Add a widget | **+** under the sidebar. A new widget starts in renaming, the way a new folder does in Finder. |
| Rename | Double-click the name, or **Rename…** in its context menu. A blank name becomes "Untitled". |
| Hide or show | The checkbox beside its name. Hiding keeps its place, so showing it again puts it back. |
| Move to the desktop | **Show On ▸ Desktop** in its context menu. See [Desktop widgets](../desktop/). |
| Copy one | **Duplicate** in its context menu. |
| Share | **Export…** or **Copy as JSON** in its context menu. See [Sharing widgets](../sharing/). |
| Bring one in | The import button under the sidebar, or drop a file on the list. See [Sharing widgets](../sharing/#bringing-one-in). |
| Delete | **−** under the sidebar, or **Delete** in its context menu. |

**Position in the menu bar is macOS's.** Hold <kbd>⌘</kbd> and drag a Caliper item to move it, as
with any menu bar item. Editing a widget never recreates its item, so a carefully arranged menu bar
does not jump around while you type.

## Cells

| To | Do |
|---|---|
| Add a reading | **+** at the end of the cells, then pick a metric. The list shows only what this Mac actually has. |
| Add space | **Spacer** or **Divider**, at the top of the same popover — see [Captions, icons and spacing](../adornments/#spacers-and-dividers). |
| Reorder | Drag a cell onto another; it takes that cell's place. |
| Change a cell | Select it; the inspector shows its metric, style, appearance and alerting. |
| Remove a cell | **Delete** in its context menu. |

A widget holds at most 24 cells, and is limited in width — the same [limits](../format/#limits) a
shared file is held to, so anything you build here can be sent to someone else.

**Density** — *Compact*, *Regular* or *Roomy* in the toolbar — sets type size and padding for every
widget at once. **Gap** sets the space between cells for the selected widget; until you change it, it
follows the density.

## What a new cell starts as

A metric you add picks a style, a precision and a caption from what it actually is:

| Metric | Starts as |
|---|---|
| The time (`time.epoch`) | A [clock](../clock/), with no caption — the time says what it is |
| Percentages, counts, temperatures | A number with no decimals |
| Sizes, rates, watts | A number with one decimal |
| Everything | A caption from the metric's group: `CPU`, `MEM`, `NET`, `TEMP` |

Changing an existing cell's metric to the time switches a plain number to a clock too, but leaves any
style you chose on purpose alone.

What a new cell does **not** get is thresholds. It stays quiet until you say what "bad" looks like —
see [Alerts](../alerts/).

## When a style is not offered

Some pairings cannot be drawn honestly, and the editor refuses them and says why rather than just
greying the option out. A donut bound to network throughput would claim a maximum that does not
exist, so it is not offered; [Cell styles](../styles/#shapes-that-claim-a-whole) explains the rule.
