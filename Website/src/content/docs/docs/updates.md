---
title: Updates and login
description: How Caliper updates itself, what it checks and when, About Caliper, and starting at login.
---

## Updates

A copy downloaded from the [releases page](https://github.com/hossainalhaidari/caliper/releases)
keeps itself up to date with [Sparkle](https://sparkle-project.org). Two items in any Caliper item's
menu govern it:

| Item | |
|---|---|
| **Check for Updates…** | Looks now. Once an update is waiting, it reads **Update to 1.2.0…** |
| **Check Automatically** | On by default: one check a day. Untick it and Caliper never looks on its own |

The check reads `appcast.xml` from the latest GitHub release, and nothing else — [Privacy](../privacy/)
lists exactly what that request carries. Every download is verified against a signing key built into
the copy you are running before it replaces anything, and releases are all signed with the same
Developer ID.

**It waits for a good moment.** Caliper has no Dock icon and is never the frontmost app on its own,
so an update found mid-afternoon does not open a window behind whatever you are doing. The update
alert appears just after launch or once the Mac has been idle; otherwise the update waits in the
menu, as **Update to …**, until you choose it.

**A copy you build yourself does not update itself.** It has no update feed, so the two update items
are not in its menu.

## About Caliper

**About Caliper** in the menu shows the version and build that is running — the first thing to quote
in a bug report — with links to the source, to [Privacy](../privacy/), and to the licences of what
the app includes. The licences are inside the app, in `Contents/Resources/Licenses`, so they open
offline.

## Launch at Login

**Launch at Login** in the menu registers Caliper with macOS as a login item. macOS keeps the
switch, not Caliper, so turning it off in *System Settings ▸ General ▸ Login Items* is reflected in the
menu too. A copy run straight from a build, with no app bundle, has nothing to register and leaves
the item out.
