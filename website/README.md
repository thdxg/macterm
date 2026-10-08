# Macterm website

The marketing landing page and docs — built by Bun, served by Caddy, shipped as
a container image.

## Structure

```
public/            Served as static files
  index.html       Landing page (hand-authored)
  docs/            One HTML file per docs page ── generated, do not edit ──
  img/             Web-sized image derivatives ── generated, do not edit ──
  tokens.css       Compiled design tokens ── generated, do not edit ──
  components/      The design system's bundle.css ── copied, do not edit ──
  site.js          Shared behavior (copy buttons, demo reel, GitHub stats)
  assets/          Symlink to the repo-root assets/ (icon, screenshots, schema)
src/
  docs-template.html  Shell each rendered docs page is injected into
design-system/     Vendored copy of the eyesclosed design system: tokens.json
                   and bundle.css, never edited here
docs/
  pages/*.md       Docs content — one Markdown file per page
build-images.mjs   Resizes assets/*.png → public/img/ (responsive WebP +
                   fallback PNG, the OG card, and favicon sizes)
build-docs.mjs     Renders docs/pages/*.md → public/docs/<slug>.html;
                   also emits public/sitemap.xml and public/robots.txt
build-tokens.mjs   Compiles design-system/tokens.json → public/tokens.css and
                   copies bundle.css → public/components/bundle.css
check-seo.mjs      Build-time guard: fails the build if the landing page's FAQ
                   markup and its FAQPage JSON-LD disagree, or if index.html's
                   canonical/og:url drift from SITE_URL
Caddyfile          How the built site is served — used by dev and prod alike
Containerfile      Multi-stage image — Bun builds it, Caddy serves it
```

### Design

Both pages are built from the **eyesclosed** design system, the one system
for every site Ethan makes. There is no site stylesheet: every page loads
`/tokens.css` and `/components/bundle.css`, puts `class="ec"` on `<body>`, and
uses the system's `ec-*` classes as its component READMEs document them — plus
`tok-*` for syntax highlighting. DM Sans (and Fira Code, inside code only) comes
from Google Fonts through `bundle.css`'s `@import`.

`design-system/` is a vendored copy of the system's `tokens.json` and
`components/bundle.css`. Never edit it here: change the system, copy the two
files back, and rebuild. `build-tokens.mjs` compiles `tokens.json` the way the
system does — colors under `:root, [data-theme="dark"]` with `{alias}` values as
`var(--alias)`, spacing, radii and grid widths under `:root`, a `--font-<key>`
per family, a class per type style — and copies `bundle.css` beside it. Don't
add colors, sizes or components the system doesn't have; add them to the
system first.

How the pages map onto it:

- **Landing** — no SiteHeader and no label column: a Hero set full width (no
  `ec-grid`; name, one sentence, a primary **Get started** button to
  `/docs/install` and a plain GitHub button); one unlabelled Section per
  feature whose body spans both columns (`ec-span`) (an `h3`,
  a muted sentence and its clip in a Figure), the features without a clip
  closing the run as an EntryList; and SiteFooter. There is no screenshot and
  no install command on the landing page; the button is the route to the docs.
- **Docs** — SiteHeader, DocsLayout (the sidebar in the label column, the page
  in an `ec-prose` article, Previous/Next pagenav), SiteFooter.
- **Code** — every fenced block `build-docs.mjs` emits is a CodeBlock
  (`ec-code`, with an `ec-code-caption` row when the fence has a `title=""`).
  YAML is highlighted with `tok-*` spans; a `console` block's `$ ` prompts are
  marked so the copy button drops them.

### Images

`assets/` holds the originals the README and release notes use — 3132×1780
screenshots at ~2MB each. The pages never reference those directly:
`build-images.mjs` renders them into `public/img/` as a responsive WebP
`srcset` (640/1000/1400/2200/3132w) plus a 1400w PNG fallback. Nothing is
upscaled: a rung wider than its original is skipped, and for the hero
(`assets/hero.png`, 2000px wide) the original's own width is the top rung. The
landing page no longer shows the hero; it is still what `og.png` is rendered
from.

It also emits `img/og.png` — the 1200×630 social card, letterboxed on the
site's own ground rather than cropped — and `img/icon-{16,32,180}.png`, so the
favicon is not the 810KB 1024×1024 app icon.

Replace a screenshot by dropping a new one into `assets/`; every derivative is
regenerated on the next build, so they cannot go stale. `public/img/` is
gitignored.

Only `screenshot-1` is still on the landing page — the figure in "Built on
libghostty" — plus `og.png`, which is rendered from it. The rest stay in
`assets/` for the repo README and the release notes. The `Caddyfile` gives
`/img/*` the same TTL as `/assets/*` — keep the two paths listed together in
both its `@media` and `@pages` matchers, or the images every page loads fall
through to the no-cache `@pages` rule.

### The demo reel

What used to be the screenshot gallery is now seven screen recordings, stacked
one per feature, in `assets/demo/`: `<name>.mp4` beside a `<name>.webp` poster
frame. Their number prefixes are the order they were recorded in, not the order
the page shows them — `index.html` decides that. They are referenced straight from `/assets/demo/…` — no build step —
because `public/assets` is the repo-root `assets/` (a symlink locally, real
files in the image) and Caddy already caches that path.

Each clip is 1400×792 H.264 at CRF 26 with `+faststart`, re-encoded from a
1680×950 master by `scripts/record-demos/record-demos.sh web` — the same script
that records them (see AGENTS.md); the poster is its first frame. All five
together are ~4MB, and none of it is fetched on load: the markup carries
`preload="none"` and the poster, and `site.js`'s `demoReel` only flips a clip
to `preload="auto"` and plays it when it scrolls into view — pausing it again
when it leaves, because five looping videos decoding at once is a fan the page
has no business spinning up.

`muted` and `playsinline` are what make that autoplay permissible at all; a
`play()` that is refused anyway turns the clip's controls on rather than
failing silently, which is also what Reduce Motion gets. A click pauses a clip
you want to read.

Each clip sits under its own `<h3>` and a line of copy in its Section, both
written into `index.html` — they are the only place the reel says what it is
showing. They name the ACTION, never the chord: every binding in the app is
rebindable, so copy that spells one out is wrong for anyone who changed it.

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
sidebar links across all pages and marks the current one with
`aria-current="page"`, and `build-docs.mjs` emits Previous/Next links from that
same order. A Markdown blockquote renders as the design system's **Note**, its
label supplied by CSS. The
`Caddyfile`'s `try_files` rule serves `public/docs/install.html` at the clean
URL `/docs/install`, and `public/docs/index.html` at `/docs/` — the
extensionless resolution the site used to get from Cloudflare's
`auto-trailing-slash` html handling, and the reason a bare file server won't do.

The docs pages carry a header with just the brand, linking home; the landing
page has none. Both share one footer. Retired pages keep their
URLs alive as `redir` lines in the `Caddyfile`: `/docs/ghostty` and
`/docs/tmux` were published pages and now 301 to the docs index. Add a line
there whenever a page is dropped or renamed.

> Bun's native HTML serving (`bun ./public/**/*.html`) does derive exactly the
> right routes, but it is a bundler, not a file server: it tries to resolve
> every root-absolute `src`/`href` as a build input (500s on `/site.js`,
> `/tokens.css`, `/img/icon-180.png`), never serves files no page references
> (`sitemap.xml`, `robots.txt`), 404s `/docs/`, and injects an HMR client. It's
> a dev server for bundled apps, which this site isn't.

### Sparkle update feed

`/appcast.xml` and `/notes/<tag>.html` are the only URLs this site serves that
the image does **not** contain. They are written at release time by
`scripts/publish-appcast.sh` to the repo's `gh-pages` branch, so the
`Caddyfile`'s `@updates` block proxies them off that branch through
`raw.githubusercontent.com` rather than serving files. `gh-pages` is a store,
not a website — reading a branch needs no GitHub Pages site.

Baking them into the image instead would mean rebuilding and redeploying the
site on every release *and every tip build* (tip publishes per commit to main),
with the feed lagging each one by the whole build-plus-Flux cycle. Proxying
keeps the publish script's git read-modify-write untouched and the feed live
the moment the workflow pushes.

Three things in that block are load-bearing, and all three were measured rather
than reasoned about:

- **Content types must be reasserted.** `raw.githubusercontent` serves every
  path as `text/plain` with `nosniff`, which renders a notes page as its own
  HTML source inside Sparkle's update dialog.
- **The reassertion uses `>`, Caddy's *deferred* set.** A plain `header` set is
  applied immediately — before `reverse_proxy` copies the upstream's headers in
  — so both values survive onto the response. That shipped two
  `X-Content-Type-Options` and would have shipped two `Content-Type`s.
- **`/notes/*` is exempt from the `.html`-stripping redirect.** Every published
  `<sparkle:releaseNotesLink>` names the extension, so stripping it would 301 to
  a path that does not exist on the branch. That exemption is a wire contract,
  not a style choice.

The `Cache-Control` set there is the response's only one — `/appcast.xml` and
`/notes/*` are kept out of the `@static`/`@pages` matchers below, because two
`header` directives naming the same field is a race, not a decision. Upstream's
CDN bookkeeping (`X-Cache`, `X-Served-By`, `X-Github-*`, and an `Expires` that
would contradict our TTL) is stripped for the same reason the site strips
`Server`; `Etag` and the upstream's CSP/`X-Frame-Options` are kept, the latter
because a notes page is now served as real HTML into a WebView.

> The origin here is a wire contract with the app: `SUFeedURL` in
> `Macterm/Info.plist`, `SITE_URL` in `scripts/publish-appcast.sh`, and
> `SITE_URL` in `build-docs.mjs` must all name this site.
> `UpdaterChannelTests.the_update_feed_and_the_website_name_one_origin` pins
> them, because an installed app polls the URL it was *built* with forever and a
> feed that 404s reports nothing at all.

### GitHub stats

`public/site.js` can fill a star count, a download total and the latest
`.dmg` link from `api.github.com`, called **client-side and unauthenticated**.
No page renders any of them today, so none of the fetches run; each runs only
on a page that carries its `data-stat-*` / `data-download-latest` markup. There is no API token and no server-side
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

`public/docs/`, `tokens.css`, `components/`, `sitemap.xml`, and `robots.txt` are build
artifacts (gitignored) — regenerated by `bun run build`, which runs
automatically before `dev`. Edit the docs by changing `docs/pages/*.md`; edit
styles in the design system, then copy its files into `design-system/`.

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

`.github/workflows/website.yml` builds `website/Containerfile` with podman, for
`linux/arm64` only, on every push to `main` that touches `website/` or
`assets/`, and publishes it to `ghcr.io/thdxg/macterm/website`. Pull requests
build without pushing, so a broken Containerfile fails the PR rather than
`:latest`. There is no amd64 image: on an x86 host, `podman run` fails with an
exec format error unless it is set up to emulate arm64.

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
podman run --rm -p 3000:3000 ghcr.io/thdxg/macterm/website:latest
```

Build it locally the same way CI does. The context is the **repository root**,
because `public/assets` is a symlink to the root `assets/` dir, and the
context is filtered by the root `.containerignore`, which Docker doesn't read.
So build with podman: `docker build` would send the whole repo, GhosttyKit
included.

```sh
bun run podman:build   # podman build --format docker --platform linux/arm64 -f Containerfile -t macterm-website ..
bun run podman:run     # podman run --rm -p 3000:3000 macterm-website
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
