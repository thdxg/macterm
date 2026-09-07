# Macterm website

The marketing landing page and docs — built by Bun, served by Caddy, shipped as
a container image.

## Structure

```
public/            Served as static files
  index.html       Landing page (hand-authored)
  docs/            One HTML file per docs page ── generated, do not edit ──
  img/             Web-sized image derivatives ── generated, do not edit ──
  tailwind.css     Compiled styles ── generated, do not edit ──
  site.js          Shared behavior (sticky nav, copy buttons, GitHub stats)
  assets/          Symlink to the repo-root assets/ (icon, screenshots, schema)
src/
  tailwind.css     Tailwind v4 input + design tokens (@theme) + components
  docs-template.html  Shell each rendered docs page is injected into
docs/
  pages/*.md       Docs content — one Markdown file per page
build-images.mjs   Resizes assets/*.png → public/img/ (responsive WebP +
                   fallback PNG, the OG card, and favicon sizes)
build-docs.mjs     Renders docs/pages/*.md → public/docs/<slug>.html;
                   also emits public/sitemap.xml and public/robots.txt
check-seo.mjs      Build-time guard: fails the build if the landing page's FAQ
                   markup and its FAQPage JSON-LD disagree, or if index.html's
                   canonical/og:url drift from SITE_URL
Caddyfile          How the built site is served — used by dev and prod alike
Dockerfile         Multi-stage image — Bun builds it, Caddy serves it
```

### Design

Both the landing page and the docs run one dark **"Classical"** system, ported
from a Claude Design canvas: Rosé Pine ink on a warm-neutral `#19191a` ground,
Cormorant Garamond display over Lora body text, JetBrains Mono for code. Only
the fonts live in `@theme`; every colour is scoped under `.landing`, which both
`public/index.html` and `src/docs-template.html` set on `<body>`, so the docs
shell reuses the landing's tokens instead of defining a second palette.

The canvas expresses a design as inline styles per element, which is what an
artboard has to do. Those are reassembled into named `.l-*` classes in
`src/tailwind.css` — hover and focus states have nowhere to live on an
artboard, and the canvas is a fixed 1180px, so every responsive step below that
is the implementation's own.

**Every command surface is one component, `.cmd`** — the hero's install pill
(`.cmd--inline`), the landing Install section, and every fenced block
`build-docs.mjs` emits. They began as three near-identical rule sets and drifted
into two font sizes, two copy-button sizes, two border colours, and two
different vertical alignments for the same button. The component owns its type
metrics so the `<pre>` and the `<code>` share one strut, and the floating copy
button's offset is derived from those tokens in `calc()` — it aligns to the
centre of the *first line*, which reads as centred on a one-line command and
stays at the top of a long block. Change the padding or the type size and the
button follows on its own.

### Images

`assets/` holds the originals the README and release notes use — 3132×1780
screenshots at ~2MB each. The pages never reference those directly:
`build-images.mjs` renders them into `public/img/` as a responsive WebP
`srcset` (640/1000/1400/2200/3132w) plus a 1400w PNG fallback, and the landing page
picks a rung with `<picture>`. The hero went from a 2.5MB PNG to 53KB at 1×
and 142KB at 2×, which is the difference between failing and passing Largest
Contentful Paint.

It also emits `img/og.png` — the 1200×630 social card, letterboxed on the
site's own ground rather than cropped — and `img/icon-{16,32,180}.png`, so the
favicon is not the 810KB 1024×1024 app icon.

Replace a screenshot by dropping a new one into `assets/`; every derivative is
regenerated on the next build, so they cannot go stale. `public/img/` is
gitignored.

The landing gallery is **five** screenshots, in this order — sidebar, command
palette, settings, full-screen TUI, quick terminal — and its captions are
written into `index.html` against those positions. The build prints a warning
naming any that are missing, because the gallery hard-codes five thumbnails, so
a missing source is a 404 in production rather than a shorter gallery.

The figure in the "Built on libghostty" section mirrors the gallery's
selection. Both carry the same `data-shot-*` hooks and `site.js` rewrites every
one it finds, but each keeps its own `sizes`, so the small figure still resolves
to a small rung. The `Caddyfile` gives `/img/*` the same TTL as `/assets/*` — keep
the two paths listed together in both its `@media` and `@pages` matchers, or
the images every page loads fall through to the no-cache `@pages` rule.

> `index.html` is hand-authored and no build step rewrites it, so anything it
> states twice can drift silently. `check-seo.mjs` guards the two that matter:
> its canonical/`og:url` against `SITE_URL`, and — if a FAQ is ever added back
> — the visible `.l-qa` markup against its `FAQPage` JSON-LD, which Google
> requires to match verbatim. Having neither FAQ half is fine; having one
> without the other fails the build, because schema with no visible text is
> ineligible for the rich result and is the kind of thing that earns a manual
> action.

The canonical production origin lives in one place — the `SITE_URL` constant at
the top of `build-docs.mjs` — and feeds the docs canonical tags, Open Graph
URLs, JSON-LD, and the sitemap. The landing page (`public/index.html`) is
hand-authored, so its canonical/OG URLs and JSON-LD are inline; keep them in
sync with `SITE_URL` if the domain ever changes.

The docs are a **multi-page site**. Each `docs/pages/*.md` becomes one page;
files are ordered by their numeric filename prefix (`10-installation.md`). The
sidebar links across all pages and marks the current one with a rose rule in
the gutter, and `build-docs.mjs` emits the group name as the page's eyebrow
plus prev/next links from that same order. A Markdown blockquote renders as the
design's bordered **Note** callout, its label supplied by CSS. The
`Caddyfile`'s `try_files` rule serves `public/docs/install.html` at the clean
URL `/docs/install`, and `public/docs/index.html` at `/docs/` — the
extensionless resolution the site used to get from Cloudflare's
`auto-trailing-slash` html handling, and the reason a bare file server won't do.

> Bun's native HTML serving (`bun ./public/**/*.html`) does derive exactly the
> right routes, but it is a bundler, not a file server: it tries to resolve
> every root-absolute `src`/`href` as a build input (500s on `/site.js`,
> `/tailwind.css`, `/assets/icon.png`), never serves files no page references
> (`sitemap.xml`, `robots.txt`), 404s `/docs/`, and injects an HMR client. It's
> a dev server for bundled apps, which this site isn't.

### GitHub stats

The star count, total download count, and the Download button's link to the
latest `.dmg` come from `api.github.com`, called **client-side and
unauthenticated** by `public/site.js`. There is no API token and no server-side
proxy — the unauthenticated budget is 60 requests/hour per visitor IP, and the
site spends at most three of them, each cached in `localStorage` for an hour and
fetched only on a page that displays it. Everything degrades to a hidden stat
line and the static `/releases/latest` href when a call fails.

## Develop

```sh
brew install caddy  # once — `bun run dev` serves through it
bun install
bun run build       # build:docs then build:css
bun run dev         # builds, then serves on http://localhost:8765
```

`bun run dev` runs the same `Caddyfile` the image does, pointed at the working
tree (`SITE_ROOT=$PWD/public`), so local preview and production resolve URLs
identically. `PORT` overrides the port.

`public/docs/`, `tailwind.css`, `sitemap.xml`, and `robots.txt` are build
artifacts (gitignored) — regenerated by `bun run build`, which runs
automatically before `dev`. Edit the docs by changing `docs/pages/*.md`; edit
styles/tokens in `src/tailwind.css`.

> Use `bun run dev`, not a plain static file server, to preview: only the
> `Caddyfile` resolves the extensionless `/docs/<slug>` URLs the sidebar links
> to.

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

## Container image

`.github/workflows/website.yml` builds `website/Dockerfile` for `linux/amd64`
and `linux/arm64` on every push to `main` that touches `website/` or `assets/`,
and publishes one multi-arch manifest to
`ghcr.io/thdxg/macterm/website`. Pull requests build both architectures without
pushing, so a broken Dockerfile fails the PR rather than `:latest`.

Three tags are published: `:latest` (what a human pulls), `:sha-<short>` (the
way back to a specific build after a bad one), and a UTC timestamp tag,
`:20260813-142259-62701be`. The last one exists for the deployment — the
cluster runs the site at [macterm.thdxg.dev](https://macterm.thdxg.dev) and
Flux's image automation selects the newest image by **sorting tag strings**, so
it needs a tag whose lexical order is its chronological order. `:latest` is one
string forever and `:sha-<short>` sorts arbitrarily; only the zero-padded
timestamp does. The deployment manifest lives in the
[`thdxg/homelab`](https://github.com/thdxg/homelab) repo under `apps/macterm/`,
and its `filterTags` pattern hard-codes this format — the two move together.

```sh
docker run --rm -p 3000:3000 ghcr.io/thdxg/macterm/website:latest
```

Build it locally the same way CI does — note the context is the **repository
root**, because `public/assets` is a symlink to the root `assets/` dir:

```sh
bun run docker:build   # docker build -f Dockerfile -t macterm-website ..
bun run docker:run     # docker run --rm -p 3000:3000 macterm-website
```

The image installs dependencies and renders the docs in Bun build stages, then
copies `public/` and the `Caddyfile` into a `caddy:2-alpine` stage — the site is
static by then, so no Bun and no `node_modules` reach the runtime (`marked` and
the Tailwind CLI are build-time only). It runs as uid 1000, writes nothing, and
terminates no TLS: that belongs to whatever fronts it.

Two optional environment variables: `PORT` (default `3000`) and `SITE_ROOT`
(default `/srv`). `GET /healthz` is the liveness endpoint the image's
`HEALTHCHECK` polls. Responses are gzip/zstd compressed — the CLI docs page goes
out at 7.8KB instead of 26.8KB.
