---
title: Troubleshooting
description: A dash where a number should be, a missing sensor, no notifications, an item that disappeared, and how to report a problem.
---

## A cell shows a dash

An en dash means **no reading**, never zero. Either this Mac does not have that metric — common with a
widget someone else made — or the metric has stopped reporting: a disk was ejected, a VPN interface
went away. A reading that has not arrived within three of its own sampling intervals is treated as
gone. It comes back by itself when the reading does.

For a widget from somewhere else, the import sheet told you which metrics this Mac lacks; `make
sensors` lists everything it has.

## A sensor is missing, or reads wrong

Temperatures, fans and power come from undocumented interfaces that a macOS update can move. When one
is missing, Caliper offers none of its metrics rather than showing a wrong number. A fanless Mac has
no fan metrics at all.

Caliper sends no telemetry and no crash reports, so an issue is the only way anyone learns a macOS
update broke a sensor. Use the
[sensor template](https://github.com/hossainalhaidari/caliper/issues/new/choose), and include the
output of `make sensors`, your Mac model and chip, and your macOS version.

## No notifications

In order:

1. **Has the breach lasted 30 seconds?** A notification waits that long by design. The colour in the
   menu bar does not.
2. **Does the cell have thresholds?** A cell with none never alerts. See [Alerts](../alerts/).
3. **Are they allowed?** *System Settings ▸ Notifications ▸ Caliper*.
4. **Is `alertsEnabled` false** in [`layout.json`](../files/)?
5. **Is it a build without a bundle** — `make run` or `swift run`? Those cannot post notifications,
   and write alerts to the system log instead. Build the app with `make app`.

## A menu bar item disappeared

- **It may be behind the notch.** On a MacBook with a notch, items that do not fit are hidden by
  macOS, not Caliper. Fewer or narrower widgets, or a lower density, make room.
- **It may be hidden.** Check the checkbox beside its name in the [editor](../editor/).
- **It may be on the desktop.** A small window icon beside its name in the editor's sidebar means it
  lives on the desktop; **Show On ▸ Menu Bar** brings it back.

With no item left to right-click, open Caliper again from *Applications*: while it is running, that
opens the editor.

## Update items are missing from the menu

A copy you built yourself has no update feed, so it has no update items — only a release updates
itself. The same goes for **Launch at Login** in a bundle-less build. See [Install and run](../install/).

## "Caliper can't be opened" on another Mac

A copy built without a Developer ID is signed ad hoc, and Gatekeeper refuses it anywhere but the Mac
that built it. Download a release instead, or see [Releasing](../releasing/) to sign and notarise
your own.

## My widgets are gone

If `layout.json` could not be read, Caliper kept a copy beside it as `layout.json.unreadable` and
started from the default widget. [Files and uninstalling](../files/#where-your-widgets-live) says how to
recover it.

## Reporting a problem

Use the [issue templates](https://github.com/hossainalhaidari/caliper/issues/new/choose). The first
thing any report needs is the version and build from **About Caliper**, your Mac model and chip, and
your macOS version.
