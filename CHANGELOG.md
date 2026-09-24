# Changelog

Everything notable that changed in the app.

Each version's section below is what the release workflow publishes: it becomes
the GitHub release's description and the release notes Caliper shows in its own
update window, so it is written for someone deciding whether to install it. A
version with no section here is refused before anything is built -- to release,
rename `[Unreleased]` to the version and date it.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
the versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-09-24

The first release.

### Added

- **Widgets in the menu bar**, each its own item that macOS lets you drag into
  place: CPU, per-core load, memory, network, disk capacity and activity, GPU,
  temperatures, power, battery, fans, and a clock.
- **Cell styles** -- text, graphs, gauges, bars and a core matrix -- with
  captions, icons, spacers and dividers, arranged in an editor with a live
  preview.
- **A detail panel** for the cell you click, **desktop widgets** that sit on the
  wallpaper, and **threshold alerts** that colour the strip and send a
  notification once a breach has lasted 30 seconds.
- **Sharing**: export a widget as a `.caliperwidget` file, and open one to see
  what it needs and whether this Mac has it before adding it. A file too big to
  be a widget -- too many cells, a name or caption too long, wider than a menu
  bar -- is refused with the reason, before anything is drawn from it.
- **Launch at Login** and **About Caliper**, from the status item menu.
- **VoiceOver** reads every menu bar item, desktop widget and detail panel, and
  alerts are underlined -- dashed for a warning, solid when critical -- so they
  never depend on telling orange from red.
- **Ready for translation**: every string is in a catalogue the tests check
  against the source, so a new language is a directory to add.
- **Updates** through Sparkle: one check a day, which the menu switches off, and
  every download verified against a key built into the copy you are running.
  That check is the only thing that leaves your Mac; the Privacy page of the
  documentation, linked from About Caliper, says exactly what it sends.
- Light on the Mac it measures: one timer for the whole app, hardware read only
  for cells that are showing, and sampling suspended while the display sleeps
  or the screen is locked -- and, one item at a time, while a full-screen app
  hides the menu bar of a single-display Mac, the notch hides an item, or
  windows cover a desktop widget. Alerts keep watching throughout.

[Unreleased]: https://github.com/hossainalhaidari/caliper/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/hossainalhaidari/caliper/releases/tag/v0.1.0
