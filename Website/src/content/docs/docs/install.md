---
title: Install and run
description: Downloading Caliper or building it from source, and what happens on first launch.
---

Caliper runs on **macOS 14 or later**.

## Download

Take the disk image from the [releases page](https://github.com/hossainalhaidari/caliper/releases),
open it, and drag **Caliper** into *Applications*. Releases are signed with a Developer ID and
notarised by Apple, so they open like any other downloaded app.

## With Homebrew

```bash
brew install --cask hossainalhaidari/tap/caliper
```

That taps [hossainalhaidari/homebrew-tap](https://github.com/hossainalhaidari/homebrew-tap), trusts
the Caliper cask in it — naming it in full is what Homebrew takes as your say-so — and installs the
same signed, notarised disk image as the releases page. The copy keeps itself up to date as any other
does ([Updates and login](../updates/)), so `brew upgrade` leaves it alone; `brew upgrade --greedy`
moves it on anyway. `brew uninstall --zap --cask caliper` removes your widgets and settings along with
it — everything listed in [Files and uninstalling](../files/).

## First launch

Caliper has **no Dock icon and no window of its own**. It starts with one widget, *Overview*, in the
menu bar:

| Cell | Shows |
|---|---|
| `CPU 23%` | Total processor load, as a number |
| a small graph | The same, over the last 60 seconds |
| a ring | Memory used — coloured by memory *pressure*, not by how full it is ([why](../alerts/#showing-one-thing-alerting-on-another)) |
| two stacked rates | Download over upload |

**Click a cell** for the [detail panel](../panel/). **Right-click** (or Control-click) any Caliper
item for its menu:

| Item | Does |
|---|---|
| **Edit Widgets…** <kbd>⌘,</kbd> | Opens the [editor](../editor/) |
| **Launch at Login** | Starts Caliper when you log in |
| **Check for Updates…** | Looks for a new version now — see [Updates and login](../updates/) |
| **Check Automatically** | The daily update check, on by default |
| **About Caliper** | The version and build that is running, with links to the source and to this site's [Privacy](../privacy/) page |
| **Quit Caliper** <kbd>⌘Q</kbd> | Quits |

Everything else, including the look of the menu bar, is in the editor.

No permission is asked for. The one prompt you may see is macOS asking whether Caliper can send
notifications, the first time an [alert](../alerts/) fires.

## Build it from source

With Xcode's toolchain installed, and nothing else:

```bash
make app        # build build/Caliper.app and launch it
make install    # copy it to /Applications
make test       # run the test suite
make help       # everything else
```

`make stop` quits a running copy. `make run` is the fastest loop — `swift run Caliper`, with no
bundle — and the menu bar strip it shows is the real thing. What a bundle-less binary cannot do is
anything keyed to a bundle identifier: it has no update feed and no login item, so both are left out
of its menu, and its [alerts](../alerts/) go to the system log instead of Notification Center.

A copy you build yourself is a **development build**: it carries a placeholder version and no update
feed, so it never offers to replace itself with the published release.

### Signing

`Tools/bundle.sh` signs with the first *Developer ID Application* certificate it finds in your
keychain (or the one named by `$CALIPER_SIGN_IDENTITY`), or ad hoc when there is none, and says which
it did. The two are very different apps:

| Signature | Runs on the Mac that built it | Runs on any other Mac |
|---|---|---|
| Developer ID + notarised | yes | yes |
| Developer ID, not notarised | yes | only past an explicit override |
| ad hoc | yes | only past an explicit override |

For your own Mac, ad hoc is fine. To give a copy to anyone else, see [Releasing](../releasing/).
