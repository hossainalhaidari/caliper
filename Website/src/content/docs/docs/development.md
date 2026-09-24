---
title: Development
description: Building and testing Caliper, the make targets, the tools that render what the menu bar shows, and what a change is held to.
---

Everything builds with Xcode's toolchain on macOS 14 or later, and nothing else. The one third-party
dependency, Sparkle, is fetched by Swift Package Manager and linked by the app alone.

## Make targets

`make help` lists them. The ones used most:

| Target | |
|---|---|
| `make run` | Build and run from source with `swift run` — the fastest loop. ^C to quit |
| `make app` | Assemble `build/Caliper.app`, signed, and launch it |
| `make install` | Copy the bundled app to `/Applications` |
| `make stop` | Quit any running Caliper |
| `make test` | The whole test suite, including the app layer |
| `make bench` | Sampler and render costs |
| `make soak`, `make watch` | The pipeline, or a running `Caliper.app`, against the budget — see [What it costs](../performance/#measuring-it-yourself) |
| `make sensors` | Every metric this Mac offers, with a live value |
| `make preview` | Render the live strip to `build/strip.png` |
| `make gallery` | Render every cell style to `build/gallery.png` |
| `make icon` | Redraw the app icon from code into `build/AppIcon.iconset` |
| `make docs` | Build this website and serve it — see `Website/README.md` |
| `make clean` | Remove all build products |

## Layout

```
Sources/
  SensorKit      reads hardware. No UI, no scheduling, no timers
  MetricBus      the app's single timer, and the history ring buffers
  RenderKit      pure drawing, testable against handwritten values
  LayoutEngine   composes cells into the one image a status item shows
  SchemaKit      the widget format, persistence, and resolving a widget against this Mac
  CaliperApp     status items, the editor, the panel, desktop widgets, alerts
  CaliperBench   caliper-bench: benchmarks, previews, the gallery, the icon
Tests/           one target per library, plus the app layer and localisation
Resources/       Info.plist and the en.lproj string catalogue
Tools/           bundle, sign, package and update-key scripts
Website/         this site
```

Dependencies point one way, down that list. [ARCHITECTURE.md](https://github.com/hossainalhaidari/caliper/blob/main/ARCHITECTURE.md)
is the design language and the reasoning behind the structure.

## Tests

```bash
make test
```

`CaliperAppTests` creates real status items and windows, so it needs a logged-in session. It runs on
GitHub's macOS runners, and on your own Mac a blank item may flicker in the menu bar while it does.

## Seeing the strip

The menu bar cannot be captured without Screen Recording permission, so `caliper-bench` renders the
real strip — the same composer, the same data — to a PNG, in both appearances:

```bash
make preview     # the live strip, real data, into build/strip.png
make gallery     # every style, synthetic data, into build/gallery.png
```

`gallery` uses synthetic data because a few seconds of sampling cannot show a graph properly.

A bundled build can also draw its own windows:

```bash
build/Caliper.app/Contents/MacOS/Caliper --dump-panel panel.png CPU
build/Caliper.app/Contents/MacOS/Caliper --dump-editor editor.png
```

`--dump-panel` renders the [detail panel](../panel/) for a group over a deliberately busy background.
`--dump-editor` captures the editor's preview strip and window chrome only — SwiftUI's lists cannot
be captured this way, so the rest of the editor has to be reviewed by opening it.

## What a change is held to

[CONTRIBUTING.md](https://github.com/hossainalhaidari/caliper/blob/main/CONTRIBUTING.md) has the full
list. In short:

- **Tests** with every fix and every new behaviour, waiting on deadlines rather than fixed sleeps.
- **The budget.** A change to sampling, the bus, rendering or the status item says what it does to the
  [published numbers](../performance/).
- **Swift 6 language mode**, with data-race checking on for every target.
- **Every string a person reads is localised** — see [Translating](../translating/).
- **The widget format is API.** Metric ids and style names are never renamed.

## Continuous integration

`.github/workflows/ci.yml` builds, runs the tests, and runs `make bench` on every push to `main` and
every pull request that touches the app. `.github/workflows/website.yml` publishes this site.
