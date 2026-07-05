// Renders website/docs/pages/*.md into a multi-page docs site under
// public/docs/ at build time.
//
// The site is static files behind a Cloudflare Worker, so the docs ship as
// plain HTML — no client-side Markdown parser, no content flash. Each Markdown
// file is one page; a shared sidebar links across pages and marks the current
// one active. Cloudflare's auto-trailing-slash html handling serves
// public/docs/install.html at /docs/install and public/docs/index.html at
// /docs/.
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
//   ```lang title="path"     fenced code -> dark code block; title="" adds a
//                            filename caption bar.
//   > blockquote             the left-ruled aside style.

import { readFileSync, writeFileSync, readdirSync, mkdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { Marked } from "marked";

const here = dirname(fileURLToPath(import.meta.url));
const PAGES_DIR = join(here, "docs", "pages");
const TEMPLATE = join(here, "src", "docs-template.html");
const OUT_DIR = join(here, "public", "docs");

const COPY_SVG = `<svg data-i="copy" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="block"><rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg><svg data-i="check" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" style="display:none"><path d="M20 6 9 17l-5-5"/></svg>`;

const escapeHtml = (s) =>
  s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");

// The clean URL for a page's slug. The intro is the docs index.
const urlForSlug = (slug) => (slug === "index" ? "/docs/" : `/docs/${slug}`);

// ---- Minimal YAML-ish syntax highlighting for the layout sample -----------
// Works on the raw source and escapes each emitted piece itself (highlighting-
// then-escaping would mangle the quotes it keys on). Handles top-level
// `key: value`, list dashes, `#` comments, and inline flow maps.
const span = (cls, text) => `<span class="${cls}">${escapeHtml(text)}</span>`;

function highlightValue(val) {
  const trimmed = val.trim();
  if (!trimmed) return escapeHtml(val);
  const lead = val.slice(0, val.indexOf(trimmed));
  const tail = val.slice(val.indexOf(trimmed) + trimmed.length);
  if (trimmed.startsWith("{") && trimmed.endsWith("}")) {
    return escapeHtml(lead) + highlightFlowMap(trimmed) + escapeHtml(tail);
  }
  const cls = /^".*"$/.test(trimmed) ? "text-syn-str" : "text-syn-val";
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
      span("text-syn-key", key) +
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
        comment = span("text-syn-comment", cm[1]);
        line = line.slice(0, cm.index);
      }
      let dash = "";
      const dm = line.match(/^(\s*)(- )/);
      if (dm) {
        dash = escapeHtml(dm[1]) + span("text-syn-dash", dm[2]);
        line = line.slice(dm[0].length);
      }
      const km = line.match(/^(\s*)([A-Za-z0-9_-]+)(\s*:\s*)([\s\S]*)$/);
      if (km) {
        const [, sp, key, colon, val] = km;
        return (
          dash +
          escapeHtml(sp) +
          span("text-syn-key", key) +
          escapeHtml(colon) +
          highlightValue(val) +
          comment
        );
      }
      return dash + escapeHtml(line) + comment;
    })
    .join("\n");
}

// ---- Markdown renderer: dark code blocks ----------------------------------
function buildRenderer() {
  return {
    code({ text, lang }) {
      const langBase = (lang || "").split(/\s+/)[0];
      const titleMatch = (lang || "").match(/title="([^"]*)"/);
      const title = titleMatch ? titleMatch[1] : null;
      const body =
        langBase === "yaml" || langBase === "yml"
          ? highlightYaml(text)
          : escapeHtml(text);

      const caption = title
        ? `<div class="code-block-caption"><span>${escapeHtml(
            title
          )}</span><button type="button" data-copy aria-label="Copy" class="code-block-copy">${COPY_SVG}</button></div>`
        : `<button type="button" data-copy aria-label="Copy" class="code-block-copy">${COPY_SVG}</button>`;

      return `<div data-block class="code-block">${caption}<pre><code>${body}</code></pre></div>`;
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
// Group pages by their `group` (first-seen order); mark the current page active.
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
          const active = p.meta.slug === currentSlug ? " is-active" : "";
          const aria = active ? ' aria-current="page"' : "";
          return `        <a href="${urlForSlug(p.meta.slug)}" class="${
            active ? "is-active" : ""
          }"${aria}>${escapeHtml(p.meta.nav)}</a>`;
        })
        .join("\n");
      return `      <div class="docs-sidebar-group">\n        <div class="docs-sidebar-label">${escapeHtml(
        g.name
      )}</div>\n${links}\n      </div>`;
    })
    .join("\n");
}

function main() {
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
  const marked = new Marked({ gfm: true });
  marked.use({ renderer: buildRenderer() });

  mkdirSync(OUT_DIR, { recursive: true });

  for (const page of pages) {
    const content = marked.parse(page.body);
    const sidebar = renderSidebar(pages, page.meta.slug);
    const title =
      page.meta.slug === "index"
        ? "Macterm Docs"
        : `${page.meta.title} — Macterm Docs`;
    const description =
      page.meta.description ||
      "Install, configure, and drive Macterm — a native macOS terminal built on libghostty.";

    // Function replacements so `$`-sequences in content aren't treated as
    // replacement patterns.
    const out = template
      .replaceAll("{{TITLE}}", () => escapeHtml(title))
      .replaceAll("{{DESCRIPTION}}", () => escapeHtml(description))
      .replace("<!-- SIDEBAR -->", () => sidebar)
      .replace("<!-- CONTENT -->", () => content);

    writeFileSync(join(OUT_DIR, `${page.meta.slug}.html`), out);
  }

  console.log(
    `build-docs: wrote ${pages.length} pages to ${OUT_DIR} (${files.join(", ")})`
  );
}

main();
