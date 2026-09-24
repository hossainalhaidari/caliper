# Caliper — Website

The homepage and documentation for Caliper, built with [Astro](https://astro.build) and
[Starlight](https://starlight.astro.build).

`astro build` emits plain HTML, CSS and JS into `dist/` — **no server-side rendering, no backend, no
runtime dependencies**. The docs search is [Pagefind](https://pagefind.app), a static index queried
in the browser, so the whole site works on any file host: GitHub Pages, Netlify, Cloudflare Pages, S3,
or a directory served by nginx.

## Commands

From the repository root, via the `Makefile` — these install dependencies on first use:

```bash
make docs        # build, then serve it and open a browser
make docs-stop   # stop that server
make docs-dev    # hot-reloading server, for editing the site itself
make docs-build  # static build only, into Website/dist
```

`make docs` serves on port 4321; override with `make docs DOCS_PORT=4400`. It hands the prompt back
with the server running in the background, because `astro preview` daemonises — hence `make docs-stop`.
`make docs-dev` blocks instead, so stop it with ^C. `make clean` removes `Website/dist` along with the
Swift build directories.

Or from this directory, directly:

```bash
npm install
npm run dev      # dev server with hot reload
npm run build    # static build into dist/
npm run preview  # serve dist/ locally, exactly as it will be deployed
npm run check    # type-check .astro and .ts
```

## Layout

```
astro.config.mjs          site config, Starlight setup, docs sidebar
src/
  pages/index.astro       the single-page homepage — owns "/"
  components/
    MenuBarMock.astro     the drawn desktop: menu bar strip, detail panel, desktop widget
  content/
    docs/docs/*.md(x)     every documentation page -> /docs/<slug>/
    docs/404.md           the not-found page
    i18n/en.json          UI string overrides
  styles/
    theme.css             design tokens, shared by the homepage and the docs
    landing.css           the homepage
    docs.css              Starlight theming
  lib/url.ts              base-aware internal links
  assets/mark.svg         the app icon, redrawn as vector
public/favicon.svg        the same mark, served as the favicon
```

**Documentation pages live in `src/content/docs/docs/`.** The extra level is deliberate: Starlight maps
`src/content/docs/<path>` onto `/<path>`, so nesting the content one folder deep is what puts the docs
under `/docs/` and leaves `/` free for the hand-written homepage.

To add a page, drop a Markdown file in that folder with `title` and `description` frontmatter, then
add it to the `sidebar` in `astro.config.mjs`.

## The homepage's illustration

`MenuBarMock.astro` is not a screenshot. The desktop, the menu bar, the widget, the detail panel and
the desktop widget are real elements styled with CSS, sized in container-query units so everything
scales with the frame. That keeps it sharp at any size and lets it follow the page's light and dark
themes.

It is also live, in the app's own terms: one timer, once a second, stopped while the tab is hidden
and never started for a reader who prefers reduced motion. The graph is always 0 to 100, the rates
scale in 1024s, and the switcher underneath pushes the CPU reading past the default widget's
thresholds (70 and 90) to show the orange and red, and the dashed and solid underlines.

The strip is the widget a fresh install starts with, `SchemaKit/DefaultLayout.swift`. If that
changes, change the cells here to match; their geometry is in the `strip` section of
`src/styles/landing.css`.

## The icon

`src/assets/mark.svg` is the app icon, redrawn by hand from `Sources/CaliperBench/IconForge.swift`:
the same superellipse, gradient and arc, with the viewBox cropped to the plate so it is not lost in
IconForge's grid margin at favicon size. Nothing generates it, so a change to IconForge needs the
same change here — and in `public/favicon.svg`, which is a copy.

## Deploying

`.github/workflows/website.yml` builds this directory and publishes it to GitHub Pages on every push
to `main` that touches it. The site is a project site, under the repository's name:

```js
site: 'https://hossainalhaidari.github.io',
base: '/caliper',
```

Every internal link on the hand-written pages goes through `src/lib/url.ts`, and Starlight handles its
own, so `base` does almost all of the work. Two places cannot route through a helper and have the
prefix written out:

- the `hero.actions` links in `src/content/docs/404.md` (frontmatter, not code);
- the URL that `make docs` echoes, in the repository root `Makefile`.

The app links here too — the Privacy link in `Sources/CaliperApp/AboutPanel.swift`, and the issue
template chooser in `.github/ISSUE_TEMPLATE/config.yml` — so moving the site means moving those.

**Moving it to a domain of its own** means setting `site` to that domain, removing `base`, adding a
`public/CNAME` with the domain in it, setting the same domain in the repository's Pages settings, and
taking `/caliper` out of the two hand-written places above.

Pages itself is turned on once, outside the workflow: *Settings ▸ Pages ▸ Source: GitHub Actions*.

## Known build warning

```
[WARN] [build] Could not render `/404` from route `/[...slug]` as it conflicts with
                higher priority route `/404`.
```

That one is expected and harmless. Starlight injects a dedicated `/404` route and also enumerates
every docs entry through its catch-all; the dedicated route wins, which is the one we want, and
`dist/404.html` is correct. It is the price of having a custom 404 page rather than the default.

## Checking links after an edit

The documentation cross-references itself, including deep links to specific headings. After a
restructure, it is worth resolving every internal `href` in `dist/**/*.html` against `dist/`, and
every `#fragment` against the target page's real heading IDs. Both are a short walk over the built
files; there is no dependency to install.
