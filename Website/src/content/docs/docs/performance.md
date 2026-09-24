---
title: What it costs
description: Caliper's measured CPU and memory cost, the budgets it is held to, where it falls short, and how to measure it yourself.
---

A menu bar app runs all day, every day, so what it costs is a feature. Caliper publishes a budget and
measures itself against it. **The budget is not moved to fit a measurement** — a budget that follows
the numbers is not a budget.

## Measured

On an Apple M4, running the built app with the default widget — a CPU number, a 60-second CPU graph, a
memory donut, and stacked network rates:

| | Measured | Budget | |
|---|---|---|---|
| CPU, one menu bar item | **0.68%** | 0.3% | **over** |
| CPU, an item that never redraws | 0.04% | 0.3% | within |
| CPU, the pipeline alone, no AppKit | 0.10% | 0.3% | within |
| Memory footprint | 16.4 MB | 30 MB | within |

And the cost of drawing, per operation:

| | |
|---|---|
| Reading a sample | 0.57 µs |
| Redrawing a cell whose value changed | 57 µs |
| Redrawing a cell whose value did not | 1.6 µs |

## Where it goes

A status item that never redraws costs 0.04%. One redrawing every second costs 0.36%. Caliper's own
drawing is 57 microseconds of that; the rest of the roughly 3 ms per redraw is macOS taking the new
image, wrapping it, and compositing it into the menu bar.

**That line is over budget, and it stays over until it is fixed.** The route back under is known: stop
handing macOS a new image every second and draw into a view of Caliper's own instead, which skips the
image creation and invalidation entirely. It has not been done yet.

Adding a live graph did not move the numbers. A cell redraws only when its *pixels* change, not its
value, so a flat graph costs a comparison and nothing else — and a clock showing minutes is drawn once
a minute.

## The editor costs about 20 MB, once

Opening the editor raises the footprint by about 20 MB, and closing it does not give that back:
12.7 MB before, 33.5 MB with the window open, 32.8 MB after closing it. The editor is SwiftUI, and
once macOS has loaded SwiftUI into a process it cannot unload it.

That is held to a **second** budget — 0.5% CPU and 45 MB after editing — rather than by relaxing the
first, because the number worth defending is what Caliper costs sitting there all day, and most
sessions never open the editor. Everything you see without opening it — the menu bar, the
[detail panel](../panel/), [desktop widgets](../desktop/) — is AppKit, for exactly this reason. A
desktop widget on screen permanently costs about 1.9 MB and 0.009% CPU.

Getting the 20 MB back would mean building the editor in AppKit, or running it as a separate process
that exits when closed. Both are possible; neither is free.

## Why it stays light

- **One timer for the whole app**, not one per widget or sensor, with enough leeway that macOS can
  wake it together with everything else on the system.
- **Hardware is read only for cells that are showing.** A sensor nothing is displaying is never
  touched.
- **Sampling stops while nobody can see it**: when the display sleeps, the Mac sleeps, or the screen is
  locked — and, one item at a time, when a full-screen app hides the menu bar of a single-display Mac,
  the notch hides an item, or windows cover a desktop widget. After three seconds out of sight an item
  stops reading the sensors behind it, not just drawing. [Alerts](../alerts/) keep watching throughout.
- **Temperatures are read six sensors at a time.** Reading all 47 takes 44 ms of waiting on the
  system, during which nothing else could be sampled; round-robin, each sensor still refreshes every
  forty seconds or so, which for a quantity that moves over minutes costs nothing real.

On a Mac with more than one display, menu bar items never suspend: macOS shows each one in every
display's menu bar from a single window, so one display's full-screen app says nothing about the
others.

## Measuring it yourself

From a checkout, with `caliper-bench`:

```bash
make bench              # sampler and render costs, per source and style
make soak               # the full pipeline against the budget, DURATION seconds (30)
make watch              # measure a running Caliper.app, DURATION seconds
make soak DURATION=120
```

`soak` and `watch` exit non-zero when a budget is exceeded. After opening the editor, apply the
second budget:

```bash
.build/release/caliper-bench watch 30 --editing
```

`bench` reports wall time and CPU time for each source, because they tell different stories: the
temperature source waits a long time and does very little. It warns, too, that sampling back to back
overstates the cost of sources that talk to the kernel — the power source measures 1.2 ms there and
costs about 0.15 ms in the running app.
