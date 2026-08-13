// Shared behavior for the Macterm marketing site + docs.
// Every feature is opt-in by DOM presence, so one script drives both pages.

// --- Sticky top-bar: transparent at the top, frosted once scrolled. ---
(function stickyNav() {
  const nav = document.querySelector("[data-nav-bar]");
  if (!nav) return;
  // Landing scrolls a little further before frosting than docs does.
  const threshold = Number(nav.dataset.navThreshold || 10);
  const onScroll = () => {
    const y = window.scrollY || document.documentElement.scrollTop || 0;
    nav.classList.toggle("is-scrolled", y > threshold);
  };
  window.addEventListener("scroll", onScroll, { passive: true });
  onScroll();
})();

// --- Mobile nav: hamburger toggles the collapsed nav links panel. ---
(function mobileNav() {
  const nav = document.querySelector("[data-nav-bar]");
  const toggle = nav && nav.querySelector("[data-nav-toggle]");
  if (!nav || !toggle) return;

  const setOpen = (open) => {
    nav.classList.toggle("nav-open", open);
    toggle.setAttribute("aria-expanded", String(open));
  };
  const close = () => setOpen(false);

  toggle.addEventListener("click", (e) => {
    e.stopPropagation();
    setOpen(!nav.classList.contains("nav-open"));
  });
  // Close when a link in the panel is chosen.
  nav.querySelectorAll(".nav-links a").forEach((a) =>
    a.addEventListener("click", close)
  );
  // Close on outside click and Escape.
  document.addEventListener("click", (e) => {
    if (nav.classList.contains("nav-open") && !nav.contains(e.target)) close();
  });
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape") close();
  });
  // Reset if the viewport grows back to the desktop layout.
  window.addEventListener("resize", () => {
    if (window.innerWidth > 640) close();
  });
})();

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

// --- Reveal-on-scroll for [data-reveal] rows (landing feature list). ---
(function revealOnScroll() {
  const items = Array.from(document.querySelectorAll("[data-reveal]"));
  if (!items.length) return;
  const reveal = (el) => el.classList.add("is-revealed");
  if (!("IntersectionObserver" in window)) {
    items.forEach(reveal);
    return;
  }
  const io = new IntersectionObserver(
    (entries) => {
      entries.forEach((en) => {
        if (!en.isIntersecting) return;
        const i = items.indexOf(en.target);
        en.target.style.transitionDelay = Math.min(i, 3) * 0.06 + "s";
        reveal(en.target);
        io.unobserve(en.target);
      });
    },
    { threshold: 0.12, rootMargin: "0px 0px -8% 0px" }
  );
  items.forEach((el) => io.observe(el));
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
