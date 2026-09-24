---
title: Alerts
description: Thresholds, the colours and underlines they bring, notifications, and alerting on a different metric from the one shown.
---

Colour in Caliper always means something. A cell is monochrome — tinted by macOS like its own menu
bar items — until its reading crosses a threshold **you** set. There are three states, and only three:

| State | Looks like | Means |
|---|---|---|
| Nominal | The menu bar's own colour | Unremarkable. The normal state. |
| Warning | System orange, **dashed** underline | Crossed the *Warn at* threshold |
| Critical | System red, **solid** underline | Crossed the *Critical at* threshold |

The underline is there so colour is never the only signal: orange and red are the two hues the
commonest colour-vision deficiencies confuse. VoiceOver says it in words — "CPU critical at 95%".

A cell with no thresholds stays nominal forever. A new cell has none: Caliper does not invent opinions
about your hardware. The default *Overview* widget alerts on CPU at 70% and 90%, and on memory
pressure.

## Setting thresholds

Select a cell in the [editor](../editor/). Under *Alerting*:

- **Warn at** and **Critical at** — either or both, in the units of the metric being judged.
- **Alert on** — which metric the thresholds are judged against. *Same as displayed metric* is the
  usual choice; *None* switches alerting off for the cell and clears its thresholds.

## Showing one thing, alerting on another

What you watch and what you alert on can be different metrics. Memory is the usual case: a healthy
Mac routinely reads 78% used while the kernel reports no pressure at all. Alerting on "used" would cry
wolf every day; showing pressure would be a number nobody recognises. So the default memory cell
**shows how full memory is, and takes its colour from memory pressure.**

Any cell can do the same — show GPU load and alert on GPU temperature, or show a disk's free space and
alert on a threshold in bytes rather than percent.

## Notifications

Colour in the menu bar is immediate and needs no permission. Notifications are deliberately more
reluctant:

- **A breach must last 30 seconds** before anything is said. CPU crosses 70% dozens of times an hour;
  an app that notifies on every spike is muted within a day and then never tells you anything again.
- **Recovery needs a margin.** The reading has to fall meaningfully below the threshold, not merely
  back under it, so a value sitting right on the line does not flip between alert and recovered.
- **No sound.** A chime for a CPU spike trains you to ignore chimes.

macOS asks whether Caliper may send notifications the first time one is due. To stop them without
touching your thresholds, turn Caliper off in *System Settings ▸ Notifications*, or set
`"alertsEnabled": false` at the top level of [`layout.json`](../files/).

**Alerts keep watching while a widget is out of sight** — behind a full-screen app, under the notch,
or covered by windows. Drawing stops then; judging the thresholds does not.
