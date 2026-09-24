---
title: Files and uninstalling
description: Where Caliper keeps your widgets and settings, what happens to a damaged file, and how to remove every trace.
---

## Where your widgets live

```
~/Library/Application Support/de.alhaidari.caliper/layout.json
```

Every widget, plus the settings that apply to all of them: density, and whether notifications are
on. It is written on first launch so it can be found, formatted to be read, and rewritten whenever
you change something in the editor. [The widget format](../format/#layoutjson) describes it.

It is safe to edit by hand while Caliper is quit. If Caliper cannot read the file when it starts, it
keeps a copy as `layout.json.unreadable` — so a typo never costs you your widgets — and starts again
from the default widget. Fix the copy and put it back as `layout.json`, with Caliper quit, to recover.

## Everything it writes

| Where | What |
|---|---|
| `~/Library/Application Support/de.alhaidari.caliper/` | `layout.json`, your widgets, and any `layout.json.unreadable` a damaged file was copied to |
| `defaults` domain `de.alhaidari.caliper` | The update switches and last-check time, and where macOS placed each menu bar item |
| `~/Library/Caches/de.alhaidari.caliper/` | Downloaded updates and the update feed's HTTP cache |
| `~/Library/HTTPStorages/de.alhaidari.caliper/` | The same requests' cookie store, empty in practice |

That is all of it.

## Uninstalling

Quit Caliper — turn off **Launch at Login** first, if it is on — then delete `Caliper.app`. To remove
what it leaves behind:

```bash
rm -rf ~/Library/Application\ Support/de.alhaidari.caliper ~/Library/Caches/de.alhaidari.caliper ~/Library/HTTPStorages/de.alhaidari.caliper
```

```bash
defaults delete de.alhaidari.caliper
```

If notifications were ever allowed, Caliper stays listed under *System Settings ▸ Notifications* until
macOS tidies it away; nothing is sent from there once the app is gone.
