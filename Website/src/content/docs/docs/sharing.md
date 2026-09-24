---
title: Sharing widgets
description: Exporting a widget, bringing one in, what the import sheet shows, and why a file can be refused.
---

A widget travels as a `.caliperwidget` file: plain JSON with a registered type, so it opens in any
text editor and double-clicking it in Finder brings it into Caliper. [The widget format](../format/)
describes what is inside.

## Sending one

In the [editor](../editor/), right-click the widget in the sidebar:

- **Export…** saves a `.caliperwidget` file.
- **Copy as JSON** puts the same thing on the clipboard, for pasting into a message or an issue.

The file holds the widget — its name, cells, and when it was exported — and nothing about the Mac it
came from. Whether it was showing in your menu bar is your business, so that is not in it either.

## Bringing one in

Four ways in:

- **Double-click** a `.caliperwidget` file in Finder.
- **Drop** one onto the widget list in the editor.
- **Open** one with the import button under the editor's sidebar.
- **Paste** JSON from the clipboard.

**Nothing lands in your menu bar unseen.** The import sheet draws the incoming widget **against your
own live data** — not a picture of the author's menu bar, which would show you their machine — with a
plain account of anything it cannot show here. Then you choose whether to add it.

A file can hold several widgets; the sheet lets you pick which to add. Each one added is a new widget,
so importing the same file twice gives you two rather than quietly replacing one.

## When a Mac is different

Widgets are written in [metric ids](../sensors/), and not every Mac has every metric:

- **A metric this Mac lacks keeps its cell**, with its reserved width and an en dash, so the layout
  the author designed holds its shape and the gap is obviously a gap.
- **A cell that cannot be drawn at all is left out**, and the report says how many and why — a donut
  bound to network throughput, say, which has no maximum to be a fraction of.
- **Machine-specific metrics are flagged.** A named volume (`disk.volume.backup.*`) or a raw
  temperature sensor (`thermal.sensor.*`) means something only on the Mac it came from. The portable
  spellings — `disk.boot.*`, `thermal.peak` — are the ones worth using in a widget meant for others.
- **A style from a newer Caliper** is carried along untouched rather than thrown away, so opening and
  saving someone's widget cannot destroy the parts this version does not understand yet.

The same check from the command line:

```
$ caliper-bench inspect Workstation.caliperwidget

  Workstation  --  5 cells, at most 212pt wide
  by someone else
  2 metrics unavailable, 1 cell could not be shown
    degraded: gpu.0.utilization is not available on this Mac
    degraded: sensor.thermal.cpu-die is not available on this Mac
    dropped: gauge.donut cannot show net.throughput.down, which has no fixed maximum
```

Add a second path to render the preview as well: `caliper-bench inspect widget.caliperwidget
preview.png`. `make bench-tool` builds `caliper-bench` into `.build/release/`.

## When a file is refused

Sharing is the one feature built to accept files from other people, so a file is measured before
anything is drawn from it, and refused with the reason when it is too big to be a widget — too many
cells, a name or caption too long, an option outside what the editor offers, or wider than a menu bar.
[Limits](../format/#limits) lists them all.

A file is **refused, never trimmed**: a widget missing its last twenty cells is a different widget
from the one that was sent, and nothing would say so. The editor works to the same limits, so a widget
made in Caliper is never refused somewhere else, and width is judged at its widest on any Mac, so a
file is accepted or refused the same way everywhere.
