---
title: Privacy
description: Caliper has zero telemetry. What stays on your Mac, the one request it makes, and exactly what that request carries.
---

**Caliper reads your Mac and tells nobody.** It collects nothing about you or how you use it. There
are no analytics, no crash reports, no usage statistics, no identifiers, no account, and no server of
Caliper's own for any of it to go to.

This is not a setting you have to find and switch off. The telemetry was never written.

## What stays on your Mac

**Everything it measures** — load, memory, temperatures, fan speeds, power, the busiest processes in
the [detail panel](../panel/) — is read on this Mac and kept in memory, for the graphs, until the app
quits. None of it is written to disk.

**What it writes to disk** is your widgets, in `layout.json`, and the updater's settings.
[Files and uninstalling](../files/) lists every file.

**A widget leaves your Mac only when you export or copy it.** The file holds the widget and when it
was exported — nothing about the Mac it came from. [Sharing widgets](../sharing/) has the details.

**Notifications**, if you allow them, are delivered by macOS on this Mac.

## The one request it makes

Caliper goes online for one thing: to look for an [update](../updates/). With **Check Automatically**
on, which is how it starts, that is once a day; turn it off in the menu and Caliper makes no request
at all until you choose **Check for Updates…**.

A check downloads a single file, the release feed (`appcast.xml`), from Caliper's GitHub releases. If
you take an update, it then downloads that update from the same place. Here is everything those
requests carry:

| | |
|---|---|
| **Your Caliper version** | **Not sent.** The request calls itself `Sparkle`, the same on every copy. Your Mac compares its own version with the feed. |
| **Your language** | **Not sent.** The request asks for any language (`*`) rather than passing on your preferred ones. |
| **Your Mac** — macOS version, model, processor, memory | **Not sent.** Sparkle can attach an "anonymous system profile" to each check. It is off in Caliper, and Caliper allows it no fields, so it would send nothing even if it were switched on. |
| **An identifier** | **None exists** to send. |
| **Your IP address** | **Seen by GitHub**, as it is by any server you connect to. It is the one thing a request cannot leave out. |

Every copy of Caliper sends the same request, so apart from your IP address nothing in it could tell
your copy from anyone else's.

Every update is verified against a signing key built into the copy you are running before it replaces
anything.

## Checking for yourself

The whole app is [open source](https://github.com/hossainalhaidari/caliper). The update settings are
in `Sources/CaliperApp/UpdateService.swift` and `Resources/Info.plist`; Sparkle, the updater, is the
only third-party code in the app.
