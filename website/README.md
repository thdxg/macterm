# Macterm website

The website has the marketing landing page and the docs. Bun builds it. Caddy serves it. A container image ships it.

## Structure

```
public/            Static files that Caddy serves
  index.html       Landing page (written by hand)
  docs/            One HTML file for each docs page ── generated, do not edit ──
  img/             Web-sized image copies ── generated, do not edit ──
  tokens.css       Compiled design tokens ── generated, do not edit ──
  components/      The bundle.css of the design system ── copied, do not edit ──
  site.js          Shared behavior (copy buttons, demo reel, GitHub stats)
  assets/          Symlink to assets/ in the repo root (icon, screenshots, schema)
src/
  docs-template.html  The shell that holds each rendered docs page
design-system/     Vendored copy of the eyesclosed design system: tokens.json
                   and bundle.css. Never edit them here.
docs/
  pages/*.md       Docs content: one Markdown file for each page
build-images.mjs   Resizes assets/*.png → public/img/ (responsive WebP and
                   fallback PNG, the OG card, and favicon sizes)
build-docs.mjs     Renders docs/pages/*.md → public/docs/<slug>.html.
                   Also writes public/sitemap.xml and public/robots.txt
build-tokens.mjs   Compiles design-system/tokens.json → public/tokens.css and
                   copies bundle.css → public/components/bundle.css
check-seo.mjs      Build check. It fails the build if the FAQ markup of the
                   landing page and its FAQPage JSON-LD disagree, or if the
                   canonical and og:url of index.html differ from SITE_URL
Caddyfile          How Caddy serves the built site. Dev and prod use it
Containerfile      Multi-stage image: Bun builds it, Caddy serves it
```

### Design

Both kinds of page use the **eyesclosed** design system. Ethan uses this one system for every site that he makes. The site has no stylesheet of its own. Every page loads `/tokens.css` and `/components/bundle.css`. Every page puts `class="ec"` on `<body>`. Every page uses the `ec-*` classes as the component READMEs of the system describe them. Pages use `tok-*` classes for syntax highlighting. Open Sans comes from Google Fonts through the `@import` in `bundle.css`. Fira Code comes from the same place and appears only inside code.

`design-system/` is a vendored copy of `tokens.json` and `components/bundle.css` from the system. Never edit it here. Change the system, copy the two files back, and build again. `build-tokens.mjs` compiles `tokens.json` in the same way as the system:

- Colors go under `:root, [data-theme="dark"]`. A `{alias}` value becomes `var(--alias)`.
- Spacing, radii and sizes (`width-text`, `width-sidebar`, `inset-stage`) go under `:root`.
- Each font family gets a `--font-<key>` variable.
- Each type style gets a class.

It also copies `bundle.css` next to `tokens.css`. Do not add a color, a size or a component that the system does not have. Add it to the system first. The scripts that the components need are in `public/site.js`, as the component READMEs give them.

How the pages use the system:

- **Landing page.** Split and Reel. On desktops (1024 pixels and up), the page is one screen that does not scroll.
  1. The hero holds still in the left column (`ec-split-side`). It has one sentence that starts with the name, a primary **Get started** button to `/docs/install` and a plain GitHub button. The page has no SiteHeader. The SiteFooter is under the hero (`ec-split-foot`).
  2. The features scroll in the pane at the right (`ec-split-pane ec-reel`). The pane has no background. Each feature is an unlabelled Section: an `h3`, a muted line and the clip in a Figure. An EntryList ends the list for the features that have no clip. The features fade out over the top 40% of the pane and in over the bottom 40%.
  3. The pane scrolls smoothly (`smoothPane` in `site.js`). Every wheel and scrolling key on the page sets a target, and the pane eases to it on each frame. Reduce Motion goes to the target at once.
  4. The pane has no end, in either direction (`reel` in `site.js`). The script keeps three pane heights of features above and below the reader. It adds another lap of the list where the reader runs short. A lap is a copy of the list from before any clip loaded. Assistive tech does not read it (`aria-hidden`, `inert`). A lap added above moves the content down, so the script moves `scrollTop` down by the same distance. That stops native momentum in Safari, but `smoothPane` drives every scroll on desktops, so no native momentum runs. On load, and on Home, the script centers the first feature in the pane.

  Below 1024 pixels there is no split and no reel: the hero, the features one time, then the footer, in one column that scrolls. The landing page has no install command. The button leads to the docs, because the docs explain the Gatekeeper step.
- **Docs.** DocsLayout, with no SiteHeader and no SiteFooter. DocsLayout pins the index at the left. It holds the name and the generated page groups. Home, GitHub and Releases are at its bottom. The page is an `ec-prose` article with Previous and Next links. On desktops, the page is in the middle of the window. The window scrolls natively. The page fades out under two bands at the top and bottom of the window (`ec-docs-fade`). The `docsFades` function in `site.js` marks where the reader is (`data-scrolled` and `data-end` on `<html>`). Below 960 pixels, a bar holds the name and a menu button, and the index becomes a full-screen menu (`docsMenu` in `site.js`).
- **Code.** `build-docs.mjs` writes every fenced block as a CodeBlock (`ec-code`). When the fence has a `title=""`, the CodeBlock has an `ec-code-caption` row. YAML gets `tok-*` spans for highlighting: keys are `tok-member`, numbers and booleans are `tok-constant`, and other values are `tok-string`. Code has no hue. The grays of the system shade it. In a `console` block, the build marks each `$ ` prompt, so the copy button does not copy it. After a copy, the button shows a check for 1.5 seconds.

### Images

`assets/` holds the original images for the README and the release notes. The screenshots are 3132×1780 pixels and about 2 MB each. The pages never use these files directly. `build-images.mjs` renders them into `public/img/`. It makes a responsive WebP `srcset` (640, 1000, 1400, 2200 and 3132 pixels wide) and a PNG fallback that is 1400 pixels wide. It never makes an image larger than its original. It skips a size that is wider than the original. For the hero (`assets/hero.png`, 2000 pixels wide), the original width is the largest size. The landing page no longer shows the hero. The build still renders `og.png` from the hero.

The build also writes `img/og.png`, the social card at 1200×630 pixels. The card has bars to fit the ground of the site. It does not crop the image. The build also writes `img/icon-{16,32,180}.png`, so the favicon is not the 1024×1024 app icon of 810 KB.

To replace a screenshot, put the new file in `assets/`. The next build regenerates every copy, so the copies cannot become old. Git ignores `public/img/`.

The landing page shows no screenshot. It uses `og.png`, which the build renders from the hero image. The other screenshots stay in `assets/` for the repo README and the release notes. The `Caddyfile` gives `/img/*` the same TTL as `/assets/*`. Keep the two paths together in both the `@media` matcher and the `@pages` matcher. If you separate them, the images that every page loads fall into the `@pages` rule, which has no cache.

### The demo reel

The screenshot gallery is now a set of screen recordings. There is one recording for each feature, one below the other, in `assets/demo/`. Each has an `<name>.mp4` file and a `<name>.webp` poster frame next to it. The number prefix is the order of recording. It is not the order of the page. `index.html` sets the page order. The page uses the files from `/assets/demo/…` with no build step. `public/assets` is the `assets/` folder in the repo root. Locally it is a symlink. In the image it is real files. Caddy already caches that path.

Each clip is 1400×792 H.264 with CRF 26 and `+faststart`. The command `scripts/record-demos/record-demos.sh web` encodes it again from a 1680×950 master. That script also records the clips (see AGENTS.md). The poster is the first frame. All five clips together are about 4 MB. The page requests none of them when it loads. The markup has `preload="none"` and the poster. The `reel` function in `site.js` changes a clip to `preload="auto"` and plays it only while a reader can see it. On desktops, that is in the panel. Below 1024 pixels, it is on screen. It pauses every other clip, and it plays nothing while the tab is hidden. Many looping videos that decode at the same time would make the fan of a Mac run for no reason.

`muted` and `playsinline` make the autoplay allowed. If the browser refuses a `play()` call, the poster stays. Reduce Motion gets the same result. The clips are illustrations: they have no controls, and `pointer-events: none` stops a click from pausing them or opening the player UI.

Each clip has its own `<h3>` and one line of text in its Section. Both are in `index.html`. They are the only place where the reel says what it shows. They name the ACTION. They never name the keys. Every keybind in the app can change, so text that names a key is wrong for a person who changed it.

> A person writes `index.html` by hand. No build step changes it, so a fact that it states twice can become different in the two places without a warning. `check-seo.mjs` guards the two that matter. First, the canonical and `og:url` must match `SITE_URL`. Second, if a FAQ returns, the visible `.l-qa` markup must match its `FAQPage` JSON-LD. Google requires the two to match word for word. A page with no FAQ at all is correct. A page with only one of the two halves fails the build. Schema with no visible text cannot get the rich result. It can also cause a manual action.

The production origin is in one place: the `SITE_URL` constant at the top of `build-docs.mjs`. It feeds the canonical tags of the docs, the Open Graph URLs, the JSON-LD and the sitemap. A person writes the landing page (`public/index.html`) by hand. Its canonical URL, its OG URLs and its JSON-LD are in the file. If the domain changes, change them to match `SITE_URL`.

The docs are a **multi-page site**. Each `docs/pages/*.md` file becomes one page. The number prefix of the file name sets the order (`10-installation.md`). The sidebar links to all pages. It marks the current page with `aria-current="page"`. `build-docs.mjs` writes the Previous and Next links in the same order. A Markdown blockquote becomes the **Note** of the design system. CSS supplies its label. The `try_files` rule in the `Caddyfile` serves `public/docs/install.html` at the clean URL `/docs/install`. It serves `public/docs/index.html` at `/docs/`. Cloudflare gave the site this extensionless URL resolution before, with its `auto-trailing-slash` html handling. A plain file server cannot do it.

A docs page has a header with only the brand, which links to the home page. The landing page has no header. Both share one footer. A retired page keeps its URL alive with a `redir` line in the `Caddyfile`. `/docs/ghostty` and `/docs/tmux` were once public pages. They now redirect to the docs index with a 301. Add a line there each time that you remove or rename a page.

> Bun can serve HTML files natively (`bun ./public/**/*.html`). It finds the correct routes. But it is a bundler, not a file server. It tries to resolve each root-absolute `src` and `href` as a build input, and it gives a 500 error for `/site.js`, `/tokens.css` and `/img/icon-180.png`. It never serves a file that no page uses (`sitemap.xml`, `robots.txt`). It gives a 404 error for `/docs/`. It adds an HMR client. It is a dev server for bundled apps. This site is not a bundled app.

### Sparkle update feed

This site serves two kinds of URL that the image does **not** contain: `/appcast.xml` and `/notes/<tag>.html`. The script `scripts/publish-appcast.sh` writes them to the `gh-pages` branch of the repo when a release happens. The `@updates` block in the `Caddyfile` proxies them from that branch through `raw.githubusercontent.com`. It does not serve files. `gh-pages` is a store, not a website. To read a branch, you do not need a GitHub Pages site.

The alternative is to put the files in the image. Then each release and each tip build needs a new build and a new deploy of the site. Tip builds publish for each commit to main. The feed would lag behind each one by the full time of the build and the Flux cycle. The proxy leaves the git sequence of the publish script (read, change, write) as it is. The feed is live when the workflow pushes.

Three things in that block are load-bearing. We measured all three. We did not only reason about them.

- **Set the content types again.** `raw.githubusercontent` serves every path as `text/plain` with `nosniff`. Then a notes page shows its own HTML source in the update dialog of Sparkle.
- **Use `>` to set them again.** `>` is the deferred set of Caddy. A plain `header` set takes effect at once, before `reverse_proxy` copies the headers of the upstream. Then both values stay on the response. That gave two `X-Content-Type-Options` headers. It would give two `Content-Type` headers too.
- **Exempt `/notes/*` from the redirect that removes `.html`.** Every published `<sparkle:releaseNotesLink>` has the extension. If the redirect removed it, the 301 would lead to a path that does not exist on the branch. This exemption is a wire contract. It is not a style choice.

The `Cache-Control` header set in that block is the only one on the response. `/appcast.xml` and `/notes/*` are not in the `@static` and `@pages` matchers below it. Two `header` directives for one field cause a race. They are not a decision. The block also removes the CDN headers of the upstream: `X-Cache`, `X-Served-By`, `X-Github-*` and an `Expires` that would contradict our TTL. The site removes `Server` for the same reason. The block keeps `Etag` and the CSP and `X-Frame-Options` of the upstream. It keeps the last two because the site now serves a notes page as real HTML into a WebView.

> The origin here is a wire contract with the app. `SUFeedURL` in `Macterm/Info.plist`, `SITE_URL` in `scripts/publish-appcast.sh` and `SITE_URL` in `build-docs.mjs` must all name this site. `UpdaterChannelTests.the_update_feed_and_the_website_name_one_origin` checks them. An installed app asks the URL that it was *built* with, forever. A feed that gives a 404 reports nothing.

### GitHub stats

`public/site.js` can fill a star count, a download total and the link to the latest `.dmg`. It reads them from `api.github.com`. It calls the API **in the browser, with no authentication**. No page shows any of them today, so none of the requests run. A request runs only on a page that has its `data-stat-*` or `data-download-latest` markup. The site has no API token and no server-side proxy. The budget without authentication is 60 requests each hour for each visitor IP. The site uses at most three. It caches each one in `localStorage` for one hour. It makes a request only on a page that shows the value. When a call fails, the stat line is hidden and the static `/releases/latest` link stays.

## Develop

```sh
brew install caddy  # once — `bun run dev` serves through it
bun install
bun run build       # build:docs then build:css
bun run dev         # builds, then serves on http://localhost:8765
```

`bun run dev` uses the same `Caddyfile` as the image. It points the file at the working tree (`SITE_ROOT=$PWD/public`). Local preview and production therefore resolve URLs in the same way. `PORT` sets another port.

`public/docs/`, `tokens.css`, `components/`, `sitemap.xml` and `robots.txt` are build files. Git ignores them. `bun run build` writes them again. It runs automatically before `dev`. To edit the docs, change `docs/pages/*.md`. To edit styles, change the design system and copy its files into `design-system/`.

> Use `bun run dev` to preview. Do not use a plain static file server. Only the `Caddyfile` resolves the extensionless `/docs/<slug>` URLs that the sidebar links to.

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

Fenced code blocks become the dark code component. Add `title="path"` after the language to get a caption bar with a file name. To add a page, put a new numbered `.md` file in `docs/pages/`.

## Container image

The workflow `.github/workflows/website.yml` builds `website/Containerfile` with podman. It builds for `linux/arm64` only. It runs on each push to `main` that changes `website/` or `assets/`. It publishes the image to `ghcr.io/thdxg/macterm/website`. A pull request builds the image but does not push it. A broken Containerfile therefore fails the PR and not `:latest`. There is no amd64 image. On an x86 host, `podman run` fails with an exec format error. To avoid the error, set up the host to emulate arm64.

The workflow publishes three tags:

- `:latest` is the tag that a person pulls.
- `:sha-<short>` is the way back to one build after a bad one.
- A UTC timestamp tag, for example `:20260813-142259-62701be`.

The timestamp tag exists for the deployment. The cluster runs the site at [macterm.thdxg.dev](https://macterm.thdxg.dev). The image automation of Flux selects the newest image when it **sorts the tag strings**. It therefore needs a tag whose alphabetical order is its time order. `:latest` is always the same string. `:sha-<short>` sorts in no useful order. Only the timestamp with zero padding works. The deployment manifest is in the [`thdxg/homelab`](https://github.com/thdxg/homelab) repo under `apps/macterm/`. Its `filterTags` pattern has this format in the code. The two change together.

```sh
podman run --rm -p 3000:3000 ghcr.io/thdxg/macterm/website:latest
```

Build the image on your Mac in the same way as CI. The context is the **repo root**, because `public/assets` is a symlink to the `assets/` folder in the root. The root `.containerignore` filters the context. Docker does not read that file. Build with podman. `docker build` would send the whole repo, with GhosttyKit.

```sh
bun run podman:build   # podman build --format docker --platform linux/arm64 -f Containerfile -t macterm-website ..
bun run podman:run     # podman run --rm -p 3000:3000 macterm-website
```

The image installs the dependencies and renders the docs in Bun build stages. Then it copies `public/` and the `Caddyfile` into a `caddy:2-alpine` stage. At that point the site is static. Bun and `node_modules` do not reach the runtime. (`marked` and the Tailwind CLI are for the build only.) The image runs as uid 1000 and writes nothing. It does not terminate TLS. The system in front of it does that.

There are two optional environment variables: `PORT` (default `3000`) and `SITE_ROOT` (default `/srv`). `GET /healthz` is the liveness endpoint. The `HEALTHCHECK` of the image polls it. The responses are gzip and zstd compressed. The CLI docs page goes out at 7.8 KB instead of 26.8 KB.
