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

// --- Landing demo reel: each clip plays while it is on screen, and the
//     hairline under it fills with its progress. ---
//
// The markup ships with a poster frame and preload="none", so the section is
// complete, indexable and free before this runs; without JS the clips are
// still there and simply wait to be asked (the fallbacks below turn their
// controls on).
//
// `muted` and `playsinline` in the markup are what make autoplay permissible
// at all — Safari and Chrome both refuse a play() that would make noise. A
// refused play() is still not fatal: the catch shows the controls so a
// visitor can start it by hand.
//
// Pausing off-screen matters as much as playing on-screen. Five looping
// videos decoding at once on a laptop is a fan the page has no business
// spinning up, and the whole reel is taller than any viewport.
(function demoReel() {
  const videos = Array.from(document.querySelectorAll("[data-demo]"));
  if (!videos.length) return;

  const fillFor = (v) => {
    const wrap = v.closest("[data-demo-wrap]");
    return wrap && wrap.querySelector("[data-demo-fill]");
  };

  const showControls = (v) => {
    v.controls = true;
    if (v.preload === "none") v.preload = "metadata";
  };

  // Reduce Motion means "do not move on your own" — the clips stay, but they
  // wait for a click. Same fallback covers a browser without the observer.
  const still = window.matchMedia("(prefers-reduced-motion: reduce)");
  if (still.matches || !("IntersectionObserver" in window)) {
    videos.forEach(showControls);
    return;
  }

  const playing = new Set();
  // A rejected play() is only meaningful when the page is actually on screen.
  // A tab opened in the background rejects every one of them, and treating
  // that as "autoplay is blocked here" would pin controls on all six clips
  // for a visitor who has not even looked at the page yet.
  const start = (v) => {
    const started = v.play();
    if (started && started.catch) {
      started.catch(() => {
        if (document.visibilityState === "visible") showControls(v);
      });
    }
  };
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState !== "visible") return;
    videos.forEach((v) => {
      if (v.paused && !v.controls && onScreen.has(v)) start(v);
    });
  });

  // One rAF loop for every clip on screen rather than a timeupdate listener
  // per video: timeupdate fires about 4x a second, which reads as a progress
  // bar that stutters. The loop stops itself when nothing is playing.
  let frame = null;
  const paint = () => {
    playing.forEach((v) => {
      const bar = fillFor(v);
      if (!bar) return;
      const pct = v.duration ? (v.currentTime / v.duration) * 100 : 0;
      bar.style.width = pct.toFixed(2) + "%";
    });
    frame = playing.size ? requestAnimationFrame(paint) : null;
  };
  const wake = () => {
    if (frame === null && playing.size) frame = requestAnimationFrame(paint);
  };

  const onScreen = new Set();
  const io = new IntersectionObserver(
    (entries) => {
      entries.forEach((entry) => {
        const v = entry.target;
        if (entry.isIntersecting) {
          onScreen.add(v);
          if (v.preload !== "auto") v.preload = "auto";
          start(v);
        } else {
          onScreen.delete(v);
          if (!v.paused) v.pause();
        }
      });
    },
    { threshold: 0.35, rootMargin: "120px 0px" },
  );

  videos.forEach((v) => {
    io.observe(v);
    v.addEventListener("playing", () => {
      playing.add(v);
      wake();
    });
    ["pause", "ended", "emptied"].forEach((e) =>
      v.addEventListener(e, () => playing.delete(v)),
    );
    // The one control an autoplaying clip keeps: click to hold a frame you
    // want to read, click again to carry on.
    v.addEventListener("click", () => {
      if (v.paused) start(v);
      else v.pause();
    });
  });
})();

// --- Live GitHub stats: fill star + download counts, reveal their containers,
//     and point Download buttons at the latest .dmg.
//
// Straight to api.github.com from the browser, unauthenticated — the site is
// static files with no server to proxy through and no token to hide. The
// unauthenticated budget is 60 requests/hour per *visitor* IP, and the site
// spends at most three of them (one per figure below), so the ceiling that
// matters is a single reader browsing the docs. Two things keep that in
// bounds: every figure is fetched only when the page actually displays it
// (both headers now show all three — stars beside GitHub, the download total
// beside Download — so a cold page spends a handful: one for stars, one for
// the latest release, and one per hundred releases for the total), and each
// is cached in localStorage for an hour, so a docs reader clicking between
// pages pays once. Anything that fails — offline, rate
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
