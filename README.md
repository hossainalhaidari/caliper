<p align="center">
  <img src="Website/src/assets/mark.svg" width="128" height="128" alt="Caliper app icon">
</p>

<h1 align="center">Caliper</h1>

<p align="center">
  A macOS menu bar system monitor — a calm instrument that stays quiet until a number crosses a line you set.
</p>

<p align="center">
  <sub>Named for the instrument: something precise you pick up, take a reading with, and put down again.</sub>
</p>

<p align="center">
  <a href="https://hossainalhaidari.github.io/caliper/">Website</a> ·
  <a href="https://hossainalhaidari.github.io/caliper/docs/">Documentation</a> ·
  <a href="https://github.com/hossainalhaidari/caliper/releases">Download</a>
</p>

## Install

Download the latest disk image from the [releases page](https://github.com/hossainalhaidari/caliper/releases)
— macOS 14 or later — or build it yourself:

```bash
make app     # build, bundle and launch build/Caliper.app
make test    # run the test suite
make help    # everything else
```

Caliper has no Dock icon or window of its own — look for its widget in the menu bar, and right-click
it for the menu. Everything else, from building widgets to privacy and uninstalling, is in the
[documentation](https://hossainalhaidari.github.io/caliper/docs/). The design and the reasoning
behind it are in [ARCHITECTURE.md](ARCHITECTURE.md); how a change is held together is in
[CONTRIBUTING.md](CONTRIBUTING.md).

## License

Caliper is released under the [MIT License](LICENSE). Sparkle, which it embeds for updates, is
MIT-licensed too; both licences ship inside the app, in `Contents/Resources/Licenses`.

**Caliper is provided "as is", without warranty of any kind**, express or implied, including but not
limited to the warranties of merchantability, fitness for a particular purpose and non-infringement.
In no event shall the authors be liable for any claim, damages or other liability arising from, out
of or in connection with the software or its use. See [Transparency](https://hossainalhaidari.github.io/caliper/docs/transparency/)
for how the project was built.
