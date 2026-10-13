# Macterm website

The website has the landing page and the docs. Bun builds it. Caddy serves it. A container image ships it to [macterm.thdxg.dev](https://macterm.thdxg.dev).

## Structure

```
public/            Static files that Caddy serves
  index.html       Landing page (written by hand)
  site.js          Shared behavior (copy buttons, docs menu, demo reel)
  assets/          Symlink to assets/ in the repo root (icons, hero, demo clips, schemas)
  docs/            One HTML file for each docs page ── generated, do not edit ──
  img/             The OG card and the favicons ── generated, do not edit ──
  tokens.css       Compiled design tokens ── generated, do not edit ──
  components/      The bundle.css of the design system ── copied, do not edit ──
src/
  docs-template.html  The shell that holds each rendered docs page
design-system/     Vendored copy of the eyesclosed design system
docs/pages/*.md    Docs content: one Markdown file for each page
build-images.mjs   Renders assets/ images → public/img/
build-docs.mjs     Renders docs/pages/*.md → public/docs/<slug>.html, plus
                   sitemap.xml and robots.txt
build-tokens.mjs   Compiles design-system/tokens.json → public/tokens.css and
                   copies bundle.css → public/components/bundle.css
check-seo.mjs      Fails the build when a fact that index.html states twice
                   disagrees with itself or with SITE_URL
Caddyfile          How Caddy serves the site, in dev and in production
Containerfile      Bun builds the site, Caddy serves it
```

Git ignores every generated file. `bun run build` writes them again.

## Develop

```sh
brew install caddy  # once
bun install
bun run dev         # builds, then serves on http://localhost:8765
```

`bun run dev` serves through the same `Caddyfile` as production. Do not use a plain static file server. Only the `Caddyfile` resolves the extensionless `/docs/<slug>` URLs that the sidebar links to. `PORT` sets another port.

### Docs pages

Each file in `docs/pages/` is one page. The number prefix sets the order. Each file starts with a front-matter comment:

```
<!-- page:
slug: install            → public/docs/install.html, served at /docs/install
title: Installation      <title> and the page's <h1>
nav: Installation        sidebar link label
group: Getting started   sidebar group heading (grouped in first-seen order)
description: ...         <meta name="description">
-->
```

Add `title="path"` after the language of a fenced code block to get a caption with a file name. A blockquote becomes a Note.

When you remove or rename a page, add a `redir` line for its old URL in the `Caddyfile`.

### Design

The site uses the **eyesclosed** design system and has no stylesheet of its own. Pages use the `ec-*` classes of the system. `design-system/` is a vendored copy. Never edit it here: change the system, copy `tokens.json` and `components/bundle.css` back, and build again. Do not add a color, a size or a component that the system does not have.

### Landing page

The landing page plays one clip for each feature from `assets/demo/`. `scripts/record-demos/record-demos.sh` records the clips and encodes them for the web (see AGENTS.md). `index.html` sets their order. The comments in `site.js` explain the scrolling and the playback.

The text of a feature names the action, never the keys. A user can change every keybind.

`index.html` has no build step, so its canonical URL, OG URLs and JSON-LD are written in the file. They must match `SITE_URL` in `build-docs.mjs`. `check-seo.mjs` checks this.

### Update feed

The site also serves the Sparkle feed: `/appcast.xml` and `/notes/<tag>.html`. The image does not contain them. The `Caddyfile` proxies them from the `gh-pages` branch, and its comments explain the rules for that block.

> The origin is a contract with the app. `SUFeedURL` in `Macterm/Info.plist`, `SITE_URL` in `scripts/publish-appcast.sh` and `SITE_URL` in `build-docs.mjs` must all name this site. An installed app asks the URL that it was built with, forever. `UpdaterChannelTests` checks them.

## Container image

`.github/workflows/website.yml` builds the image with podman for `linux/arm64` on each push to `main` that changes `website/` or `assets/`, and publishes it to `ghcr.io/thdxg/macterm/website`. A pull request builds the image but does not push it. Flux deploys the timestamp tag. The workflow explains the tag format.

To build the image on your Mac, use podman, not `docker build`. The context is the repo root, because `public/assets` is a symlink out of `website/`. Docker does not read the root `.containerignore`, so it would send the whole repo.

```sh
bun run podman:build
bun run podman:run     # serves on http://localhost:3000
```

The image accepts `PORT` (default `3000`) and `SITE_ROOT` (default `/srv`). `GET /healthz` is the liveness endpoint.
