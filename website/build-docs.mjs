// Renders website/docs/docs.md into public/docs.html at build time.
//
// The site is static files behind a Cloudflare Worker, so the docs ship as
// plain HTML — no client-side Markdown parser, no content flash. This script
// turns the Markdown into the design's prose + dark code blocks and generates
// the sidebar from section markers.
//
// Markdown conventions:
//   <!-- section: <id> | <Nav label> | <Group name> -->
//       Starts a new page section. The section becomes <section id="<id>">,
//       the sidebar gets a link labeled <Nav label> under heading <Group name>.
//   ```lang title="path"      Fenced code -> dark code block; title="" adds a
//                             filename caption bar.
//   > blockquote              -> the left-ruled aside style.

import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { Marked } from "marked";

const here = dirname(fileURLToPath(import.meta.url));
const DOCS_MD = join(here, "docs", "docs.md");
const TEMPLATE = join(here, "src", "docs-template.html");
const OUT = join(here, "public", "docs.html");

const COPY_SVG = `<svg data-i="copy" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="block"><rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg><svg data-i="check" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" style="display:none"><path d="M20 6 9 17l-5-5"/></svg>`;

const escapeHtml = (s) =>
  s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");

// Minimal YAML-ish syntax highlighting for the layout sample, matching the
// design's token colors. Works on the raw source and escapes each emitted
// piece itself (highlighting-then-escaping would mangle the quotes it keys on).
// Handles top-level `key: value`, leading list dashes, trailing `//` and `#`
// comments, and inline flow maps like `{ cwd: "./api", run: "x" }`.
const span = (cls, text) => `<span class="${cls}">${escapeHtml(text)}</span>`;

function highlightValue(val) {
  const trimmed = val.trim();
  if (!trimmed) return escapeHtml(val);
  // Preserve surrounding whitespace, color the token.
  const lead = val.slice(0, val.indexOf(trimmed));
  const tail = val.slice(val.indexOf(trimmed) + trimmed.length);
  if (trimmed.startsWith("{") && trimmed.endsWith("}")) {
    return escapeHtml(lead) + highlightFlowMap(trimmed) + escapeHtml(tail);
  }
  const cls = /^".*"$/.test(trimmed) ? "text-syn-str" : "text-syn-val";
  return escapeHtml(lead) + span(cls, trimmed) + escapeHtml(tail);
}

function highlightFlowMap(text) {
  // text is "{ k: v, k2: v2 }" — color braces/commas plain, keys and values.
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
      // Trailing // or # comment (outside of quotes — the sample has none).
      let comment = "";
      const cm = line.match(/(\s+(?:\/\/|#).*)$/);
      if (cm) {
        comment = span("text-syn-comment", cm[1]);
        line = line.slice(0, cm.index);
      }
      // Leading "- " list dash.
      let dash = "";
      const dm = line.match(/^(\s*)(- )/);
      if (dm) {
        dash = escapeHtml(dm[1]) + span("text-syn-dash", dm[2]);
        line = line.slice(dm[0].length);
      }
      // key: value
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

function buildRenderer() {
  const renderer = {
    code({ text, lang }) {
      // lang may carry `title="..."` (e.g. ```yaml title=".macterm/layout.yaml").
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
  return renderer;
}

function main() {
  const raw = readFileSync(DOCS_MD, "utf8");

  // Split into sections on the <!-- section: <id> | <label> | <group> -->
  // markers. The group (last field) is captured non-greedily up to the closing
  // --> so a hyphen in a group name doesn't truncate it.
  const marker = /<!--\s*section:\s*([^|]+)\|([^|]+)\|(.+?)\s*-->/g;
  const sections = [];
  let m;
  let current = null;
  const flush = (endIdx) => {
    if (current) {
      current.md = raw.slice(current.bodyStart, endIdx).trim();
      sections.push(current);
    }
  };
  while ((m = marker.exec(raw)) !== null) {
    flush(m.index);
    current = {
      id: m[1].trim(),
      label: m[2].trim(),
      group: m[3].trim(),
      bodyStart: marker.lastIndex,
    };
  }
  flush(raw.length);

  if (!sections.length) {
    throw new Error("build-docs: no <!-- section: ... --> markers found");
  }

  const marked = new Marked({ gfm: true });
  marked.use({ renderer: buildRenderer() });

  // Render each section body, wrapping in <section id> with a divider between.
  const contentParts = sections.map((s, i) => {
    const html = marked.parse(s.md);
    const hr = i < sections.length - 1 ? "\n<hr />" : "";
    return `<section id="${s.id}" data-section>\n${html}\n</section>${hr}`;
  });
  const content = contentParts.join("\n");

  // Build the sidebar: group links by their `group`, preserving first-seen order.
  const groups = [];
  const groupIndex = new Map();
  for (const s of sections) {
    if (!groupIndex.has(s.group)) {
      groupIndex.set(s.group, groups.length);
      groups.push({ name: s.group, links: [] });
    }
    groups[groupIndex.get(s.group)].links.push(s);
  }
  const sidebar = groups
    .map((g) => {
      const links = g.links
        .map(
          (l) =>
            `        <a data-nav-link href="#${l.id}">${escapeHtml(
              l.label
            )}</a>`
        )
        .join("\n");
      return `      <div class="docs-sidebar-group">\n        <div class="docs-sidebar-label">${escapeHtml(
        g.name
      )}</div>\n${links}\n      </div>`;
    })
    .join("\n");

  const template = readFileSync(TEMPLATE, "utf8");
  // Function replacements so `$`-sequences in the content (e.g. shell `$`)
  // aren't interpreted as replacement patterns.
  const out = template
    .replace("<!-- SIDEBAR -->", () => sidebar)
    .replace("<!-- CONTENT -->", () => content);
  writeFileSync(OUT, out);
  console.log(
    `build-docs: wrote ${OUT} (${sections.length} sections, ${groups.length} groups)`
  );
}

main();
