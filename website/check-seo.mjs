// Build-time guard for the two SEO invariants nothing else can enforce.
// Runs after build-docs.mjs; exits non-zero (failing `bun run build`, and so
// the Docker build and CI) when either is broken.
//
// 1. THE FAQ IS WRITTEN TWICE. public/index.html is hand-authored and no build
//    step rewrites it, so the visible <section id="faq"> markup and the
//    FAQPage JSON-LD in its <head> are two copies of the same eight questions.
//    Google's FAQ structured-data policy requires the question and answer text
//    to appear verbatim on the page; markup whose text is not visible is
//    ineligible for the rich result and is the kind of thing that earns a
//    manual action. The two copies had already drifted once during authoring —
//    five of eight questions were reworded in the visible markup only, which is
//    invisible in every browser and in every local preview. This check compares
//    them and says which entry moved.
//
// 2. THE CANONICAL ORIGIN IS WRITTEN TWICE. build-docs.mjs owns SITE_URL for
//    every generated docs page, but index.html carries its own inline
//    canonical, og:url, and JSON-LD @ids. A domain change that updated only the
//    constant would leave the landing page — the site's most important URL —
//    pointing its canonical at the old origin.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join, basename } from "node:path";
import { readdirSync } from "node:fs";

const here = dirname(fileURLToPath(import.meta.url));
const INDEX = join(here, "public", "index.html");
const DOCS_DIR = join(here, "public", "docs");

// Kept in step with build-docs.mjs's own constant; invariant 2 is what makes a
// disagreement between the two an error rather than a silent inconsistency.
const SITE_URL = "https://macterm.thdxg.dev";

const problems = [];

const decodeEntities = (s) =>
  s
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&amp;/g, "&");

// Visible text of an HTML fragment, normalized the way a reader sees it:
// tags dropped, whitespace collapsed. Links and <code> inside an answer
// contribute their text, which is exactly what the JSON-LD should carry.
const visibleText = (fragment) =>
  decodeEntities(fragment.replace(/<[^>]+>/g, "")).replace(/\s+/g, " ").trim();

function jsonLdBlocks(html, label) {
  const blocks = [
    ...html.matchAll(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/g),
  ].map((m) => m[1]);
  if (!blocks.length) {
    problems.push(`${label}: no JSON-LD block found`);
    return [];
  }
  const parsed = [];
  for (const raw of blocks) {
    try {
      parsed.push(JSON.parse(raw));
    } catch (err) {
      problems.push(`${label}: JSON-LD does not parse — ${err.message}`);
    }
  }
  return parsed;
}

// ---- 1. FAQ markup vs FAQPage JSON-LD -------------------------------------
function checkFaqMirrorsMarkup(html) {
  const section = html.match(/<section id="faq"[\s\S]*?<\/section>/);
  const graph = jsonLdBlocks(html, "index.html").flatMap((d) => d["@graph"] ?? [d]);
  const faq = graph.find((n) => n["@type"] === "FAQPage");

  // Having no FAQ at all is a valid state — the landing page carried one for a
  // while and then dropped it. What must never happen is one half without the
  // other, in either direction, so the asymmetric cases are the errors.
  if (!section && !faq) return;

  if (!section) {
    problems.push(
      "index.html: FAQPage JSON-LD is present but there is no visible " +
        '<section id="faq">. Google requires the question and answer text to ' +
        "appear on the page; schema-only markup is ineligible for the rich " +
        "result and is the kind of thing that earns a manual action. Remove " +
        "the JSON-LD or restore the section."
    );
    return;
  }

  const visible = [
    ...section[0].matchAll(
      /<div class="l-qa">\s*<h3>([\s\S]*?)<\/h3>\s*<p>([\s\S]*?)<\/p>/g
    ),
  ].map((m) => ({ q: visibleText(m[1]), a: visibleText(m[2]) }));

  if (!visible.length) {
    problems.push("index.html: FAQ section has no .l-qa entries to compare");
    return;
  }

  if (!faq) {
    problems.push("index.html: FAQ markup is present but there is no FAQPage JSON-LD");
    return;
  }

  const schema = (faq.mainEntity ?? []).map((q) => ({
    q: (q.name ?? "").replace(/\s+/g, " ").trim(),
    a: (q.acceptedAnswer?.text ?? "").replace(/\s+/g, " ").trim(),
  }));

  if (schema.length !== visible.length) {
    problems.push(
      `index.html: FAQ has ${visible.length} visible question(s) but ${schema.length} in JSON-LD`
    );
  }

  for (let i = 0; i < Math.min(schema.length, visible.length); i++) {
    if (schema[i].q !== visible[i].q) {
      problems.push(
        `index.html: FAQ #${i + 1} question differs.\n` +
          `      visible: ${visible[i].q}\n` +
          `      JSON-LD: ${schema[i].q}`
      );
    }
    if (schema[i].a !== visible[i].a) {
      problems.push(
        `index.html: FAQ #${i + 1} ("${visible[i].q}") answer differs.\n` +
          `      visible: ${visible[i].a}\n` +
          `      JSON-LD: ${schema[i].a}`
      );
    }
  }
}

// ---- 2. index.html agrees with SITE_URL ------------------------------------
function checkLandingOrigin(html) {
  const canonical = html.match(/<link rel="canonical" href="([^"]+)"/);
  if (!canonical) {
    problems.push("index.html: no canonical link");
  } else if (canonical[1] !== SITE_URL + "/") {
    problems.push(
      `index.html: canonical is ${canonical[1]}, expected ${SITE_URL}/ ` +
        `(SITE_URL in build-docs.mjs)`
    );
  }

  const ogUrl = html.match(/<meta property="og:url" content="([^"]+)"/);
  if (ogUrl && ogUrl[1] !== SITE_URL + "/") {
    problems.push(`index.html: og:url is ${ogUrl[1]}, expected ${SITE_URL}/`);
  }

  // Any absolute macterm URL in the landing page that names a different origin
  // is a leftover from a domain move.
  const foreign = [...html.matchAll(/https:\/\/[a-z0-9.-]*macterm[a-z0-9.-]*/g)]
    .map((m) => m[0])
    .filter((u) => !u.startsWith(SITE_URL) && !u.includes("github.com"));
  for (const u of new Set(foreign)) {
    problems.push(`index.html: absolute URL ${u} does not match SITE_URL ${SITE_URL}`);
  }
}

// ---- 3. Every generated docs page still carries valid JSON-LD --------------
function checkDocsPages() {
  let files;
  try {
    files = readdirSync(DOCS_DIR).filter((f) => f.endsWith(".html"));
  } catch {
    problems.push(`check-seo: ${DOCS_DIR} is missing — run build:docs first`);
    return;
  }
  for (const f of files) {
    const html = readFileSync(join(DOCS_DIR, f), "utf8");
    jsonLdBlocks(html, `docs/${basename(f)}`);
    if (!/<link rel="canonical" href="https:\/\//.test(html)) {
      problems.push(`docs/${f}: missing an absolute canonical link`);
    }
  }
}

const index = readFileSync(INDEX, "utf8");
checkFaqMirrorsMarkup(index);
checkLandingOrigin(index);
checkDocsPages();

if (problems.length) {
  console.error("check-seo: FAILED\n");
  for (const p of problems) console.error(`  - ${p}`);
  console.error("");
  process.exit(1);
}

console.log("check-seo: ok (FAQ markup matches JSON-LD, origins agree, JSON-LD parses)");
