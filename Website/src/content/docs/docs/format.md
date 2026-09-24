---
title: The widget format
description: The JSON inside a .caliperwidget file and layout.json — every field, every default, and the limits a file is held to.
---

Widgets are JSON, written to be read and hand-written as well as exported. Everything with an obvious
default may be left out, so this is a complete, valid widget:

```json
{
  "schema": "caliper.widget/1",
  "name": "Minimal",
  "cells": [ { "metric": "cpu.usage.total", "style": { "type": "text.value" } } ]
}
```

The same format is used in two places:

| File | Holds |
|---|---|
| `something.caliperwidget` | One widget, or several, for [sharing](../sharing/) |
| `layout.json` | Every widget you have, plus the settings that apply to all of them — see [Files](../files/) |

## Three promises

**Metric ids are the portable contract.** `cpu.usage.total` means the same thing on every Mac;
`disk.volume.backup.free.bytes` obviously does not. Ids and style `type` names are never renamed, so a
widget written today still opens later. [Sensors and metrics](../sensors/) lists them.

**A widget degrades visibly, never silently.** A metric a Mac lacks keeps its cell and shows a dash;
only a cell that cannot be drawn at all is left out, and you are told.

**A document from a newer version survives a round trip.** A style this version does not recognise is
kept verbatim rather than discarded.

## A widget

| Field | | Default |
|---|---|---|
| `schema` | `"caliper.widget/1"` | that |
| `name` | What the editor and VoiceOver call it | `"Untitled"` |
| `cells` | The cells, leading to trailing | `[]` |
| `spacing` | Points between cells, 0–40 | follows the density |
| `desktop` | Present when the widget lives on the desktop: `x`, `y`, `height` (16–200) and `level`, `"desktop"` (behind windows) or `"floating"` | absent: the menu bar |
| `isEnabled` | Shown or hidden. Not shared: an imported widget is always added shown | `true` |
| `id` | A UUID. Regenerated on import | generated |
| `author`, `created` | Who made it and when; shown on import | absent |

## A cell

| Field | | Default |
|---|---|---|
| `metric` | The metric id it shows. Only spacers and dividers leave it out | required |
| `style` | `{ "type": "…", …options }`; only `type` is required — see [Cell styles](../styles/#options) | required |
| `label` | A caption, up to 16 characters | none |
| `icon` | `{ "symbol": "cpu" }` for an SF Symbol, or `{ "emoji": "🔥" }` — wins over `label` | none |
| `thresholds` | `{ "elevated": 70, "critical": 90 }`, either or both | none: never alerts |
| `alertMetric` | Judge the thresholds against this metric instead of `metric` | `metric` |
| `series` | More metrics the style draws: the lower row of stacked rates | `[]` |
| `id` | A UUID | generated |

A cell as the app writes it:

```json
{
  "id" : "FC57823B-5DCF-46C8-9FED-0DF0C0F13AD2",
  "metric" : "cpu.usage.total",
  "style" : {
    "capacity" : 60,
    "mode" : "area",
    "type" : "graph.history",
    "width" : 34
  },
  "thresholds" : { "critical" : 90, "elevated" : 70 }
}
```

## layout.json

`layout.json` wraps your widgets with the settings that apply to all of them:

| Field | | Default |
|---|---|---|
| `schema` | `"caliper.layout/1"` | that |
| `widgets` | Every widget, in sidebar order | `[]` |
| `density` | `"compact"`, `"regular"` or `"roomy"` | `"regular"` |
| `alertsEnabled` | `false` stops [notifications](../alerts/#notifications); colour in the menu bar is unaffected | `true` |

## Limits

A shared file is measured before anything is drawn from it, and refused with the reason if it breaks
any of these. The editor enforces the same ones.

| | At most |
|---|---|
| File size | 1 MB |
| Widgets in one file | 32 |
| Cells in one widget | 24 |
| Widget width | 1,200 points, judged at its widest on any Mac — about a laptop's whole menu bar |
| Name | 64 characters |
| Caption | 16 characters |
| Emoji | 16 characters |
| SF Symbol name | 64 characters |
| Clock format | 64 characters |
| `series` | 64 metrics |
| Core matrix `groups` | 8 groups of up to 64 cores |

Each style option has a range too — decimals 0–3, a graph 16–120 points wide and 10–600 samples long,
and so on. [Cell styles](../styles/#options) lists them.
