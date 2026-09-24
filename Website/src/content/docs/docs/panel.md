---
title: The detail panel
description: Click a cell and a panel opens on that metric — its last minute, what it is made of, and what is behind it.
---

The menu bar answers "is anything wrong?". The panel answers "what exactly?".

**Click a cell** and the panel opens **on that cell's group** — click the CPU graph and you get the
CPU, click the memory ring and you get memory:

- **A headline**: the reading you clicked, large.
- **Its last minute**, as a graph drawn by the same code as the menu bar.
- **The facts behind it**: for CPU, user and system time and the efficiency and performance clusters;
  for memory, what it is made of; and so on for each group.
- **Top processes** where the group has them: the busiest processes by that measure.
- **Every other group**, as a row of chips along the bottom. Click one to switch.

A cell in a widget is one drawn image as far as macOS is concerned, so Caliper maps the click back to
the cell under the pointer. **Right-click** (or Control-click) still gives the item's
[menu](../install/#first-launch).

A group is whatever the metrics of that kind are — so a sensor added in a later version appears in
the panel with nothing else changed.

## Seeing it without clicking

A bundled build can draw the panel for a group to a PNG, over a deliberately busy background and in
both appearances, so anything showing through where it should not is obvious:

```bash
build/Caliper.app/Contents/MacOS/Caliper --dump-panel panel.png CPU
```

## Why AppKit

The panel is drawn with AppKit and the same renderers as the menu bar, not SwiftUI. SwiftUI costs
about 20 MB the moment it loads and never gives it back, and a panel opened from the menu bar would
pay that on the first click of every session. See [What it costs](../performance/).
