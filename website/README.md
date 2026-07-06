# Macterm website

The marketing landing page and docs, served by a Cloudflare Worker
(`src/index.js`) that also exposes a `/api/stats` endpoint for live GitHub
stars and the latest `.dmg` download link.

## Structure

```
public/            Served as static assets by the Worker
  index.html       Landing page (hand-authored)
  docs/            One HTML file per docs page ── generated, do not edit ──
  tailwind.css     Compiled styles ── generated, do not edit ──
  site.js          Shared behavior (sticky nav, copy buttons, stats)
  assets/          icon.png, screenshot.png, JSON schemas
src/
  tailwind.css     Tailwind v4 input + design tokens (@theme) + components
  docs-template.html  Shell each rendered docs page is injected into
docs/
  pages/*.md       Docs content — one Markdown file per page
build-docs.mjs     Renders docs/pages/*.md → public/docs/<slug>.html;
                   also emits public/sitemap.xml and public/robots.txt
```

The canonical production origin lives in one place — the `SITE_URL` constant at
the top of `build-docs.mjs` — and feeds the docs canonical tags, Open Graph
URLs, JSON-LD, and the sitemap. The landing page (`public/index.html`) is
hand-authored, so its canonical/OG URLs and JSON-LD are inline; keep them in
sync with `SITE_URL` if the domain ever changes.

The docs are a **multi-page site**. Each `docs/pages/*.md` becomes one page;
files are ordered by their numeric filename prefix (`10-installation.md`). The
sidebar links across all pages and marks the current one active. Cloudflare's
`auto-trailing-slash` html handling serves `public/docs/install.html` at the
clean URL `/docs/install`, and `public/docs/index.html` at `/docs/`.

## Develop

```sh
bun install
bun run build       # build:docs then build:css
bun run dev         # builds, then wrangler dev (matches production URL handling)
```

`public/docs/` and `tailwind.css` are build artifacts (gitignored) — regenerated
by `bun run build`, which runs automatically before `dev` and `deploy`. Edit the
docs by changing `docs/pages/*.md`; edit styles/tokens in `src/tailwind.css`.

> Use `bun run dev` (wrangler), not a plain static server, to preview: only
> wrangler resolves the extensionless `/docs/<slug>` URLs the sidebar links to.

Each page starts with a front-matter comment:

```
<!-- page:
slug: install            → public/docs/install.html, served at /docs/install
title: Installation      <title> and the page's <h1>
nav: Installation        sidebar link label
group: Getting started   sidebar group heading (grouped in first-seen order)
description: ...         <meta name="description">
-->
```

Fenced code blocks render as the dark code component; add `title="path"` after
the language for a filename caption bar. To add a page, drop a new numbered
`.md` in `docs/pages/`.

## Deploy

Deployed as a Cloudflare Worker via **Workers Builds** (Git integration): on
push, Cloudflare runs the `[build]` command in `wrangler.toml`
(`bun install && bun run build`) and then `wrangler deploy`. The generated
`public/docs/` and `tailwind.css` are gitignored, so the build step is what
produces them — never ship `public/` without building.

Because this Worker lives in a subdirectory of the repo, its **root directory**
in the Cloudflare dashboard (Worker → Settings → Builds) must be set to
`website` so the build and deploy commands run here.

To deploy by hand instead:

```sh
bun run deploy      # build + wrangler deploy
```
