// Renders website/docs/pages/*.md into a multi-page docs site under
// public/docs/ at build time, and the notes of every stable release into
// public/changelog.html (see releases.mjs).
//
// The site is plain static files, so the docs ship as plain HTML — no
// client-side Markdown parser, no content flash. Each Markdown file is one
// page; a shared sidebar links across pages and marks the current one active.
// The Caddyfile's try_files rule serves public/docs/install.html at
// /docs/install and public/docs/index.html at /docs/, so the slugs below are
// the URLs.
//
// Per-page front-matter (HTML comment at the top of each .md):
//   <!-- page:
//   slug: install            file becomes public/docs/<slug>.html
//   title: Installation      <title> and <h-nav> heading
//   nav: Installation        sidebar link label
//   group: Getting started   sidebar group heading
//   description: ...         <meta name="description">
//   -->
//
// Markdown conventions:
//   ```lang title="path"     fenced code -> an ec-code CodeBlock; title=""
//                            adds a filename caption row.
//   > blockquote             a Note (ec-prose styles every blockquote as one).

import { readFileSync, writeFileSync, readdirSync, mkdirSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { Marked } from "marked";
import { lastModifiedDates, LASTMOD_FILE, LANDING_SOURCE, pageSource } from "./lastmod.mjs";
import { fetchReleases, RELEASES_FILE, REPO } from "./releases.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const PAGES_DIR = join(here, "docs", "pages");
const TEMPLATE = join(here, "src", "docs-template.html");
const OUT_DIR = join(here, "public", "docs");
const PUBLIC_DIR = join(here, "public");

// Canonical production origin — used for canonical tags, OG URLs, and the
// sitemap. No trailing slash.
const SITE_URL = "https://macterm.thdxg.dev";

// The design system's copy glyph: 16px, 1.5px stroke in currentColor (the
// stroke comes from .ec-copy svg). The check after it in the same stroke shows
// for a moment after a copy (site.js marks the button, bundle.css swaps them).
const COPY_SVG =
  `<svg class="ec-copy-glyph" viewBox="0 0 16 16" aria-hidden="true"><rect x="5.5" y="5.5" width="8" height="8" rx="1.5"/><path d="M10.5 3.5v-.5a1 1 0 0 0-1-1h-6a1 1 0 0 0-1 1v6a1 1 0 0 0 1 1h.5"/></svg>` +
  `<svg class="ec-copied-glyph" viewBox="0 0 16 16" aria-hidden="true"><path d="M3.5 8.5l3 3 6-7"/></svg>`;

const escapeHtml = (s) =>
  s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");

// The clean URL for a page's slug. The intro is the docs index.
const urlForSlug = (slug) => (slug === "index" ? "/docs/" : `/docs/${slug}`);

// The release notes page, written to public/changelog.html (try_files serves it).
const CHANGELOG_PATH = "/changelog";

// ---- Minimal YAML-ish syntax highlighting for the layout sample -----------
// Works on the raw source and escapes each emitted piece itself (highlighting-
// then-escaping would mangle the quotes it keys on). Handles top-level
// `key: value`, list dashes, `#` comments, and inline flow maps. Classes are
// the design system's tok-* (Helix scope) names: keys are members (Helix reads
// a YAML key as variable.other.member), numbers and booleans constants, every
// other scalar a string.
const span = (cls, text) => `<span class="${cls}">${escapeHtml(text)}</span>`;

function highlightValue(val) {
  const trimmed = val.trim();
  if (!trimmed) return escapeHtml(val);
  const lead = val.slice(0, val.indexOf(trimmed));
  const tail = val.slice(val.indexOf(trimmed) + trimmed.length);
  if (trimmed.startsWith("{") && trimmed.endsWith("}")) {
    return escapeHtml(lead) + highlightFlowMap(trimmed) + escapeHtml(tail);
  }
  const cls = /^(true|false|null|~|-?\d+(\.\d+)?)$/.test(trimmed)
    ? "tok-constant"
    : "tok-string";
  return escapeHtml(lead) + span(cls, trimmed) + escapeHtml(tail);
}

function highlightFlowMap(text) {
  const inner = text.slice(1, -1);
  const parts = inner.split(",").map((pair) => {
    const m = pair.match(/^(\s*)([A-Za-z0-9_-]+)(\s*:\s*)(.*?)(\s*)$/);
    if (!m) return escapeHtml(pair);
    const [, sp, key, colon, val, trail] = m;
    return (
      escapeHtml(sp) +
      span("tok-member", key) +
      escapeHtml(colon) +
      highlightValue(val) +
      escapeHtml(trail)
    );
  });
  return escapeHtml("{") + parts.join(escapeHtml(",")) + escapeHtml("}");
}

function highlightYaml(code) {
  return code
    .split("\n")
    .map((line) => {
      let comment = "";
      const cm = line.match(/(\s+(?:\/\/|#).*)$/);
      if (cm) {
        comment = span("tok-comment", cm[1]);
        line = line.slice(0, cm.index);
      }
      let dash = "";
      const dm = line.match(/^(\s*)(- )/);
      if (dm) {
        dash = escapeHtml(dm[1]) + span("tok-punct", dm[2]);
        line = line.slice(dm[0].length);
      }
      const km = line.match(/^(\s*)([A-Za-z0-9_-]+)(\s*:\s*)([\s\S]*)$/);
      if (km) {
        const [, sp, key, colon, val] = km;
        return (
          dash +
          escapeHtml(sp) +
          span("tok-member", key) +
          escapeHtml(colon) +
          highlightValue(val) +
          comment
        );
      }
      return dash + escapeHtml(line) + comment;
    })
    .join("\n");
}

// ---- Markdown renderer: headings and CodeBlocks ---------------------------
// A heading's anchor: lowercased words joined by hyphens, as GitHub makes
// them, so `/docs/configuration#project-colors` and the app's help buttons
// (`DocsLink` in Macterm) can point at a section. A repeat on the same page
// gets `-2`, `-3`.
const slugifyHeading = (text) =>
  text
    .toLowerCase()
    .replace(/<[^>]*>/g, "")
    .replace(/&[a-z]+;/g, "")
    .replace(/[^a-z0-9\s-]/g, "")
    .trim()
    .replace(/\s+/g, "-");

function buildRenderer(seenAnchors) {
  return {
    heading({ tokens, depth, text }) {
      const base = slugifyHeading(text);
      const count = (seenAnchors.get(base) || 0) + 1;
      seenAnchors.set(base, count);
      const id = count === 1 ? base : `${base}-${count}`;
      return `<h${depth} id="${id}">${this.parser.parseInline(tokens)}</h${depth}>\n`;
    },
    code({ text, lang }) {
      const langBase = (lang || "").split(/\s+/)[0];
      const titleMatch = (lang || "").match(/title="([^"]*)"/);
      const title = titleMatch ? titleMatch[1] : null;
      let body;
      if (langBase === "yaml" || langBase === "yml") {
        body = highlightYaml(text);
      } else if (langBase === "console") {
        // A console transcript marks its commands with `$ `; the prompt is
        // drawn as a decorative span, and the copy button drops it.
        body = text
          .split("\n")
          .map((line) =>
            line.startsWith("$ ")
              ? `<span class="prompt">$ </span>${escapeHtml(line.slice(2))}`
              : escapeHtml(line)
          )
          .join("\n");
      } else {
        body = escapeHtml(text);
      }

      // The design system's CodeBlock. With a title the copy button sits in
      // the caption row; without one it floats over the code's top right.
      const copy = `<button type="button" class="ec-copy" aria-label="Copy">${COPY_SVG}</button>`;
      const pre = `<pre><code>${body}</code></pre>`;
      return title
        ? `<div class="ec-code" data-block><div class="ec-code-caption"><span>${escapeHtml(
            title
          )}</span>${copy}</div>${pre}</div>`
        : `<div class="ec-code" data-block>${pre}${copy}</div>`;
    },
  };
}

// ---- Front-matter ---------------------------------------------------------
function parsePage(raw, filename) {
  const fm = raw.match(/^\s*<!--\s*page:\s*([\s\S]*?)-->\s*/);
  if (!fm) {
    throw new Error(`build-docs: ${filename} is missing a <!-- page: ... --> header`);
  }
  const meta = {};
  for (const line of fm[1].split("\n")) {
    const kv = line.match(/^\s*([A-Za-z]+)\s*:\s*(.+?)\s*$/);
    if (kv) meta[kv[1]] = kv[2];
  }
  for (const key of ["slug", "title", "nav", "group"]) {
    if (!meta[key]) {
      throw new Error(`build-docs: ${filename} front-matter is missing "${key}"`);
    }
  }
  return { meta, body: raw.slice(fm[0].length).trim() };
}

// ---- Sidebar --------------------------------------------------------------
// Group pages by their `group` (first-seen order); mark the current page with
// aria-current, which is all DocsLayout needs to draw it.
function renderSidebar(pages, currentSlug) {
  const groups = [];
  const index = new Map();
  for (const p of pages) {
    if (!index.has(p.meta.group)) {
      index.set(p.meta.group, groups.length);
      groups.push({ name: p.meta.group, links: [] });
    }
    groups[index.get(p.meta.group)].links.push(p);
  }
  return groups
    .map((g) => {
      const links = g.links
        .map((p) => {
          const aria = p.meta.slug === currentSlug ? ' aria-current="page"' : "";
          return `        <a href="${urlForSlug(p.meta.slug)}"${aria}>${escapeHtml(p.meta.nav)}</a>`;
        })
        .join("\n");
      return `      <div class="ec-sidebar-group">\n        <p class="ec-sidebar-label">${escapeHtml(
        g.name
      )}</p>\n${links}\n      </div>`;
    })
    .join("\n");
}

// ---- Prev / next ----------------------------------------------------------
// The footer pair at the bottom of every docs page. Order is the pages array's
// own order — the numeric filename prefix — so it always matches the sidebar a
// reader just used, and the ends of the run correctly get only one link.
// Both are plain <a>s, so they are real internal links a crawler follows, not
// a JS-driven widget.
function renderPageNav(pages, index) {
  const prev = pages[index - 1];
  const next = pages[index + 1];
  if (!prev && !next) return "";
  // DocsLayout pushes a lone "next" to the right on its own (rel="next").
  const link = (page, rel, label) =>
    `<a href="${urlForSlug(page.meta.slug)}" rel="${rel}"><span>${label}</span>${escapeHtml(
      page.meta.nav
    )}</a>`;
  return `      <nav class="ec-pagenav" aria-label="Pages">${
    prev ? link(prev, "prev", "Previous") : ""
  }${next ? link(next, "next", "Next") : ""}</nav>`;
}

// ---- Changelog --------------------------------------------------------------
// /changelog: the notes of every stable release (releases.mjs), newest first,
// in the docs shell. Each release is an h2, so the notes' own `## What's New`
// and `## Fixes` move down one level to h3.

const MONTHS = [
  "January", "February", "March", "April", "May", "June",
  "July", "August", "September", "October", "November", "December",
];

// The anchor of a release: `v1.33.2` becomes `v1-33-2`. A dot cannot simply be
// dropped, because v1.33.2 and v1.3.32 would then share `v1332`.
const anchorForTag = (tag) => tag.toLowerCase().replace(/[^a-z0-9]+/g, "-");

// Turn the references that GitHub links in a release into links here too: a
// PR or compare URL gets GitHub's short label (`#229`, `v1.0.4...v1.0.5`), and
// `(#666)` and `@user` link to the PR and the profile. Code spans are skipped,
// so `@types/node` or `#1` in code stays literal.
function linkReferences(markdown) {
  const gh = `https://github.com/${REPO}`;
  return markdown
    .split(/(`[^`\n]*`)/)
    .map((part, i) =>
      i % 2
        ? part
        : part
            .replace(
              new RegExp(`(^|[^\\w(\\[</])${gh}/(pull|issues)/(\\d+)\\b`, "g"),
              (_, pre, kind, n) => `${pre}[#${n}](${gh}/${kind}/${n})`
            )
            .replace(
              new RegExp(`(^|[^\\w(\\[</])${gh}/compare/([\\w.-]+\\.\\.\\.[\\w.-]+)`, "g"),
              (_, pre, range) => `${pre}[${range}](${gh}/compare/${range})`
            )
            .replace(/(^|[\s(])#(\d+)\b/g, (_, pre, n) => `${pre}[#${n}](${gh}/pull/${n})`)
            .replace(
              /(^|[^\w.\/@])@([A-Za-z0-9](?:[A-Za-z0-9-]{0,38}))\b/g,
              (_, pre, user) => `${pre}[@${user}](https://github.com/${user})`
            )
    )
    .join("");
}

function renderChangelog(releases) {
  let anchor = "";
  const seenAnchors = new Map();
  const base = buildRenderer(seenAnchors);
  const marked = new Marked({ gfm: true });
  marked.use({
    renderer: {
      code: base.code,
      // Every release has a "What's New", so a heading's anchor starts with
      // its release's: /changelog#v1-33-2-fixes.
      heading({ tokens, depth, text }) {
        const slug = slugifyHeading(text);
        const count = (seenAnchors.get(slug) || 0) + 1;
        seenAnchors.set(slug, count);
        const id = `${anchor}-${count === 1 ? slug : `${slug}-${count}`}`;
        const level = Math.min(depth + 1, 6);
        return `<h${level} id="${id}">${this.parser.parseInline(tokens)}</h${level}>\n`;
      },
      // The notes are text, never markup. A PR title can contain `<`, and
      // GitHub's generated notes copy PR titles in as they are.
      html({ text }) {
        return escapeHtml(text);
      },
    },
  });

  const intro = `<h1>Changelog</h1>\n`;

  const sections = releases.map((release) => {
    anchor = anchorForTag(release.tag);
    seenAnchors.clear();
    const date = new Date(release.publishedAt);
    const day = `${MONTHS[date.getUTCMonth()]} ${date.getUTCDate()}, ${date.getUTCFullYear()}`;
    return (
      `<h2 id="${anchor}">${escapeHtml(release.tag)}</h2>\n` +
      `<p><time datetime="${date.toISOString().slice(0, 10)}">${day}</time> · ` +
      `<a href="${escapeHtml(release.url)}">GitHub ↗</a></p>\n` +
      // GitHub's generated notes open with an HTML comment that names their
      // config. It is for the author, and escaped it would show as text.
      marked.parse(linkReferences(release.body.replace(/<!--[\s\S]*?-->/g, "")))
    );
  });

  return intro + sections.join("");
}

// The changelog's index: every release, grouped by the month it came out in,
// in the markup of the docs sidebar. Each link goes to the release's h2 on
// this page, so a click scrolls to it.
function renderReleaseSidebar(releases) {
  const groups = [];
  for (const release of releases) {
    const date = new Date(release.publishedAt);
    const month = `${MONTHS[date.getUTCMonth()]} ${date.getUTCFullYear()}`;
    if (groups.at(-1)?.name !== month) groups.push({ name: month, links: [] });
    groups.at(-1).links.push(
      `        <a href="#${anchorForTag(release.tag)}">${escapeHtml(release.tag)}</a>`
    );
  }
  return groups
    .map(
      (g) =>
        `      <div class="ec-sidebar-group">\n        <p class="ec-sidebar-label">${escapeHtml(
          g.name
        )}</p>\n${g.links.join("\n")}\n      </div>`
    )
    .join("\n");
}

function writeChangelog(template, releases) {
  const title = "Changelog — Macterm";
  const description =
    "The new features and fixes in each release of Macterm, a native macOS terminal built on libghostty.";
  const canonical = SITE_URL + CHANGELOG_PATH;

  const jsonld = JSON.stringify({
    "@context": "https://schema.org",
    "@graph": [
      {
        "@type": "WebPage",
        name: title,
        description,
        url: canonical,
        inLanguage: "en",
        dateModified: releases[0].publishedAt,
        isPartOf: { "@type": "WebSite", "@id": SITE_URL + "/#website", name: "Macterm", url: SITE_URL + "/" },
        about: {
          "@type": "SoftwareApplication",
          "@id": SITE_URL + "/#app",
          name: "Macterm",
          applicationCategory: "DeveloperApplication",
          operatingSystem: "macOS 14.0 or later",
          softwareVersion: releases[0].tag.replace(/^v/, ""),
          sameAs: ["https://github.com/thdxg/macterm", "https://www.reddit.com/r/macterm"],
        },
      },
      {
        "@type": "BreadcrumbList",
        itemListElement: [
          { "@type": "ListItem", position: 1, name: "Macterm", item: SITE_URL + "/" },
          { "@type": "ListItem", position: 2, name: "Changelog", item: canonical },
        ],
      },
    ],
  });

  const out = template
    .replaceAll("{{TITLE}}", () => escapeHtml(title))
    .replaceAll("{{DESCRIPTION}}", () => escapeHtml(description))
    .replaceAll("{{CANONICAL}}", () => canonical)
    .replaceAll("{{SITE_URL}}", () => SITE_URL)
    .replace("{{JSONLD}}", () => jsonld)
    .replace("<!-- SIDEBAR -->", () => renderReleaseSidebar(releases))
    // The sidebar lists releases here, not the docs, so the foot's link to
    // this same page gives its place to the docs.
    .replace('<a href="/changelog">Changelog</a>', () => '<a href="/docs/">Docs</a>')
    .replace("<!-- CONTENT -->", () => renderChangelog(releases))
    .replace("<!-- PAGENAV -->", () => "");

  writeFileSync(join(PUBLIC_DIR, "changelog.html"), out);
}

// The file that the host wrote (releases.mjs says why), or GitHub when there
// is none, as in a plain `bun run build` in a checkout.
async function loadReleases() {
  if (existsSync(RELEASES_FILE)) {
    return JSON.parse(readFileSync(RELEASES_FILE, "utf8"));
  }
  return fetchReleases();
}

async function main() {
  const files = readdirSync(PAGES_DIR)
    .filter((f) => f.endsWith(".md"))
    .sort();
  if (!files.length) {
    throw new Error("build-docs: no .md files in docs/pages/");
  }

  const pages = files.map((f) => {
    const parsed = parsePage(readFileSync(join(PAGES_DIR, f), "utf8"), f);
    return { ...parsed, file: f };
  });

  const template = readFileSync(TEMPLATE, "utf8");
  // Anchors are unique per page, so the table is cleared before each one.
  const seenAnchors = new Map();
  const marked = new Marked({ gfm: true });
  marked.use({ renderer: buildRenderer(seenAnchors) });

  mkdirSync(OUT_DIR, { recursive: true });

  for (const [index, page] of pages.entries()) {
    seenAnchors.clear();
    const content = marked.parse(page.body);
    const sidebar = renderSidebar(pages, page.meta.slug);
    const title =
      page.meta.slug === "index"
        ? "Macterm Docs"
        : `${page.meta.title} — Macterm Docs`;
    const description =
      page.meta.description ||
      "Install, configure, and drive Macterm — a native macOS terminal built on libghostty.";
    const canonical = SITE_URL + urlForSlug(page.meta.slug);

    // TechArticle + breadcrumb, so search engines understand the docs tree.
    //
    // The SoftwareApplication carries the same @id the landing page's own
    // JSON-LD uses, so every docs page reinforces one entity rather than
    // declaring a new nameless app per page — which is what tells Google that
    // "Macterm" here is this app and not the unrelated 1990s MacTerm/MacTelnet
    // that currently owns the brand query.
    const jsonld = JSON.stringify({
      "@context": "https://schema.org",
      "@graph": [
        {
          "@type": "TechArticle",
          headline: page.meta.title,
          name: page.meta.title,
          description,
          url: canonical,
          inLanguage: "en",
          image: SITE_URL + "/img/og.png",
          isPartOf: {
            "@type": "WebSite",
            "@id": SITE_URL + "/#website",
            name: "Macterm",
            url: SITE_URL + "/",
          },
          about: {
            "@type": "SoftwareApplication",
            "@id": SITE_URL + "/#app",
            name: "Macterm",
            applicationCategory: "DeveloperApplication",
            operatingSystem: "macOS 14.0 or later",
            sameAs: ["https://github.com/thdxg/macterm", "https://www.reddit.com/r/macterm"],
          },
        },
        {
          "@type": "BreadcrumbList",
          itemListElement: [
            { "@type": "ListItem", position: 1, name: "Macterm", item: SITE_URL + "/" },
            { "@type": "ListItem", position: 2, name: "Docs", item: SITE_URL + "/docs/" },
            ...(page.meta.slug === "index"
              ? []
              : [
                  {
                    "@type": "ListItem",
                    position: 3,
                    name: page.meta.title,
                    item: canonical,
                  },
                ]),
          ],
        },
      ],
    });

    // Function replacements so `$`-sequences in content aren't treated as
    // replacement patterns.
    const out = template
      .replaceAll("{{TITLE}}", () => escapeHtml(title))
      .replaceAll("{{DESCRIPTION}}", () => escapeHtml(description))
      .replaceAll("{{CANONICAL}}", () => canonical)
      .replaceAll("{{SITE_URL}}", () => SITE_URL)
      .replace("{{JSONLD}}", () => jsonld)
      .replace("<!-- SIDEBAR -->", () => sidebar)
      .replace("<!-- CONTENT -->", () => content)
      .replace("<!-- PAGENAV -->", () => renderPageNav(pages, index));

    writeFileSync(join(OUT_DIR, `${page.meta.slug}.html`), out);
  }

  const releases = await loadReleases();
  writeChangelog(template, releases);

  writeSitemapAndRobots(pages, releases);

  console.log(
    `build-docs: wrote ${pages.length} pages to ${OUT_DIR} (${files.join(", ")}), ` +
      `and ${CHANGELOG_PATH} with ${releases.length} releases`
  );
}

// The lastmod of each page source, see lastmod.mjs. Git answers in a checkout.
// In the image build there is no git, so the host wrote docs/lastmod.json into
// the build context first. Git comes first so that a stale file in a checkout
// never wins. With neither, the sitemap gets no lastmod and check-seo.mjs
// fails the build, because a sitemap without the dates is a silent regression.
function loadLastModified() {
  try {
    return lastModifiedDates();
  } catch (err) {
    if (existsSync(LASTMOD_FILE)) {
      return JSON.parse(readFileSync(LASTMOD_FILE, "utf8"));
    }
    console.warn(
      `build-docs: no lastmod for the sitemap (${err.message}; ${LASTMOD_FILE} is absent)`
    );
    return {};
  }
}

// Emit sitemap.xml (landing + every docs page) and robots.txt into public/.
//
// `changefreq` is deliberately absent: Google has said for years that it
// ignores the element outright, so emitting `weekly` on every URL was pure
// noise.
//
// `lastmod` is the commit date of the page's source (lastmod.mjs says why a
// file mtime cannot serve). The template and the build script do not count:
// Google reads lastmod as "the content changed", and a template change moves
// no content.
//
// `priority` is advisory-at-best, but it is cheap, stable, and honest: it says
// the landing page and docs index matter more than page 9 of the docs, which
// is true and does not change per build.
//
// The changelog's lastmod is the date of its newest release, because a release
// is the only thing that changes it.
function writeSitemapAndRobots(pages, releases) {
  const lastmod = loadLastModified();
  const entries = [
    { url: SITE_URL + "/", priority: "1.0", lastmod: lastmod[LANDING_SOURCE] },
    ...pages.map((p) => ({
      url: SITE_URL + urlForSlug(p.meta.slug),
      priority: p.meta.slug === "index" ? "0.9" : "0.7",
      lastmod: lastmod[pageSource(p.file)],
    })),
    {
      url: SITE_URL + CHANGELOG_PATH,
      priority: "0.8",
      lastmod: new Date(releases[0].publishedAt).toISOString(),
    },
  ];

  const sitemap =
    `<?xml version="1.0" encoding="UTF-8"?>\n` +
    `<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n` +
    entries
      .map(
        (e) =>
          `  <url>\n    <loc>${e.url}</loc>\n` +
          (e.lastmod ? `    <lastmod>${e.lastmod}</lastmod>\n` : "") +
          `    <priority>${e.priority}</priority>\n  </url>`
      )
      .join("\n") +
    `\n</urlset>\n`;
  writeFileSync(join(PUBLIC_DIR, "sitemap.xml"), sitemap);

  // Everything is crawlable, /img/ included — those derivatives are what the
  // pages actually reference now, so blocking them would hide every screenshot
  // on the site from image search and break the OG card's preview fetch.
  const robots = [
    "User-agent: *",
    "Allow: /",
    "",
    `Sitemap: ${SITE_URL}/sitemap.xml`,
    "",
  ].join("\n");
  writeFileSync(join(PUBLIC_DIR, "robots.txt"), robots);
}

await main();
