// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

// Static output: `astro build` writes plain HTML/CSS/JS to ./dist with no server
// component of any kind. Starlight's search is Pagefind, which is a static index
// queried in the browser, so the docs stay searchable on any dumb file host.
export default defineConfig({
  // A project site on GitHub Pages, so everything sits under /caliper/. Moving to a domain of its
  // own means changing `site`, dropping `base`, and adding public/CNAME -- Website/README.md lists
  // the two places that spell the prefix out by hand.
  site: 'https://hossainalhaidari.github.io',
  base: '/caliper',
  trailingSlash: 'always',
  integrations: [
    starlight({
      title: 'Caliper',
      description:
        'A macOS menu bar system monitor: a calm instrument that stays quiet until a number crosses a line you set.',
      // The landing page at src/pages/index.astro owns "/", so Starlight lives
      // under /docs/ -- its content is nested one level inside the collection.
      logo: {
        src: './src/assets/mark.svg',
        alt: 'Caliper',
      },
      customCss: ['./src/styles/theme.css', './src/styles/docs.css'],
      social: [
        {
          icon: 'github',
          label: 'GitHub',
          href: 'https://github.com/hossainalhaidari/caliper',
        },
      ],
      editLink: {
        baseUrl: 'https://github.com/hossainalhaidari/caliper/edit/main/Website/',
      },
      sidebar: [
        {
          label: 'Start here',
          items: [
            { label: 'Overview', slug: 'docs' },
            { label: 'Install and run', slug: 'docs/install' },
            { label: 'Privacy', slug: 'docs/privacy' },
          ],
        },
        {
          label: 'Building a widget',
          items: [
            { label: 'Widgets and the editor', slug: 'docs/editor' },
            { label: 'Cell styles', slug: 'docs/styles' },
            { label: 'Captions, icons and spacing', slug: 'docs/adornments' },
            { label: 'The clock', slug: 'docs/clock' },
          ],
        },
        {
          label: 'Reading it',
          items: [
            { label: 'Alerts', slug: 'docs/alerts' },
            { label: 'The detail panel', slug: 'docs/panel' },
            { label: 'Desktop widgets', slug: 'docs/desktop' },
            { label: 'Accessibility', slug: 'docs/accessibility' },
          ],
        },
        {
          label: 'Sharing',
          items: [
            { label: 'Sharing widgets', slug: 'docs/sharing' },
            { label: 'The widget format', slug: 'docs/format' },
          ],
        },
        {
          label: 'Your Mac',
          items: [
            { label: 'Sensors and metrics', slug: 'docs/sensors' },
            { label: 'What it costs', slug: 'docs/performance' },
            { label: 'Updates and login', slug: 'docs/updates' },
            { label: 'Files and uninstalling', slug: 'docs/files' },
          ],
        },
        {
          label: 'Help',
          items: [
            { label: 'Troubleshooting', slug: 'docs/troubleshooting' },
            { label: 'Known gaps', slug: 'docs/known-gaps' },
          ],
        },
        {
          label: 'Project',
          items: [
            { label: 'Development', slug: 'docs/development' },
            { label: 'Releasing', slug: 'docs/releasing' },
            { label: 'Translating', slug: 'docs/translating' },
            { label: 'Transparency', slug: 'docs/transparency' },
          ],
        },
      ],
      lastUpdated: false,
      pagination: true,
    }),
  ],
});
