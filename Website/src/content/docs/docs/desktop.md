---
title: Desktop widgets
description: Putting a widget on the desktop instead of the menu bar, above your windows or just behind them.
---

Any widget can live on the desktop instead of the menu bar. It is drawn by the same code, at a larger
size so it stays legible across a room, in a borderless panel you drag wherever you want it.

## Moving a widget to the desktop

In the [editor](../editor/), right-click the widget in the sidebar and choose **Show On ▸ Desktop**.
**Show On ▸ Menu Bar** brings it back. A widget is in one place or the other, never both, and a small
window icon beside its name in the sidebar says which.

The checkbox beside its name shows or hides it wherever it lives. Hiding keeps its position, so
showing it again puts it where you left it.

## Above or behind

**Desktop Layer**, in the same context menu, sets how it sits among your windows:

| Layer | |
|---|---|
| **Behind windows** | Above the wallpaper and desktop icons, below every app's windows — a widget you see when you clear the screen |
| **Floating above** | Above ordinary windows, always in view |

## What it costs

Having one on screen permanently costs about **1.9 MB and 0.009% CPU**. When windows cover a desktop
widget completely for three seconds, it stops drawing and stops reading the sensors behind it, and it
starts again the moment any of it is visible. [Alerts](../alerts/) keep watching throughout.

## Why not a macOS widget

macOS's own desktop widgets (WidgetKit) are built on timelines with a refresh budget — they cannot
update every second — and run sandboxed, away from the interfaces temperatures, fans and power come
from. A live CPU graph is not something they can show.
