// Shared behavior for the Macterm marketing site + docs.
// Every feature is opt-in by DOM presence, so one script drives both pages.
//
// There is no sticky nav or reveal-on-scroll. The hero's settle-in
// (ec-reveal) is CSS that runs on load. Reveal-on-scroll is worth not bringing back — it starts content at
// opacity 0, so a JS failure leaves the page blank rather than merely
// unanimated.

// --- Copy-to-clipboard for CodeBlocks. ---
// An .ec-copy button copies the <code> inside its enclosing [data-block],
// minus any `$ ` prompts, then says so: for 1.5s it carries data-copied, which
// swaps its glyph for a check (CodeBlock), and its label reads "Copied".
(function copyButtons() {
  const buttons = document.querySelectorAll("[data-block] .ec-copy");
  if (!buttons.length) return;
  buttons.forEach((btn) => {
    btn.addEventListener("click", async () => {
      const code = btn.closest("[data-block]").querySelector("code");
      if (!code) return;
      const text = code.innerText.replace(/^\$ /gm, "").trim();
      try {
        await navigator.clipboard.writeText(text);
      } catch {
        const range = document.createRange();
        range.selectNodeContents(code);
        const sel = window.getSelection();
        sel.removeAllRanges();
        sel.addRange(range);
        document.execCommand("copy");
        sel.removeAllRanges();
      }
      btn.setAttribute("aria-label", "Copied");
      btn.dataset.copied = "";
      clearTimeout(btn._t);
      btn._t = setTimeout(() => {
        btn.setAttribute("aria-label", "Copy");
        delete btn.dataset.copied;
      }, 1500);
    });
  });
})();

// --- Docs menu: on phones the index folds behind the bar's menu button.
// The index hides only while it carries data-menu="closed", which this sets,
// so without JavaScript the page links simply stay in view. Above 960px the
// bar is hidden and the attribute has no effect.
(function docsMenu() {
  document.querySelectorAll(".ec-menu-btn").forEach((btn) => {
    const nav = document.getElementById(btn.getAttribute("aria-controls"));
    if (!nav) return;
    nav.dataset.menu = "closed";
    btn.addEventListener("click", () => {
      const open = nav.dataset.menu === "closed";
      nav.dataset.menu = open ? "open" : "closed";
      btn.setAttribute("aria-expanded", String(open));
    });
  });
})();

// --- Landing pane: smooth scrolling and edge fades. ---
//
// On desktops (1024px and up) the landing's features scroll in a pane at the
// right (Split). Every wheel and scrolling key, over the pane or anywhere
// else on the page, moves a target, and the pane eases toward
// it on each frame: a fixed share of the distance that is left, scaled to the
// frame time so a 120 Hz display glides at the same speed as a 60 Hz one. The
// position is kept as a float, because a browser can round scrollTop to whole
// pixels and the last steps of the ease are less than one. Reduce Motion
// jumps straight to the target. Pinch (a wheel event with ctrlKey) and
// sideways gestures, such as a wide code block, stay the browser's.
//
// It also marks where the reader is, for the fades: data-scrolled once the
// pane leaves its start (`home`), data-end at its end. An `endless` pane (the
// reel) never ends. Home goes back to the start; End, when there is one, to
// the end. The returned shift() moves the glide with content that the caller
// adds above the reader.
const smoothPane = (pane, home, endless) => {
  const pinned = window.matchMedia("(min-width: 1024px)");
  const still = window.matchMedia("(prefers-reduced-motion: reduce)");
  const EASE = 0.14; // share of the distance covered in a 60 Hz frame
  let target = 0;
  let at = 0;
  let frame = 0;
  let last = 0;
  const limit = () => pane.scrollHeight - pane.clientHeight;

  const edge = () => {
    pane.toggleAttribute("data-scrolled", pinned.matches && Math.abs(pane.scrollTop - home()) > 1);
    pane.toggleAttribute("data-end", pinned.matches && !endless && pane.scrollTop >= limit() - 1);
  };
  pane.addEventListener("scroll", edge, { passive: true });
  pinned.addEventListener("change", edge);
  edge();

  const glide = (now) => {
    const dt = Math.min(now - last, 64);
    last = now;
    at += (target - at) * (1 - Math.pow(1 - EASE, dt / 16.67));
    if (Math.abs(target - at) < 0.5) at = target;
    pane.scrollTop = at;
    frame = at === target ? 0 : requestAnimationFrame(glide);
  };
  const scrollTo = (y) => {
    // Start from where the pane is, in case something else moved it (a jump
    // to an anchor, or a focused element scrolled into view).
    if (!frame) at = target = pane.scrollTop;
    target = Math.max(0, Math.min(y, limit()));
    if (still.matches) {
      at = target;
      pane.scrollTop = target;
    } else if (!frame) {
      last = performance.now();
      frame = requestAnimationFrame(glide);
    }
  };
  const scrollBy = (by) => scrollTo((frame ? target : pane.scrollTop) + by);

  window.addEventListener(
    "wheel",
    (e) => {
      if (!pinned.matches || e.ctrlKey || Math.abs(e.deltaX) > Math.abs(e.deltaY)) return;
      // A left column taller than the window scrolls itself under the
      // pointer.
      const side = e.target.closest && e.target.closest(".ec-split-side");
      if (side && side.scrollHeight > side.clientHeight) return;
      e.preventDefault();
      const unit = e.deltaMode === 1 ? 40 : e.deltaMode === 2 ? pane.clientHeight : 1;
      scrollBy(e.deltaY * unit);
    },
    { passive: false },
  );
  document.addEventListener("keydown", (e) => {
    if (!pinned.matches || e.defaultPrevented || e.metaKey || e.ctrlKey || e.altKey) return;
    const t = e.target;
    if (t.closest("input, textarea, select, [contenteditable]")) return;
    // Space on a focused button or link presses it.
    if (e.key === " " && t.closest("a, button")) return;
    if (e.key === "Home" || (e.key === "End" && !endless)) {
      e.preventDefault();
      scrollTo(e.key === "Home" ? home() : limit());
      return;
    }
    const page = pane.clientHeight * 0.9;
    const by = {
      ArrowDown: 80,
      ArrowUp: -80,
      PageDown: page,
      PageUp: -page,
      " ": e.shiftKey ? -page : page,
    }[e.key];
    if (by === undefined) return;
    e.preventDefault();
    scrollBy(by);
  });

  return {
    edge,
    shift(dy) {
      at += dy;
      target += dy;
    },
  };
};

// --- Docs fades: mark where the reader is on the page. ---
// The window scrolls natively. DocsLayout shows the top band once the page
// leaves the top (data-scrolled on <html>) and hides the bottom band at the
// end (data-end).
(function docsFades() {
  if (!document.querySelector(".ec-docs")) return;
  const root = document.documentElement;
  const edge = () => {
    root.toggleAttribute("data-scrolled", window.scrollY > 1);
    root.toggleAttribute("data-end", window.scrollY >= root.scrollHeight - window.innerHeight - 1);
  };
  window.addEventListener("scroll", edge, { passive: true });
  window.addEventListener("resize", edge, { passive: true });
  edge();
})();

// --- Landing feature reel. ---
//
// The features scroll in the landing's pane, and the pane has no end in either
// direction: it keeps a few pane heights of features above and below the
// reader, and adds another lap of the list where the reader runs short. A lap
// is a copy of the list taken before any clip loads, so its clips also start
// at preload="none". It is hidden from assistive tech, which reads the list
// once. Below 1024px the CSS hides every lap and the list reads once.
//
// A lap added above pushes everything down, so the script moves scrollTop down
// by the same distance, measured as how far the real list moved. Setting
// scrollTop stops native momentum in Safari, but on desktops smoothPane drives
// every wheel and key scroll itself, so there is no native momentum to stop.
// The CSS turns off the browser's own scroll anchoring, which would move
// scrollTop a second time.
//
// The clips are illustrations, not media: no controls, no click to pause. The
// markup ships with a poster frame and preload="none", so a feature is
// complete, indexable and free before this runs; without JS, or when a
// browser refuses autoplay (Low Power Mode, Reduce Motion), the poster stays.
//
// A clip plays only while a reader can see it: inside the pane on desktops,
// on screen below 1024px. Many looping videos decoding at once on a laptop is
// a fan the page has no business spinning up. `muted` and `playsinline` in
// the markup are what make autoplay permissible at all — Safari and Chrome
// both refuse a play() that would make noise. A refused play() is ignored: a
// pause() during a fast scroll rejects the pending play() too, so a rejection
// says nothing about whether autoplay works.
(function reel() {
  const panel = document.querySelector(".ec-reel");
  const list = panel && panel.querySelector(".ec-reel-list");
  const end = panel && panel.querySelector(".ec-reel-end");
  if (!list || !end || !("IntersectionObserver" in window)) return;

  const pinned = window.matchMedia("(min-width: 1024px)");
  // Reduce Motion means "do not move on your own", so the poster stays.
  const still = window.matchMedia("(prefers-reduced-motion: reduce)");
  const lap = list.cloneNode(true);
  lap.dataset.lap = "";
  lap.setAttribute("aria-hidden", "true");
  lap.inert = true;

  const clips = () => panel.querySelectorAll("[data-demo]");
  const shown = new Set();
  const start = (v) => {
    if (v.preload !== "auto") v.preload = "auto";
    const started = v.play();
    if (started && started.catch) started.catch(() => {});
  };
  const sync = () => {
    clips().forEach((v) => {
      const play = shown.has(v) && !still.matches && document.visibilityState === "visible";
      if (play && v.paused) start(v);
      else if (!play && !v.paused) v.pause();
    });
  };

  // The pane scrolls on desktops and the window below 1024px, so the
  // observer's root follows the layout.
  let watch = null;
  const observe = () => {
    if (watch) watch.disconnect();
    shown.clear();
    watch = new IntersectionObserver(
      (entries) => {
        entries.forEach((e) => (e.isIntersecting ? shown.add(e.target) : shown.delete(e.target)));
        sync();
      },
      { root: pinned.matches ? panel : null, threshold: 0.35 },
    );
    clips().forEach((v) => watch.observe(v));
    sync();
  };

  // The reel's start: the scrollTop that centers the first feature in the
  // pane, in the band that the fades leave clear.
  const home = () => {
    const first = list.firstElementChild;
    return list.offsetTop + first.offsetHeight / 2 - panel.clientHeight / 2;
  };
  const smooth = smoothPane(panel, home, true);

  // Keep at least three pane heights of features on each side of the
  // reader. One lap is many times that, so this adds one lap at a time.
  const fill = () => {
    if (!pinned.matches) return;
    const room = 3 * panel.clientHeight;
    for (let i = 0; i < 4; i++) {
      if (panel.scrollHeight - panel.scrollTop - panel.clientHeight > room) break;
      const next = lap.cloneNode(true);
      panel.insertBefore(next, end);
      next.querySelectorAll("[data-demo]").forEach((v) => watch.observe(v));
    }
    for (let i = 0; i < 4; i++) {
      if (panel.scrollTop > room) break;
      const before = list.offsetTop;
      const next = lap.cloneNode(true);
      panel.insertBefore(next, panel.firstElementChild);
      next.querySelectorAll("[data-demo]").forEach((v) => watch.observe(v));
      const dy = list.offsetTop - before;
      panel.scrollTop += dy;
      smooth.shift(dy);
    }
  };
  panel.addEventListener("scroll", fill, { passive: true });

  // Where the script last put the reader. The web fonts can arrive after the
  // first layout and re-flow the laps above, which moves the list down; if
  // the reader has not moved since, the list goes back to its start.
  let placedAt = -1;
  const place = () => {
    // The start can need a lap above it, so place the list again once fill()
    // adds one.
    panel.scrollTop = home();
    fill();
    panel.scrollTop = home();
    placedAt = panel.scrollTop;
    smooth.edge();
  };
  const layout = () => {
    observe();
    // Laps that were hidden below 1024px are back above the list.
    if (pinned.matches) place();
  };
  layout();
  pinned.addEventListener("change", layout);
  if (document.fonts) {
    document.fonts.ready.then(() => {
      if (pinned.matches && panel.scrollTop === placedAt) place();
    });
  }
  still.addEventListener("change", sync);
  // A tab opened in the background rejects every play(); start the visible
  // clips when the visitor comes to it.
  document.addEventListener("visibilitychange", sync);
})();

// --- Live GitHub stats: fill star + download counts, reveal their containers,
//     and point Download buttons at the latest .dmg.
//
// Straight to api.github.com from the browser, unauthenticated — the site is
// static files with no server to proxy through and no token to hide. The
// unauthenticated budget is 60 requests/hour per *visitor* IP, and the site
// spends at most three of them (one per figure below), so the ceiling that
// matters is a single reader browsing the docs. Two things keep that in
// bounds: every figure is fetched only when the page actually displays it —
// each block below is guarded on its own markup being present, and today only
// the star count is rendered, so a cold page spends one request — and each is
// cached in localStorage for an hour, so a reader clicking between pages pays
// once. Anything that fails — offline, rate limited, storage blocked — leaves
// the stat hidden and the button on its static /releases/latest href, which is
// how this already degrades. The download-total and latest-.dmg blocks are
// kept wired for whenever a Download button comes back. ---
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
