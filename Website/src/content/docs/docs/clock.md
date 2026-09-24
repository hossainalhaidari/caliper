---
title: The clock
description: A date and time cell in either of two format dialects, with a second time zone if you want one.
---

The clock is a cell like any other: add the **Clock** metric (`time.epoch`) and it starts as a clock.
It takes a format in one of two dialects, because retyping a format that already works in another
language is a poor welcome:

| Syntax | Example | |
|---|---|---|
| **Pattern** | `EEE d MMM  HH:mm` | Unicode date patterns, as macOS uses. Localises properly. |
| **strftime** | `%a %d %b  %H:%M` | C `strftime`, as on Linux. |

The default is `HH:mm`, as a pattern. The editor shows a **live preview** of whatever you type,
because nobody remembers whether the month is `MM`, `LLL` or `%b`, and offers common formats in both
dialects — picking one sets the format and its syntax together.

**A newline in the format stacks the clock into two rows.** A format is at most 64 characters.

## A second time zone

Set a time zone and the cell shows the time there, which is how you get a second clock for somewhere
else. Leave it on *System* and it follows your Mac.

```json
{ "metric": "time.epoch", "label": "TOKYO",
  "style": { "type": "text.clock", "format": "%H:%M %Z",
             "syntax": "strftime", "timeZone": "Asia/Tokyo" } }
```

`timeZone` takes an identifier such as `Europe/Berlin`. `locale`, which the editor does not show, sets
the language of day and month names, such as `de_DE`.

## How often it redraws

The clock is read once a second, like every other metric, but a cell only redraws when what it
*shows* changes — so a clock showing hours and minutes is drawn once a minute.

It reserves the width of the widest thing its format can print over a whole year, measured in the
font it draws with, so the menu bar does not shift when "May" becomes "September".
