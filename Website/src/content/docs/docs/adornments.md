---
title: Captions, icons and spacing
description: What a cell can carry before its value, and the spacers and dividers that go between cells.
---

## Captions and icons

Every cell can carry one thing before its value, and **every style honours it** — number, graph,
donut, dial, bar, core matrix and stacked rates alike. In the inspector it is under *Appearance*.

| | In a widget file | |
|---|---|---|
| Caption | `"label": "MEM"` | Drawn dimmer than the value, so it reads as a quiet second layer |
| Icon | `"icon": {"symbol": "cpu"}` | Any SF Symbol, monochrome, so it tints with the menu bar exactly as text does |
| Emoji | `"icon": {"emoji": "🔥"}` | Colour, which makes the whole widget carry explicit colours |

An icon wins over a caption when both are set in a file: they take the same place, and the editor
offers them as alternatives. A symbol name this version of macOS does not know takes no space at all,
so a widget naming one looks like it has no icon rather than looking broken.

A caption is at most 16 characters.

## Spacers and dividers

Two cells hold no reading at all:

| Style | In a widget file | |
|---|---|---|
| Spacer | `{"type": "layout.spacer", "width": 18}` | Blank space of a fixed width: 2–80 points, 8 by default |
| Divider | `{"type": "layout.divider"}` | A hairline rule, inset from top and bottom. `thickness` 0.5–4 (default 1), `inset` 0–10 (default 5) |

They are cells rather than settings on their neighbours, because spacing in a strip is not uniform in
practice — you want a wide gap between CPU and network and none at all between download and upload.
As cells they drag, reorder, copy and share like everything else.

They are the only cells with no `metric`, and so they never cause a sensor to be read.

## The gap between cells

Each widget has a **Gap** — the space between every pair of its cells — in the editor's toolbar, 0 to
40 points. Until you set it, it follows the density: *Compact*, *Regular* or *Roomy*.
