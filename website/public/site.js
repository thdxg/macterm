// Shared behavior for the Macterm marketing site + docs.
// Every feature is opt-in by DOM presence, so one script drives both pages.
//
// The sticky-nav, hamburger, and reveal-on-scroll modules were dropped with the
// dark redesign: its header is a plain bordered bar with three links that wrap
// on a phone, and nothing fades in on scroll. Reveal-on-scroll in particular is
// worth not bringing back — it starts content at opacity 0, so a JS failure
// leaves the page blank rather than merely unanimated.

// --- Copy-to-clipboard for code chips/blocks. ---
// A [data-copy] button copies the <code> inside its enclosing [data-block]
// (or, on the landing hero, the chip it lives in), then swaps its glyph.
(function copyButtons() {
  const buttons = document.querySelectorAll("[data-copy]");
  if (!buttons.length) return;
  buttons.forEach((btn) => {
    btn.addEventListener("click", async () => {
      const scope = btn.closest("[data-block]") || btn.parentElement;
      const code = scope && scope.querySelector("code");
      if (!code) return;
      try {
        await navigator.clipboard.writeText(code.innerText.trim());
      } catch {
        const range = document.createRange();
        range.selectNodeContents(code);
        const sel = window.getSelection();
        sel.removeAllRanges();
        sel.addRange(range);
        document.execCommand("copy");
        sel.removeAllRanges();
      }
      const copy = btn.querySelector('[data-i="copy"]');
      const check = btn.querySelector('[data-i="check"]');
      if (copy && check) {
        copy.style.display = "none";
        check.style.display = "block";
        clearTimeout(btn._t);
        btn._t = setTimeout(() => {
          copy.style.display = "block";
          check.style.display = "none";
        }, 1500);
      }
    });
  });
})();

// --- Landing screenshot gallery: thumbnails swap the framed shot above. ---
//
// The markup ships showing the first screenshot with its caption already
// written, so the section is complete and indexable before this runs — the
// thumbnails just stop being interactive without JS.
//
// The swap has to rewrite the <source>'s srcset, not only the <img>'s src: the
// browser picks from <source> whenever it supports WebP, so changing src alone
// would leave every visitor on modern Safari or Chrome looking at the first
// screenshot no matter which thumbnail they clicked.
//
// The targets are collected document-wide rather than from inside the gallery,
// because the "Built on libghostty" figure further down mirrors the same
// selection. Each target keeps its own `sizes` — only srcset, src, alt, and
// caption text are rewritten — so the small figure still picks a small rung.
(function screenshotGallery() {
  const root = document.querySelector("[data-gallery]");
  if (!root) return;
  const sources = document.querySelectorAll("[data-shot-source]");
  const imgs = document.querySelectorAll("[data-shot-main]");
  const captions = document.querySelectorAll("[data-shot-caption]");
  const thumbs = Array.from(root.querySelectorAll("[data-shot]"));
  if (!sources.length || !imgs.length || !thumbs.length) return;

  // The rungs build-images.mjs emits. Kept in step with WIDTHS there — a rung
  // named here that the build didn't write is a 404 on click.
  const WIDTHS = [640, 1000, 1400, 2200, 3132];
  const srcsetFor = (base) =>
    WIDTHS.map((w) => `/img/${base}-${w}.webp ${w}w`).join(", ");

  const select = (btn) => {
    const base = btn.dataset.shot;
    const srcset = srcsetFor(base);
    sources.forEach((s) => {
      s.srcset = srcset;
    });
    imgs.forEach((i) => {
      i.src = `/img/${base}-1400.png`;
      i.alt = btn.dataset.alt || "";
    });
    captions.forEach((c) => {
      c.textContent = btn.dataset.caption || "";
    });
    thumbs.forEach((t) => t.setAttribute("aria-pressed", String(t === btn)));
  };

  thumbs.forEach((btn) => btn.addEventListener("click", () => select(btn)));
})();

// --- Live GitHub stats: fill star + download counts, reveal their containers,
//     and point Download buttons at the latest .dmg.
//
// Straight to api.github.com from the browser, unauthenticated — the site is
// static files with no server to proxy through and no token to hide. The
// unauthenticated budget is 60 requests/hour per *visitor* IP, and the site
// spends at most three of them (one per figure below), so the ceiling that
// matters is a single reader browsing the docs. Two things keep that in
// bounds: every figure is fetched only when the page actually displays it (a
// docs page shows only the Download button, so it spends one), and each is
// cached in localStorage for an hour. Anything that fails — offline, rate
// limited, storage blocked — leaves the stat hidden and the button on its
// static /releases/latest href, which is how this already degrades. ---
(function loadStats() {
  const starWraps = document.querySelectorAll("[data-stat-stars]");
  const dlWraps = document.querySelectorAll("[data-stat-downloads]");
  const dlBtns = document.querySelectorAll("[data-download-latest]");
  if (!starWraps.length && !dlWraps.length && !dlBtns.length) return;

  const REPO = "thdxg/macterm";
  const API = "https://api.github.com";
  const CACHE_PREFIX = "macterm:gh:";
  const CACHE_TTL_MS = 60 * 60 * 1000;

  const compact = new Intl.NumberFormat("en", {
    notation: "compact",
    maximumFractionDigits: 1,
  });
  // Reveal a stat's own wrapper and any [data-stats-line] container holding it.
  const reveal = (el) => {
    el.hidden = false;
    const line = el.closest("[data-stats-line]");
    if (line) line.hidden = false;
  };

  // Cached per figure, not as one record: a docs page only ever resolves
  // `latest`, and must not stamp a fresh timestamp on figures it never asked
  // for. `undefined` means "not cached" — a 0 star count still caches.
  const cached = (key, load) => {
    const at = CACHE_PREFIX + key;
    try {
      const hit = JSON.parse(localStorage.getItem(at));
      if (hit && Date.now() - hit.at < CACHE_TTL_MS) return Promise.resolve(hit.v);
    } catch {}
    return load().then((v) => {
      if (v === undefined) return v;
      try {
        localStorage.setItem(at, JSON.stringify({ at: Date.now(), v }));
      } catch {}
      return v;
    });
  };

  const getJSON = async (path) => {
    const r = await fetch(API + path, {
      headers: { Accept: "application/vnd.github+json" },
    });
    if (!r.ok) throw new Error(`GitHub ${r.status} for ${path}`);
    return r.json();
  };

  // Total downloads is the one figure with no single-request form — it sums
  // every asset of every release. Capped so a paging bug can't run away.
  const totalDownloads = async () => {
    let total = 0;
    for (let page = 1; page <= 10; page++) {
      const rels = await getJSON(`/repos/${REPO}/releases?per_page=100&page=${page}`);
      if (!Array.isArray(rels) || rels.length === 0) break;
      for (const rel of rels) {
        for (const asset of rel?.assets ?? []) total += asset.download_count || 0;
      }
      if (rels.length < 100) break;
    }
    return total;
  };

  const fill = (wraps, selector, value) => {
    if (typeof value !== "number" || value <= 0) return;
    const text = compact.format(value);
    wraps.forEach((wrap) => {
      (wrap.querySelector(selector) || wrap).textContent = text;
      reveal(wrap);
    });
  };

  const swallow = (p) => p.catch(() => undefined);

  if (starWraps.length) {
    swallow(
      cached("stars", async () => (await getJSON(`/repos/${REPO}`)).stargazers_count)
    ).then((stars) => fill(starWraps, "[data-stat-stars-num]", stars));
  }

  if (dlWraps.length) {
    swallow(cached("downloads", totalDownloads)).then((downloads) =>
      fill(dlWraps, "[data-stat-downloads-num]", downloads)
    );
  }

  if (dlBtns.length) {
    // /releases/latest is already "newest non-draft, non-prerelease", so the
    // whole release list never has to be paged for this.
    swallow(
      cached("latestDmg", async () => {
        const rel = await getJSON(`/repos/${REPO}/releases/latest`);
        const dmg = rel?.assets?.find((a) => a.name?.endsWith(".dmg"));
        return dmg ? { name: dmg.name, url: dmg.browser_download_url } : null;
      })
    ).then((latestDmg) => {
      if (!latestDmg) return;
      dlBtns.forEach((btn) => {
        btn.href = latestDmg.url;
        btn.setAttribute("download", latestDmg.name);
      });
    });
  }
})();
