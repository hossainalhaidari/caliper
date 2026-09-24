---
title: Accessibility
description: VoiceOver in the menu bar, the panel and desktop widgets, and alerts that never depend on colour alone.
---

A Caliper widget is a single drawn image as far as macOS is concerned, which would make it invisible
to VoiceOver. So each one carries its own words.

## VoiceOver

**Menu bar items** have the widget's name as their label, and as their value what every cell shows —
"CPU 23%, Memory Used 61% and Download 1.2 MB/s" — rebuilt whenever the picture is.

- An alerting cell says so: "CPU critical at 95%".
- A cell of many readings, like a core matrix, is summarised as an average and a peak rather than
  read out core by core.
- A cell with no reading says "no reading".

**Desktop widgets** and the editor's preview say the same.

**The detail panel** is drawn rather than built from controls, so it gives VoiceOver an element for
every line it draws, and its group chips are buttons that press.

## Not colour alone

An alert is never only a colour. A cell past its warning threshold is underlined with a **dashed**
line, and past its critical one with a **solid** line. The line sits under the cell, where no style
draws, so it costs no width. See [Alerts](../alerts/).

## Reduce Motion

Nothing in Caliper animates. A number that eases between values is a number you cannot read, so
there is nothing for Reduce Motion to turn off.
