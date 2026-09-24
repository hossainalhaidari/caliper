---
title: Known gaps
description: What Caliper does not do, and whether that is a decision or a wall in macOS.
---

Each of these is here with its reason, so you can tell a decision from a limit before filing a bug.

## Walls in macOS

**It cannot be on the Mac App Store.** Temperatures, power and fan speeds come from
`IOHIDEventSystemClient`, `IOReport` and the SMC, which the App Store sandbox blocks. Caliper is
distributed as a signed, notarised download instead.

**A sensor can vanish with a macOS update.** Those interfaces are undocumented, and Apple can move
them. Caliper probes for each one at launch and offers nothing rather than something wrong — see
[Sensors and metrics](../sensors/#where-the-private-ones-come-from).

**Temperature sensors have no useful names.** Apple silicon labels them `PMU tdie1` and the like, so
there is no "CPU temperature" to offer — only the hottest, the average, the battery and the SSD, plus
every raw sensor under *Advanced*.

**The editor keeps about 20 MB after it closes.** It is SwiftUI, and macOS cannot unload a framework
from a running process. See [What it costs](../performance/#the-editor-costs-about-20-mb-once).

**The menu bar cannot be screenshotted without Screen Recording.** Caliper does not ask for that
permission; `make preview` renders the real strip to a PNG instead. See
[Development](../development/#seeing-the-strip).

**Desktop widgets are not macOS widgets.** WidgetKit cannot update every second, and runs sandboxed
away from the sensors. See [Desktop widgets](../desktop/#why-not-a-macos-widget).

## Decisions

**One menu bar item redraws over its CPU budget.** 0.68% against 0.3%, almost all of it macOS
compositing the new image. The budget stays where it is until the fix — drawing into a view instead
of an image — is made. See [What it costs](../performance/).

**No colour without a threshold.** No per-metric colours, no always-on accent. Colour in the menu bar
means something crossed a line you set, and only stays trustworthy if nothing else uses it.

**No sound for alerts, and no notification before 30 seconds.** An alert that fires on every spike
gets muted, and then tells you nothing.

**No per-cell fonts, padding or corner radius.** Density is the one knob, so a whole menu bar changes
together.

**No animation in the menu bar.** A number easing between values is a number you cannot read.

**No top-processes list in the menu bar.** It is a list, and lists belong in the
[detail panel](../panel/).

**No writing to the hardware, ever.** Fans are read from the SMC; nothing can set them.

**Shared files are refused, not trimmed.** A widget over the limits would arrive as something
different from what was sent. See [Sharing widgets](../sharing/#when-a-file-is-refused).

## Only for bundled builds

A copy run without its app bundle — `make run`, `swift run Caliper` — shows the real menu bar strip,
but it cannot update itself, register a login item, or post notifications, and leaves those out.
