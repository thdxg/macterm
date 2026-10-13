// Renders the repo's full-resolution PNGs into web-sized derivatives under
// public/img/ at build time.
//
// The pages show no screenshot (the landing page plays the recordings in
// assets/demo/), so the only images left to render are the ones every page
// loads in its <head>:
//   img/og.png                1200x630 social card, letterboxed on the canvas
//   img/icon-<size>.png       favicon, apple-touch-icon and header brand mark
//
// The originals in assets/ stay untouched and authoritative; everything here is
// a generated artifact (public/img/ is gitignored), so replacing an original is
// still a one-file change and the derivatives can never go stale.
//
// Reads from public/assets/ rather than ../assets/ because that is the path
// that exists in both trees: locally it is a symlink to the repo-root assets/,
// and the Containerfile replaces it with real files copied from the build context.

import { mkdirSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import sharp from "sharp";

const here = dirname(fileURLToPath(import.meta.url));
const SRC_DIR = join(here, "public", "assets");
const OUT_DIR = join(here, "public", "img");

// Open Graph's canonical card size. Cropping the wider-than-tall hero to this
// 1.90:1 box would cut the sidebar or the shell out of frame, so the image is
// letterboxed onto the site's own ground instead — the whole image stays
// visible and the bars read as intentional matting. The colour is the design
// system's `page` token; a card on a different ground than the site reads as a
// rendering bug in every link preview.
const OG = { width: 1200, height: 630, background: "#111214" };

// 180 is the apple-touch-icon size iOS actually asks for; 32 and 16 are the
// classic favicon rungs. The 730x730 original has no business being either.
const ICON_SIZES = [180, 32, 16];

// From the hero, the same image the repo README leads with.
async function buildOgCard() {
  const input = join(SRC_DIR, "hero.png");
  if (!existsSync(input)) {
    throw new Error(`build-images: ${input} is missing — no OG card to build`);
  }
  await sharp(input)
    .resize({
      width: OG.width,
      height: OG.height,
      fit: "contain",
      background: OG.background,
    })
    .png({ compressionLevel: 9 })
    .toFile(join(OUT_DIR, "og.png"));
}

// Built from the bare glyph, not the full app icon: the site's brand mark sits
// on the header's own dark ground and a favicon sits on the browser's, so the
// icon's background plate would read as a plate rather than as the mark. The
// glyph is full-bleed in its canvas (729 of 730px), so it needs no re-cropping.
async function buildIcons() {
  const input = join(SRC_DIR, "icons", "glyph.png");
  if (!existsSync(input)) {
    throw new Error(`build-images: ${input} is missing — no icons to build`);
  }
  for (const size of ICON_SIZES) {
    await sharp(input)
      .resize({ width: size, height: size })
      .png({ compressionLevel: 9 })
      .toFile(join(OUT_DIR, `icon-${size}.png`));
  }
}

async function main() {
  mkdirSync(OUT_DIR, { recursive: true });
  await buildOgCard();
  await buildIcons();
  console.log(`build-images: wrote og.png and ${ICON_SIZES.length} icons to ${OUT_DIR}`);
}

await main();
