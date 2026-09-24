# Caliper -- Architecture

How Caliper is meant to look and feel, how it is built, and the reasoning behind
both. What the app does and how to use it is in the documentation, in `Website/`
and published at <https://hossainalhaidari.github.io/caliper/docs/>; this file is
for the people changing it.

The first half is the **design language**: the reference every milestone is
checked against. It is opinionated on purpose -- a stats app that tries to please
everyone becomes a control panel. The second half, from [Structure](#structure)
on, is **how it is built**: the layers, the measurements, and what building it
taught that no document said.

## Stance

**A calm instrument, not a dashboard.**

A dashboard wants to be looked at. An instrument wants to be glanced at and then
forgotten, and to interrupt you only when something is actually wrong. Almost
every system monitor is built as the former and then used as the latter: people
install them for reassurance, leave them running for years, and look directly at
them maybe twice a week.

So the design optimises for the 99.9% of the time you are *not* reading it. The
menu bar strip should be something your eye slides past, until the moment it
shouldn't.

## Principles

**1. Colour is signal, never decoration.**
The strip renders as a monochrome template image, which macOS tints to match the
menu bar in light mode, dark mode, and under a tinted wallpaper. It looks like it
shipped with the OS. Colour appears *only* when a value crosses a threshold its
owner set -- which means colour in the menu bar always means something, and you
learn to trust it. A rainbow of per-metric colours would make the alerting state
invisible, because it would look like every other state.

Colour is never the *only* signal, though. Orange and red are the two hues the
commonest colour-vision deficiencies confuse, with each other and with the menu
bar's own grey, so an alerting cell is also underlined: dashed when it has passed
its warning threshold, solid when it has passed its critical one. The line sits
under the cell, where no style draws, so it costs no width -- principle 2 holds.
And for VoiceOver the same states are words: "CPU critical at 95%".

**2. Numbers must not dance.**
Every cell reserves the width of the widest string it could ever render and never
changes size. Digits are tabular. A value going 9% -> 10% moves the digits inside
the cell; it does not shove the rest of your menu bar sideways. This is the
difference between a strip you can ignore and one that pulls your eye once a
second. It is enforced by a test, not by care.

**3. One idea per cell.**
A cell shows one metric in one form. Combinations are made by putting cells next
to each other, not by cramming two numbers into one glyph. This is what makes
"any combination of stats" tractable instead of combinatorial.

**4. What you show and what you alert on can be different things.**
macOS forces this: a healthy Mac routinely reads 78% memory used while the kernel
reports no pressure at all. Showing pressure would be truthful but unfamiliar;
alerting on used% would cry wolf every day and train you to ignore the one signal
the app has. So the memory cell shows the number people look for and takes its
colour from the number that is true.

This is a property of every cell (`Cell.alertMetric`), not a memory special case
-- show GPU utilisation and alert on GPU temperature, show disk free and alert on
a threshold in bytes rather than percent.

**5. Glance, then look.**
The menu bar answers "is anything wrong?". The panel answers "what exactly?".
Nothing that belongs in the second is allowed to migrate into the first.

**6. Density is a setting, not a default.**
Compact / Regular / Roomy move type size and padding together. A 13" MacBook with
fourteen menu bar items and a 32" display with three cannot share one spacing
value, and per-cell padding controls would push that decision onto the user one
cell at a time.

**7. Absent data looks absent.**
An unavailable sensor renders as an en dash at full reserved width -- not as `0`,
not as `n/a`. Zero is a lie about the hardware, and a collapsing cell makes a
shared layout fall apart on a machine that lacks one sensor.

This extends to data that *stops*. A volume is ejected, a VPN drops, a sensor
disappears on an OS update: the last value would otherwise sit frozen in the menu
bar looking entirely plausible, which is the worst thing a monitoring tool can
do. Anything that has not reported within three of its own sampling intervals
reverts to the placeholder.

## The menu bar cell

A cell is three columns, each sized to its own worst case:

```
   +----------------------------------+
   |  CPU  |     42 | %               |
   |  MEM  |     77 | %               |
   |   v   |      7 | KB/s            |
   +----------------------------------+
      ^         ^     ^
      |         |     +-- unit, LEFT-aligned at a fixed x
      |         +-------- number, RIGHT-aligned in its own column
      +------------------ label: 85% size, 55% opacity
```

Splitting the number from the unit is what makes a multi-cell strip legible. Both
must be reserved at their widest, or a cell resizes as its value grows -- but
formatting them as one right-aligned string makes the unit *slide* horizontally
as the magnitude changes (`7 KB/s` and `888 MB/s` end at the same x, so their
units do not align). Measuring the two columns independently pins the `%`, the
`°` and the `MB/s` to a fixed position, and the strip reads as a small table
instead of a run-on sentence.

## Colour

Three states, and only three.

| State    | Appearance                    | Meaning                        |
|----------|-------------------------------|--------------------------------|
| Nominal  | Template (adapts to menu bar) | Unremarkable. The normal state. |
| Elevated | System orange                 | Crossed the threshold you set.  |
| Critical | System red                    | Crossed the second threshold.   |

A cell with no thresholds is permanently nominal. New cells are quiet until their
owner says what "bad" looks like -- the app does not invent opinions about your
hardware.

Because AppKit templates are all-or-nothing per image, one alerting cell forces
the whole strip into explicit colours. Nominal cells then draw in `labelColor`,
which is what the template would have resolved to anyway, so the transition is
invisible.

## Typography

System font with **monospaced digits** -- not a monospaced font. Proportional
letterforms keep labels compact and readable; fixed-width digits keep the numbers
from shifting. Sizes: 10 / 11.5 / 13pt by density, against a 22pt item height.

Text is centred on the font's *metrics*, not on its glyph bounding box, so the
baseline cannot jump when the string changes.

## Graphs

**A graph's ceiling is a claim, so it has to be readable.** Scaling continuously
to whatever is in the window destroys any sense of absolute magnitude: a machine
trickling 7 KB/s of background chatter draws the same full-height storm as one
saturating a gigabit link. Two rules fix that.

A **floor** means quiet looks quiet. Below a megabyte a second, the trace stays
near the bottom where it belongs, because that is the threshold at which network
activity is something you did rather than something the OS is doing for you.

A **quantised ceiling** -- 1, 2, or 5 times a power of the unit -- means the scale
changes in occasional visible steps rather than breathing on every tick. And the
quantisation happens in the units the value is labelled in: byte scales step in
1024s, so the top of the graph is a round number of megabytes. Rounding a byte
rate to a decimally-tidy 2,000,000 gives a ceiling that displays as "1.9 MB/s",
which is worse than not rounding at all.

Both are pure functions of the data. A stateful decay would make a graph's
appearance depend on the history of its own ceilings, so the same widget fed the
same numbers could render differently on two machines -- exactly what M4's
shareable documents must not do.

**Percentages never auto-scale.** 5% has to look like 5%, not like a full bar
because nothing higher happened to be in the window. This is the same principle
as the floor, and it is enforced by a test.

## Shapes that claim a whole

The donut, arc and bar all say "this much of that much", so they refuse metrics
with no declared maximum. A ring three percent full when throughput is 3 MB/s is
not a rough approximation; it implies a ceiling that does not exist. The editor
refuses the binding at the point you make it rather than drawing something
unreadable and leaving you to work out why.

## Width, resolved

M1's default strip was 279pt, nearly all of it two throughput cells each
reserving room for `888 MB/s`. Reserving the worst case is not negotiable -- it is
what keeps the strip from reflowing -- so the fix was to change the shape rather
than the reservation.

Stacking download and upload into one cell reserves that width once instead of
twice, and showing memory as a donut costs 22pt where the number cost 54. The
default is now 188pt *and* includes a live graph. The exact memory figure moved
one click away into the dropdown, which is the glance-then-look rule doing its
job rather than a compromise.

## Direction for later milestones

Recorded here so the layers built now do not foreclose them.

### The panel (built in M6)

The iStat-style dropdown is a dense table of everything. What was built instead:
**you clicked a cell, so the panel opens scoped to that metric.**

```
  +--------------------------------------+
  |  CPU                          42%    |   headline: the number you clicked
  |  ~~~~~~~~/\~~~~~/\_____              |   60s sparkline, same renderer as the strip
  |                                      |
  |  User            28%                 |   three supporting facts, no more
  |  System          14%                 |
  |  Top process     Xcode  (31%)        |
  |                                      |
  |  Memory  61%   Disk  12 MB/s    >    |   the rest, one row, expandable
  +--------------------------------------+
```

Progressive disclosure done properly: the thing you asked about is the whole
panel, and everything else is a row of chips at the bottom.

Two details that make it work. The click position is mapped back to a cell using
frames the composer records, so "which one did you click" has an answer at all.
And the rows come from `MetricDescriptor.group` in declaration order, so a source
added later appears with no panel code touched -- and the headline is the metric
its author put first rather than whichever sorted earliest.

### "Is this normal?" (M6+, idea not commitment)

Every monitor shows you a number. Almost none tell you whether the number is
*unusual*. With an hour of history already in the ring buffers and a cheap
rolling baseline on disk, the panel could say:

> 42% -- about 3x your usual for a Tuesday morning.

That is the single most useful sentence a stats app could show a non-expert, and
it costs almost nothing on top of what M1 already stores. Worth prototyping
before committing: a baseline that is wrong is worse than no baseline.

### The editor (built in M3)

Direct manipulation, not a preferences table. Three rules it actually follows:

**The preview is the real thing.** The strip at the top is drawn by the same
`StripComposer` the menu bar uses, with live data. A preview that is a second
implementation can drift, and a drifted preview is worse than none -- it lies
with confidence.

**Every change is immediate.** No OK button. The preview above is the feedback;
an editor you have to commit to before seeing the result is a form, not direct
manipulation.

**Refusals explain themselves.** A donut cannot be bound to network throughput,
because a ring implies a maximum that throughput has none of. The style is not
offered, *and* the inspector says why -- "why can't I pick this" is the question
a greyed-out control always provokes and never answers.

The metric picker is grouped by `MetricDescriptor.group` and lists only what this
Mac actually has, from the same live descriptors that M4's import will use to
report what a shared widget cannot show. One source of truth for "what is
available", used at both ends.

### Behind windows means below windows, not on the desktop

The desktop widget's "behind other windows" setting does not use the desktop
window level, despite that being what it sounds like. macOS composites its own
full-screen surfaces there -- Finder's desktop and WindowManager's -- and anything
a third-party app puts at that level sits behind them forever.

One level below normal is what the setting actually means: above the wallpaper and
the icons, below every app window. The distinction is invisible until you try it,
which is why the ordering is asserted in a test rather than left as a constant
someone might later "correct".

### Several items, not one strip

Each widget is its own `NSStatusItem`. macOS assigns menu bar position per item
and lets the user drag them, so separate items are the only way to have CPU on
the left and network by the clock. A single combined strip would be simpler to
manage and would take that away entirely.

The consequence for the editor: re-pointing an existing item at an edited widget
rather than recreating it. macOS remembers position per item, so tearing one down
and building a new one on every keystroke would make a carefully arranged menu
bar jump around while you typed.

### Sharing (built in M4)

**The preview is rendered on the recipient's machine, not shipped with the file.**
A picture of the author's strip shows you their hardware and their numbers. What
you need to know is what *you* would get, which means rendering their widget
against your own live data -- including the gaps where your machines differ.

**Nothing lands unsighted.** The import sheet shows that preview alongside a
plain-language report: which metrics are unavailable, which cells had to be left
out. Turning a silent degradation into an informed choice is the entire reason
the resolution report exists.

**Absent data has one glyph.** A cell with no reading shows an en dash, whatever
its style. Gauges originally drew an empty ring, which is indistinguishable from
a ring reading zero -- so a sensor you do not have looked exactly like a sensor
reporting nothing is happening. Borrowing the text placeholder means somebody who
has learnt what the dash means in one cell knows what it means in all of them.

**The sender's state is not imposed on the recipient.** Whether a widget appears
in your menu bar is your decision, so `isEnabled` is not shared. Identities are
regenerated on import, so the same file imported twice gives two widgets rather
than one silently replacing the other.

**Hand-writable, not just machine-writable.** Every field with an obvious default
may be omitted -- id, schema, enabled state, and every style option. A widget can
legitimately be four lines. A format advertised as readable that can only be
produced by exporting is not really readable.

**Too big is refused, not trimmed.** A file anyone can write can describe a
widget no menu bar could hold -- three hundred cells, a name five thousand
characters long -- and the preview would draw it before anyone had decided
anything. So a file is measured first, at its widest on any Mac, and one past
the limits is refused with the reason. Cutting it to fit would be quieter and
worse: a widget missing its last twenty cells is a different widget from the
one that was sent, and nothing would say so. The editor works to the same
limits, so nothing made here is ever refused somewhere else.

### Updates: Sparkle, kept quiet (built in M7)

**Installing is the part worth a dependency.** The first version of this only
*noticed* updates -- a hundred lines against GitHub's API and a link to the
release page -- on the argument that Sparkle would be the package's first
third-party dependency. What that left to the user was the fiddly half:
downloading, mounting, quitting, replacing a running signed bundle. Sparkle does
that half properly, and verifies every download against an EdDSA key built into
the copy that is running, which a link to a web page never could. It is still
the only dependency, and only the app links it; every library below stays
dependency-free and testable on its own.

**One request a day, and it says so.** The update check is the only thing in the
app that touches the network, which is exactly why the switch for it sits in the
menu next to the thing it governs rather than three levels into a settings
window. Every copy sends the same User-Agent and no system profile, so the
request carries nothing about the Mac asking. The feed is a file on the latest
GitHub release; there is no server on the other end that belongs to this app,
and so nothing that could quietly start collecting.

**Only a release updates itself.** A development build has no feed at all. It is
numbered below every release, so with one it would offer to "update" to the
older published build -- the kind of bug that only shows up on the developer's
own machine, and there teaches them to click through update alerts.

**Found is not the same as shown.** An agent app has no Dock icon and is never
frontmost on its own, so an alert opened mid-afternoon lands behind whatever the
user is doing and sits there unseen. Sparkle's gentle reminders let it show the
alert only when the moment is right -- just after launch, or once the Mac has
been idle. Otherwise the update waits in the menu item's title, which is the
version of the same message that does not interrupt.

## Curation is a design decision, not a data decision

An M4 offers 47 thermal sensors with names like `PMU2 tdev4`, six of them
identical, three reporting -22 °C, and two that are calibration references rather
than temperatures. Showing all of them is not "giving the user everything" -- it
is refusing to make the decision the app exists to make.

The rule this settled on: **aggregate what is portable, expose what is not, and
say which is which.** `thermal.peak` means the same thing on every Mac and is safe
to share. `thermal.sensor.pmu-tdie6` means something only here, sits in an
Advanced group, and produces an explicit warning when a widget using it lands on
another machine.

The same reasoning already governs volumes: `disk.boot.*` is portable,
`disk.volume.backup.*` is not.

## A feature every style must have belongs to none of them

Labels were implemented inside `TextValueRenderer`, so eight other styles ignored
them silently -- setting a caption on a donut reserved no width and drew nothing.
Nothing was broken in any single renderer; the fault was in where the
responsibility lived.

**If something must be true of every cell, the compositor owns it.** Adornments
are now measured and drawn in one place, which makes them consistent by
construction, gives a style added next year the feature for free, and reduces the
number of places that can forget from nine to one.

The same reasoning already applies to width stability, template selection, and
redraw skipping. Anything a renderer *could* decide differently belongs to the
renderer; anything that must be uniform does not.

## Legibility cannot depend on the wallpaper

The system's label colours carry alpha by design -- roughly 85%, 50% and 25%.
Drawn straight onto a translucent popover they blend with whatever is behind the
*window*, so on a saturated desktop every label came out washed-out and tinted
with the wallpaper's hue.

The first fix was to fill an opaque background behind the content. It made the
text readable and caused a worse problem, because **`NSPopover` draws a 13pt
translucent frame around its content**: an opaque rectangle inside that border
left a hard seam with the desktop visible all the way around it.

The fix that works is the other way round. The background stays the popover's own
material, supplied by an `NSVisualEffectView` so the content and the frame are one
continuous surface, and the **ink** is fully opaque -- fixed values per
appearance rather than the system's semi-transparent ones.

Contrast then comes from the colours rather than from covering anything up, and
the panel looks like a native popover instead of a rectangle pasted inside one.

The general rule, learned the expensive way: **do not fight the container.** Two
of the three bugs here came from taking over something AppKit already owned --
the background, and the content view's frame. Stating what the content *is* and
letting the popover size and composite it is both less code and the only version
that survives a relayout.

## Accessibility

Not a late pass; the strip is an image, which means it is invisible to VoiceOver
unless we say otherwise.

- The status item carries an accessibility label built from the same formatted
  values it draws, updated whenever the image is.
- Threshold state is announced as text, because colour alone cannot carry it.
- Increase Contrast drops the label's 55% opacity to full.
- Nothing animates, so Reduce Motion needs no special case -- which is itself a
  design decision, not an accident.

## What this app deliberately does not do

- No always-visible colour. See principle 1.
- No per-cell padding, corner radius, or font pickers. Density and theme are the
  two knobs; everything else is a preset.
- No animated transitions in the menu bar. A number that eases between values is
  a number you cannot read.
- No "top processes" in the strip. It is a list, and lists belong in the panel.

## Naming

**Caliper.** Named for the instrument: precise, unglamorous, picked up to take a
reading and put down again. It carries the engineering care the app is built with
without claiming to be a dashboard.

The name is baked into the document format -- `caliper.widget/1`,
`caliper.layout/1`, the `.caliperwidget` extension and the
`de.alhaidari.caliper.widget` type identifier -- which is why it was worth
settling before the format went anywhere.

## The icon

An arc gauge, the same shape `ArcGaugeRenderer` draws in the menu bar, generated
in code rather than stored as an asset so the two cannot drift apart.

Deep slate rather than a saturated colour, because an icon shouting before the
app has drawn a pixel would contradict everything the strip does. The single
accent is the **leading tip of the reading**, which is the same rule as the strip:
colour marks the signal and nothing else. An earlier version laid an orange needle
across the arc, and it muddied precisely the spot the eye lands on.

It has to survive 16 points, which rules out text, fine lines, and second ideas.
A thick open ring keeps a recognisable silhouette at every size, which is the only
test that matters.

## Structure

Five libraries and the app, each independently testable, with dependencies
pointing one way.

```
SensorKit     reads hardware. No UI, no scheduling, no timers.
              CPU, cores, memory, network, disks, GPU, temperatures,
              fans, power, battery, and the clock.
    |
MetricBus     the process's single timer + history ring buffers.
    |
RenderKit     pure drawing. Deliberately does NOT depend on MetricBus,
    |         so every visual style is testable against handwritten input.
LayoutEngine  composes cells into the one image a status item displays.
    |
SchemaKit     the document format, persistence, and resolving a document
    |         against whatever hardware is actually present.
CaliperApp    status items, the SwiftUI editor, visibility suspension.
              Tested too: menus, lifecycle, alerts, import and occlusion
              run against real status items and windows.
```

The editor is SwiftUI; the menu bar strip stays AppKit. The reason SwiftUI was
ruled out in M0 was per-second menu bar redraws, and that argument simply does
not apply to a window that is open for a few minutes a year and costs nothing
when closed.

Three decisions that cannot be retrofitted, so they are in from M0:

**One timer for the whole process.** Not one per widget or per source. A single
`DispatchSourceTimer` with 10% leeway, so the kernel coalesces our wakeups with
the rest of the system's. This is the largest battery win available to a menu bar
app, and it is only available if there is exactly one timer to coalesce.

**Refcounted sources.** A source is activated when its first subscriber appears
and deactivated when its last one leaves. Nothing bound to a visible cell means
the hardware is never touched.

**Suspension.** Display sleep, system sleep, and screen lock stop the timer
outright. Resuming re-primes each source's delta state, so the first reading
after wake covers the last second rather than the last eight hours.

A surface nobody can see stops too, one at a time: a menu bar hidden by a
full-screen app, a status item pushed behind the notch, a desktop widget buried
under windows. Each asks the window server whether any pixel of its own window is
on screen, and after three seconds out of sight drops its subscription -- which
stops the hardware behind it being read, not just the drawing. It comes back the
moment it is in view. Alerts hold their own subscription, so a threshold crossed
during a film is still noticed. On a Mac with more than one display, status items
never suspend: macOS shows each one in every display's menu bar, from a single
window, so a full-screen app hiding that window says nothing about the copies.

Two things M1 added to that foundation:

**The bus times each source.** Rate metrics divide a byte delta by an interval,
and the interval is not 1.0 seconds -- the timer carries deliberate leeway,
sources run at different cadences, and a resumed timer does not land on the beat.
The bus measures each source's own interval and passes it in `SampleContext`, so
no source reads a clock and they all agree what "per second" means.

**Metrics can go stale.** A volume is ejected, a VPN drops, a sensor disappears
on an OS update. Left alone the last value would sit frozen in the menu bar
looking perfectly plausible, which is the worst failure available to a monitoring
tool. The bus drops any metric that has not reported within three of its own
intervals, and the cell falls back to a placeholder.

### The clock is a sensor

It would be simpler for the renderer to call `Date()` when asked to draw, and it
would be broken: a widget containing only a clock would subscribe to nothing, the
bus would deliver no snapshots, nothing would ask it to redraw, and the clock
would freeze at the second it was created. As a source it keeps the shared timer
alive like any other metric, and stops when the screen locks.

Sampled once a second, but because the redraw check compares *rendered output*, a
clock showing only hours and minutes is rasterised once a minute.

### Not WidgetKit

Desktop widgets are borderless AppKit panels drawn by the same `StripComposer`,
not WidgetKit. That API is timeline-based and budgeted -- it cannot update every
second -- and its extension is sandboxed away from the private sensor interfaces
M5 depends on. A live CPU graph is not something it can express. The cost of one
permanently on screen is +1.9 MB and +0.009% CPU; the SwiftUI equivalent would
have been +20 MB, paid at launch rather than on demand.

### Sharing is the one door in

Sharing is the one feature built to accept files from other people, and before
`WidgetLimits` a 53 KB file composed a 103 MB bitmap for a single menu bar item.
Every limit is checked before anything is drawn, the editor uses the same ranges,
and width is judged at its widest on any Mac -- before the recipient's hardware is
known -- so a file is accepted or refused the same way everywhere.

## Measuring the cost

The published numbers are in the documentation's *What it costs* page. How they
came to be trusted is here.

**Every CPU figure published before this was wrong by a factor of 41.67.**
`proc_pid_rusage` reports `ri_user_time` and `ri_system_time` in *mach absolute
time units*, not nanoseconds, despite the names. Dividing by a billion is
plausible, silent, and under-reports by the timebase ratio -- 125/3 on Apple
Silicon. The app was never at 0.02%; it has always been around 0.7%.

Confirmed three ways: a busy loop reads exactly 100.0% of a core once converted
and 2.4% before; `ps` cputime deltas on the running app give 1.0%; and the
corrected probe agrees. `ps %cpu` disagrees at 0.1% and is the outlier -- it is a
decaying average over process lifetime, not a current reading.

### Where it goes

A status item that never redraws costs 0.04%. One redrawing every second costs
0.36%. Our own compose is 57 microseconds of that, so the remaining ~3ms per
redraw is AppKit's `button.image` assignment and the compositing behind it.

**The budget stays at 0.3% and is currently failing.** A budget moved to match
the measurement is not a budget. The concrete route back under it is to stop
handing AppKit a new `NSImage` every second and draw into a custom `NSView`
instead, which skips image creation, wrapping and invalidation entirely. That is
a real change to `StatusItemController` and has not been made yet.

**Opening the editor costs about 20 MB, and does not give it back.** Measured
across one open-and-close cycle: 12.7 MB before, 33.5 MB with the window open,
32.8 MB after closing it *and* releasing the entire view hierarchy. Only 0.7 MB
of that was ever reclaimable; the rest is SwiftUI's frameworks, and dyld cannot
unload a framework once it is loaded.

That is recorded as a **second** budget rather than by relaxing the first. The
number worth defending for a menu bar agent is what it costs sitting there all
day, and most sessions never open the editor. Raising the resident budget to make
this pass would have thrown that figure away. Eliminating the 20 MB entirely means
either building the editor in AppKit or running it as a separate process that
exits when closed. Both are real options if the number matters; neither is free.

Adding a live graph did not move the numbers. A scrolling plot redraws far more
often than a number does, but the redraw check compares *pixel rows*, not values,
so a flat trace costs a hash and nothing else.

## Notes on the platform

Temperatures and power on Apple Silicon require `IOHIDEventSystemClient` and
`IOReport`, and fan speeds require the `AppleSMC` key table -- all undocumented
and blocked by the App Store sandbox.
Distribution is therefore Developer ID + notarisation. That tier lands at M5,
behind a capability probe, so a future macOS that changes those interfaces
degrades the app to "sensor unavailable" rather than breaking it.

Each private source probes at construction and publishes **no descriptors at
all** when its interface is missing. A macOS release that moves these symbols
removes the metrics from the picker rather than filling the menu bar with
permanent dashes.

| Source | Interface | Status |
|---|---|---|
| GPU utilisation and memory | `IOAccelerator` registry property | Ordinary IOKit, verified |
| Temperatures | `IOHIDEventSystemClient` | Private, verified (47 sensors) |
| Power in watts | `IOReport` | Private, verified |
| Battery | `IOPowerSources` + registry | Fully public, verified |
| Fan speeds | `AppleSMC` key table | Private, verified (2 fans, M4 Max Mac Studio) |

Fans are the one sensor that does not come from the HID event system. They were
written that way originally, on a fanless MacBook Air, and an M4 Max Mac Studio
showed why that could never have worked: its HID vendor page publishes 39
temperature sensors and nothing at all at the fan usage, or at any usage across
the full 0...255 sweep. The capability probe did its job and offered no fans --
on a machine with two of them spinning.

They come from the SMC instead, which reports both. One trap is worth knowing if
you touch that code: this endpoint wants its four-character keys **byte
reversed**. Sent the obvious way, every key returns `kSMCKeyNotFound`, which
looks exactly like an SMC with no keys rather than a byte-order bug.

Read-only, permanently. Only the read and key-info commands are implemented, and
the write command deliberately is not. Writing SMC keys can drive fans past their
rated speed or stop them; no menu bar app has any business doing that.

## Things found by building, not by reading

**Aggregate CPU tick counters update lazily.** Found in M0: the kernel's
aggregate CPU tick counters update *lazily* on Apple Silicon. A caller that stays
on-core can read an unchanged snapshot hundreds of milliseconds apart, then see a
double-sized delta on the next read. Measured on an M4, reads taken while
busy-looping return a zero delta roughly a third of the time. `CPULoadSource`
emits nothing on those ticks rather than reporting a false 0%, and because the
following delta covers the full elapsed period the percentage stays accurate.

**Efficiency cores come first.** `host_processor_info` reports cores
least-performant first, which is the reverse of how `hw.perflevelN` numbers them
(`perflevel0` is the *most* performant). Verified by loading the machine at
different QoS classes and watching which indices moved: user-interactive work
landed on 6-9, background on 0-3, on a 4P/6E M4. `CPUCoreSource` derives the
mapping from the sysctls rather than hardcoding it, and a test asserts the
ordering so a future macOS flipping it fails loudly instead of silently swapping
the P and E labels.

**There is no single boot volume any more.** Since Big Sur, `/` is the read-only
signed system volume and `/System/Volumes/Data` is the writable one, marked
don't-browse. The "Macintosh HD" Finder shows is a synthesised view of that
firmlinked pair, so the obvious filter -- local, browsable, writable -- matches
neither and finds no startup disk at all. `MNT_ROOTFS` identifies it directly.

**`proc_pid_rusage` takes a pointer to the struct, not to a pointer.** Its third
parameter is declared `rusage_info_t *`, and `rusage_info_t` is itself `void *`,
so passing `&someLocalPointer` type-checks and is completely wrong -- the kernel
writes ~200 bytes into an 8-byte stack slot and the process dies in
`__stack_chk_fail`. Verified the fix against a C reference implementation.

**Quantising a byte scale in decimal makes the axis unreadable.** A graph
ceiling rounded to a "nice" 2,000,000 bytes per second *displays* as 1.9 MB/s --
a number nobody would ever choose, which defeats the entire point of rounding it.
Byte-denominated scales quantise in 1024s so the top of the graph is a round
number of megabytes; everything else quantises in 1000s.

**`getmntinfo` returns a static buffer.** Two concurrent callers silently corrupt
each other's results. Found when the parallel test runner called the volume scan
from several tests at once and produced a Mac with no boot volume. Being
queue-confined would have made it safe in production, but a function that is only
safe from one specific call site is a trap for whoever calls it next -- so it now
uses the reentrant `getmntinfo_r_np` and simply is not a hazard.

**A fixed-width reservation has to be derived from what is *shown*, not from what
is stored.** Memory used is declared `bounded(0, 17_179_869_184)` on a 16 GB Mac,
and the width came from that raw maximum -- reserving room for
`88888888888.8 MB` in order to display `11.9 GB`. Disk free was worse, at twelve
digits. But an auto-scaled value never leaves its unit until it reaches the
radix, so the mantissa is bounded by 1024 however large the underlying quantity
is: four digits, not eleven. That also fixed a latent overflow in the other
direction, where unbounded rates reserved three digits and `1023 MB/s` did not
fit.

**`strftime` on Darwin ignores `tm_gmtoff` and `tm_zone`.** With the offset set
to Tokyo's +32400 it still printed the *process* zone for `%z` and "UTC" for
`%Z`. The only other lever is the `TZ` environment variable, which is global
process state and not something a menu bar cell should reach for -- so those two
specifiers are resolved and substituted before the string reaches `strftime`,
walking the format so an escaped `%%z` is left alone.

**Sampling a few dates does not cover the combinations.** The clock's width probe
originally tried five days per month, and missed "Wednesday 25 September" --
September 2024 has no Wednesday on any of them -- which is the widest thing
`EEEE d MMMM` can print. It walks every day of a leap year now. It also compared
candidates by *character count*, which is not width in a proportional face; the
renderer measures them in the font it will actually draw with.

**`proc_pid_rusage` reports CPU in mach units, not nanoseconds.** The field is
called `ri_user_time` and dividing it by a billion gives a number that looks
entirely reasonable and is 41.67x too small on Apple Silicon. It went unnoticed
through six milestones because the results were plausible -- an efficient menu
bar app *should* read low. It was caught by ranking processes: a busy loop
appeared at 2% when it had to be near 100%. Two independent cross-checks settled
it. Both the benchmark and the process sampler now convert through
`mach_timebase_info`, and a test spins a busy loop and asserts the reading comes
out near one core.

**`kCGDesktopIconWindowLevel` makes a window nobody can see.** It is the obvious
level for "behind other windows" and it is wrong: on this era of macOS both
WindowManager and Finder composite *full-screen* windows at exactly that level,
so a third-party window placed there is permanently buried behind them. Measured
front-to-back at that level, ours was last of four. Ordering forward does not
help, because those surfaces belong to the window server rather than to any app.
The level is one below normal instead -- above every desktop surface, below every
ordinary window -- and a test pins that relationship rather than the number.

**Do not fight the container.** Three bugs in the detail panel, all from taking
over something `NSPopover` already owned. Filling an opaque background left a
seam, because the popover draws a 13pt translucent frame that an opaque rectangle
cannot match -- the content now shares the frame's material and the *ink* is
opaque instead. Assigning `view.frame` fought the popover's own sizing, so the
first paint looked right and the next relayout left the panel inset. And laying
out against a hardcoded 300pt meant everything inside was positioned for a width
the view might not have.

**Re-subscribing on every tick thrashes the sources.** The panel rebuilt its bus
subscription on each snapshot, so once a second a source's refcount could drop to
zero and back -- discarding the delta state that tick-counter and rate sources
depend on. It now rebuilds only when the metric set changes.

**A verification tool that arranges favourable conditions is worse than none.**
The panel dump filled an opaque background before drawing, so it tested a
situation that never occurs -- and reported the panel as fine while it was, in
reality, illegible over a coloured wallpaper. It converted an unknown into a
false certainty, which is worse than having no tool at all. It now renders over a
deliberately hostile background, in both appearances, so anything showing through
is visible as the bug it is.

**Two functions holding the same magic numbers will drift.** The panel's
`height(rows:)` added up its own copy of the eight constants that `draw()` walked
through. They agreed by luck and left 12pt under the footer where 16 were
intended. One layout pass now produces the geometry and the height is whatever
that pass needed.

**Iterating a dictionary is not an order.** `availableMetrics()` flat-mapped over
a dictionary of sources, so the sequence depended on hashing. The detail panel
headlines a group with its first metric, and opened the CPU panel titled
"Efficiency Cores" -- correct code, nondeterministic data. Registration order is
now preserved explicitly, and a test asserts it across twenty calls.

**A view with no window cannot be asked to cache its display.** The panel dump
produced a blank image until it drew itself into a bitmap directly. It works at
all only because the panel is AppKit and draws itself -- the same capture path
failed completely against the SwiftUI editor.

**IOReport is not in IOKit.** Its symbols live in `/usr/lib/libIOReport.dylib`,
which is inside the dyld shared cache and therefore does not exist as a file --
`ls` finds nothing while `dlopen` succeeds.

**One IOReport group returns three different units at once.** A single "Energy
Model" sample on an M4 gives CPU energy in mJ, GPU energy in nJ, and PCIe energy
in uJ. Assuming any one of them is wrong by a factor of a million, so the label is
read per channel. The M4 conveniently publishes GPU energy twice, in mJ and nJ,
which is a free cross-check.

**A wrong HID field constant returns zero, not an error.** The temperature value
is at `IOHIDEventFieldBase(type)`; using `base | 1` returns a completely plausible
0.00 for all 47 sensors. Silent, uniform, and easy to mistake for "this Mac has no
temperature data".

**Reading 47 sensors costs 44 ms of wall time and 1.6 ms of CPU.** The call is
96% blocking IPC. That first looked like a CPU disaster and is not one -- but it
is a *queue occupancy* disaster, because every source shares one serial queue, so
44 ms in there is 44 ms during which nothing else is sampled. Sensors are now read
round-robin, six per tick, which cuts queue time to about 4.5 ms per five seconds.
Individual sensors refresh every forty seconds or so, which for a quantity that
moves over minutes costs nothing real.

**A per-source benchmark that reports one number lies.** Judged on wall time the
thermal source looks ruinous; on CPU time it looks free. Both matter, for
different reasons, so `micro` now reports both -- and warns that back-to-back
sampling overstates kernel-facing sources. `PowerSource` measures 1.2 ms there and
costs about 0.15 ms in the running app.

**An empty gauge and a gauge reading zero are the same picture.** Text cells show
a dash when a metric is unavailable, which is unmistakable; a ring had no
equivalent, so a sensor this Mac does not have looked exactly like a sensor
reporting that nothing is happening. Found by rendering a widget written for
other hardware. Dashing the track was the first attempt and is far too quiet at
sixteen points -- gauges now draw the *same en dash* the text cells use, so the
app has one glyph for "no reading" across every style.

**Dragging an item right needs different arithmetic than dragging it left.**
Dropping a chip onto another means "put it here", so the dragged cell takes the
target's slot. Removing it first shifts the target one place left, so a rightward
drag has to insert *after* the target and a leftward drag *at* it. One rule for
both looks correct dragging leftwards and silently drops the cell one place short
every time you drag rightwards -- caught by the test written to check exactly
that, which the first fix also failed.

**SwiftUI cannot be screenshotted by any AppKit view-capture path.**
`cacheDisplay`, `dataWithPDF`, and rendering the CALayer tree all fail to capture
lists, scroll views, and their contents, because those are composited from
separate backing stores. The editor's `--dump-editor` flag captures the live
preview strip and the window chrome and nothing else. Kept anyway, since the
strip is the part unique to this app; the rest of the editor has to be reviewed
by opening it.

**Dynamic colours need an appearance to resolve against.** The strip is rendered
from a bus callback, not inside a draw cycle, so nothing has established a
current appearance and `NSColor.labelColor` resolves to the wrong side of
light/dark. Invisible while the strip is a template image, because AppKit tints
those itself -- and then suddenly visible the first time a cell alerts, when the
quiet cells are drawn white on a white menu bar. Fixed by composing inside
`performAsCurrentDrawingAppearance`.

## Milestones

- **M0** -- skeleton, CPU, benchmark harness, budget *(done)*
- **M1** -- memory, disk, network, per-core CPU *(done)*
- **M2** -- graph / gauge / bar / matrix renderers *(done)*
- **M3** -- widget editor, multiple menu bar items, document format *(done)*
- **M4** -- sharing: export, import, capability report *(done)*
- **M5** -- GPU, temperatures, fans, power *(done)*
- **M6** -- desktop widgets, detail panel, threshold alerts *(done)*
- **M7** -- Developer ID signing, notarisation, Sparkle updates, launch at
  login, CI *(done)*
