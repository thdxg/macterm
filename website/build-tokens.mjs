// Compiles the eyesclosed design system's tokens into the two stylesheets
// every page loads: public/tokens.css (generated from design-system/
// tokens.json) and public/components/bundle.css (design-system/bundle.css,
// copied as is).
//
// design-system/ is a vendored copy of the system's own files, never edited
// here: re-sync it from the system and rebuild. tokens.css is compiled the way
// the system compiles it — color and shadow tokens under
// `:root, [data-theme="<first theme>"]`, an alias `{name}` becoming
// `var(--name)`; every other token family plus one `--font-<key>` per family
// stack under `:root`; and one class per type style.

import { readFileSync, writeFileSync, mkdirSync, copyFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const SRC = join(here, "design-system");
const PUBLIC_DIR = join(here, "public");

const tokens = JSON.parse(readFileSync(join(SRC, "tokens.json"), "utf8"));

const value = (v) =>
  typeof v === "string" ? v.replace(/^\{([A-Za-z0-9_.-]+)\}$/, "var(--$1)") : String(v);
const decl = (name, v) => `  --${name}: ${value(v)};`;

const themes = tokens.color.themes;
const first = themes[0].id;
const themed = [...tokens.color.tokens, ...(tokens.shadow?.tokens ?? [])];
const valueIn = (t, theme) => (typeof t.value === "string" ? t.value : t.value[theme]);

const blocks = [`/* ${tokens.name} — generated from tokens.json */`];

blocks.push(
  `:root, [data-theme="${first}"] {\n` +
    themed.map((t) => decl(t.name, valueIn(t, first))).join("\n") +
    `\n}`
);
for (const theme of themes.slice(1)) {
  const overrides = themed.filter(
    (t) => typeof t.value === "object" && t.value[theme.id] !== undefined
  );
  blocks.push(
    `[data-theme="${theme.id}"] {\n` +
      overrides.map((t) => decl(t.name, t.value[theme.id])).join("\n") +
      `\n}`
  );
}

const SKIP = new Set(["name", "version", "meta", "color", "shadow", "type"]);
const rootDecls = [];
for (const [family, body] of Object.entries(tokens)) {
  if (SKIP.has(family) || !Array.isArray(body?.tokens)) continue;
  for (const t of body.tokens) rootDecls.push(decl(t.name, t.value));
}
for (const [key, stack] of Object.entries(tokens.type.families)) {
  rootDecls.push(`  --font-${key}: ${stack};`);
}
blocks.push(`:root {\n${rootDecls.join("\n")}\n}`);

const px = (v) => (typeof v === "number" ? `${v}px` : v);
for (const group of tokens.type.groups) {
  for (const s of group.styles) {
    const props = [
      `font-family: var(--font-${s.family ?? group.family});`,
      `font-size: ${px(s.fontSize)};`,
      s.lineHeight !== undefined && `line-height: ${s.lineHeight};`,
      s.fontWeight !== undefined && `font-weight: ${s.fontWeight};`,
      s.letterSpacing !== undefined && `letter-spacing: ${px(s.letterSpacing)};`,
      s.fontStyle && `font-style: ${s.fontStyle};`,
    ].filter(Boolean);
    blocks.push(`.${s.name} { ${props.join(" ")} }`);
  }
}

for (const font of tokens.type.fonts) {
  blocks.push(
    `@font-face { font-family: "${font.family}"; src: url("/${font.file}"); ` +
      `font-weight: ${font.weight ?? "400"}; font-style: ${font.style ?? "normal"}; font-display: swap; }`
  );
}

writeFileSync(join(PUBLIC_DIR, "tokens.css"), blocks.join("\n\n") + "\n");
mkdirSync(join(PUBLIC_DIR, "components"), { recursive: true });
copyFileSync(join(SRC, "bundle.css"), join(PUBLIC_DIR, "components", "bundle.css"));

console.log("build-tokens: wrote public/tokens.css and public/components/bundle.css");
