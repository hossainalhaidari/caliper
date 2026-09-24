---
title: Translating Caliper
description: Adding a language is copying one directory and translating the right-hand side of each line.
---

Caliper is written in English and ready for any other language. Every string a person reads — in the
app, and the metric names, style names and import reports the libraries produce — is looked up in
`Resources/en.lproj`. Adding a language needs no code changes:

```bash
cp -R Resources/en.lproj Resources/de.lproj
```

Then translate, in `Resources/de.lproj`:

| File | Holds |
|---|---|
| `Localizable.strings` | every string in the app's windows, menus, metric names and reports |
| `Localizable.stringsdict` | the strings that quote a count, where the plural forms are the language's business |
| `InfoPlist.strings` | what macOS shows on Caliper's behalf, before the app does |

In `Localizable.strings` the key on the left is the English text, and it is what the code looks the
string up by — leave it exactly as it is and change only the value on the right. Each entry carries a
note saying where it appears and what its arguments are.

`Localizable.stringsdict` needs a thought rather than a translation. English declares `one` and
`other`; give your language the categories it actually uses — `zero`, `one`, `two`, `few`, `many`,
`other`.

**Leave alone** the unit symbols in the menu bar — `%`, `MB/s`, `W`, `RPM` — and clock format codes.
Sparkle's update window is translated by Sparkle itself.

## Checking it

`make test` runs `LocalizationTests`, which checks the catalogue against the source in both
directions: nothing in the source is missing from it, and nothing in it is dead. It then says which
lines, if any, your language is missing.

After adding strings to the source, a regenerated catalogue to copy new entries from is written to the
temporary directory by:

```bash
CALIPER_DUMP_STRINGS=1 swift test
```
