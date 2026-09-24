# Contributing

Thank you for looking. Caliper is small on purpose, and most of what makes it
work is a handful of rules held everywhere, so this file is mostly those rules.
[ARCHITECTURE.md](ARCHITECTURE.md) is what the app should look and feel like,
and how it is built; the [documentation](https://hossainalhaidari.github.io/caliper/docs/)
is how it works and what it costs.

## Reporting a problem

Use the issue templates. The first thing any report needs is the version and
build from **About Caliper**, the Mac model and chip, and the macOS version.

A sensor that is missing or reads wrong has its own template, because those
readings come from undocumented interfaces that a macOS update can move. Caliper
sends no telemetry and no crash reports -- a choice, not an oversight -- so an
issue is the only way anyone learns that an update broke a sensor. The output of
`make sensors` says what this Mac offers and is worth more than any description.

## Building

Xcode's toolchain on macOS 14 or later, nothing else:

```bash
make test        # everything, including the app layer
make app         # build/Caliper.app, launched
make help        # the rest
```

`CaliperAppTests` creates real status items and windows, so it needs a logged-in
session. It runs on GitHub's macOS runners, and on your Mac a blank item may
flicker in the menu bar while it does.

## What a change is held to

**Tests.** A fix comes with the test that would have caught it, and a new
behaviour with the tests that say what it is. Tests use Swift Testing, and wait
for asynchronous work with a deadline rather than a fixed sleep: a loaded CI
runner turns every fixed sleep into a flaky test. Tests never post the real
system-wide notifications -- screen lock, sleep -- that every other app on the
Mac would hear; the monitors take their notification centres as parameters for
that reason.

**The budget.** The documentation publishes what the app costs, and a change to
sampling, the bus, rendering or the status item should say what it does to
those numbers. `make bench` gives the sampler and render costs; `make watch`
measures a running `Caliper.app`. A budget is not moved to fit a measurement.

**Swift 6 language mode**, with data-race checking on for every target, and no
warnings in a release build.

**Layers point one way.** SensorKit, MetricBus, RenderKit, LayoutEngine,
SchemaKit, then the app -- see "Structure" in ARCHITECTURE.md. RenderKit in
particular never learns about the bus or the file format.

**Every string a person reads is localized.** `String(localized:comment:)` in
code, a string key in SwiftUI, and an entry in `Resources/en.lproj` --
`Localizable.strings`, or `Localizable.stringsdict` when it counts something.
`LocalizationTests` fails on a string missing from the catalogue and on an entry
nothing uses; `CALIPER_DUMP_STRINGS=1 swift test` writes a regenerated
catalogue to copy from. The comment is for the translator: say what the
arguments are.

**The widget format is API.** Metric ids and style `type` strings are what
shared widgets are written in, so they are never renamed. A newer document must
survive a round trip through an older build. Anything that can arrive in a
shared file is bounded in `WidgetLimits`, and the editor uses the same ranges,
so a new option gets a range there too.

**Comments say why.** What the code does is in the code; the comment is for the
reason it does it that way, and for what went wrong the other way. Match the
density and voice of the file you are in.

## Sending a change

- Branch from `main`, and keep a pull request to one idea.
- Commit messages are lower case, say what changed in the first line, and say
  why in the body.
- Anything a user would notice goes in `CHANGELOG.md` under `[Unreleased]`,
  written for someone deciding whether to install it -- that section becomes the
  release notes shown in the app's update window.
- CI runs the build, the tests and `make bench` on every pull request.

Releases are made from `main` by the release workflow; the documentation's
*Releasing* page covers it.

## The website

The homepage and documentation are in `Website/`, an Astro site with its own
[README](Website/README.md). A change a user would notice changes the page that
describes it, in the same pull request. `make docs-dev` serves it with hot
reload; CI publishes it when `main` changes.

By contributing you agree that your contribution is licensed under the
[MIT License](LICENSE), like the rest of Caliper.
