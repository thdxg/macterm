// Renders the repo's full-resolution PNGs into web-sized derivatives under
// public/img/ at build time.
//
// Why this exists: assets/ holds the originals the README and the release
// notes use — 3168x1956 screenshots, ~2.5MB each, and a 1024x1024 icon. The
// landing page displays the hero at ~1000 CSS px, so shipping the original
// meant a 2.5MB LCP image for a 1000px slot. That is the page's largest
// element, so it *is* the Largest Contentful Paint, and Core Web Vitals is a
// ranking signal — the original alone put the page well outside the 2.5s
// threshold on anything but a fast connection.
//
// The originals stay untouched and authoritative; everything here is a
// generated artifact (public/img/ is gitignored), so replacing a screenshot in
// assets/ is still a one-file change and the derivatives can never go stale.
//
// Outputs, per screenshot:
//   img/<name>-<width>.webp   the responsive srcset (WEBP_QUALITY)
//   img/<name>-1400.png       the <picture> fallback for a WebP-less client
// Plus, once:
//   img/og.png                1200x630 social card, letterboxed on the canvas
//   img/icon-<size>.png       favicon and apple-touch-icon sizes
//
// Reads from public/assets/ rather than ../assets/ because that is the path
// that exists in both trees: locally it is a symlink to the repo-root assets/,
// and the Dockerfile replaces it with real files copied from the build context.

import { readdirSync, mkdirSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import sharp from "sharp";

const here = dirname(fileURLToPath(import.meta.url));
const SRC_DIR = join(here, "public", "assets");
const OUT_DIR = join(here, "public", "img");

// The hero is capped at 1100 CSS px by the landing page's `max-width: 1180px`
// figure minus 40px padding on each side, so 2200 covers it at 2x DPR. We also
// include 3132 (the original width) for 3x displays and zoom.
const WIDTHS = [640, 1000, 1400, 2200, 3132];
// The width the <picture> fallback <img> is emitted at. Only reached by a
// client with no WebP support, so it trades bytes for compatibility.
const FALLBACK_WIDTH = 1400;
const WEBP_QUALITY = 90;

// Open Graph's canonical card size. Cropping the wider-than-tall screenshots
// to this 1.90:1 box would cut the sidebar or the shell out of frame, so the
// image is letterboxed onto the site's own ground instead — the whole
// screenshot stays visible and the bars read as intentional matting. The
// colour tracks the landing page's --l-bg; a cream card behind a dark site
// reads as a rendering bug in every link preview.
const OG = { width: 1200, height: 630, background: "#19191a" };

// The landing page's gallery hard-codes five thumbnails, one per screenshot,
// so a missing source is a 404 in production rather than a smaller gallery.
// The build doesn't fail on it — a contributor touching only CSS shouldn't be
// blocked by an asset they never touched — but it must not pass silently.
const EXPECTED_SCREENSHOTS = 5;

// 180 is the apple-touch-icon size iOS actually asks for; 32 and 16 are the
// classic favicon rungs. The 1024x1024 original is an 810KB app icon and has
// no business being either.
const ICON_SIZES = [180, 32, 16];

async function buildScreenshots() {
  const sources = readdirSync(SRC_DIR)
    .filter((f) => /^screenshot-\d+\.png$/.test(f))
    .sort();
  if (!sources.length) {
    throw new Error(`build-images: no screenshot-*.png in ${SRC_DIR}`);
  }

  for (const file of sources) {
    const name = file.replace(/\.png$/, "");
    const input = join(SRC_DIR, file);
    const { width: srcWidth } = await sharp(input).metadata();

    for (const width of WIDTHS) {
      // Never upscale — a derivative wider than the original is bytes spent to
      // add no detail. A screenshot smaller than a rung simply skips it, and
      // the srcset the page emits is filtered to match.
      if (srcWidth && width > srcWidth) continue;
      await sharp(input)
        .resize({ width, withoutEnlargement: true })
        .webp({ quality: WEBP_QUALITY, smartSubsample: true })
        .toFile(join(OUT_DIR, `${name}-${width}.webp`));
    }

    await sharp(input)
      .resize({ width: FALLBACK_WIDTH, withoutEnlargement: true })
      .png({ compressionLevel: 9, palette: true })
      .toFile(join(OUT_DIR, `${name}-${FALLBACK_WIDTH}.png`));
  }

  const missing = [];
  for (let n = 1; n <= EXPECTED_SCREENSHOTS; n++) {
    if (!sources.includes(`screenshot-${n}.png`)) missing.push(`screenshot-${n}.png`);
  }
  if (missing.length) {
    console.warn(
      `build-images: WARNING — public/index.html's gallery expects ` +
        `${EXPECTED_SCREENSHOTS} screenshots; missing ${missing.join(", ")}. ` +
        `Those thumbnails will 404. Add them to assets/ and rebuild.`
    );
  }

  return sources.length;
}

async function buildOgCard() {
  const input = join(SRC_DIR, "screenshot-1.png");
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

async function buildIcons() {
  const input = join(SRC_DIR, "icon.png");
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
  const count = await buildScreenshots();
  await buildOgCard();
  await buildIcons();
  console.log(
    `build-images: wrote ${count} screenshot set(s), og.png, and ${ICON_SIZES.length} icons to ${OUT_DIR}`
  );
}

await main();
