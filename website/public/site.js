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

// --- Live GitHub stats from /api/stats: fill star + download counts, reveal
//     their containers, and point Download buttons at the latest .dmg. ---
(async function loadStats() {
  const starWraps = document.querySelectorAll("[data-stat-stars]");
  const dlWraps = document.querySelectorAll("[data-stat-downloads]");
  const dlBtns = document.querySelectorAll("[data-download-latest]");
  if (!starWraps.length && !dlWraps.length && !dlBtns.length) return;

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

  try {
    const r = await fetch("/api/stats");
    if (!r.ok) return;
    const data = await r.json();

    if (typeof data.stars === "number" && data.stars > 0) {
      const text = compact.format(data.stars);
      starWraps.forEach((wrap) => {
        const num = wrap.querySelector("[data-stat-stars-num]") || wrap;
        num.textContent = text;
        reveal(wrap);
      });
    }
    if (typeof data.downloads === "number" && data.downloads > 0) {
      const text = compact.format(data.downloads);
      dlWraps.forEach((wrap) => {
        const num = wrap.querySelector("[data-stat-downloads-num]") || wrap;
        num.textContent = text;
        reveal(wrap);
      });
    }
    if (data.latestDmg) {
      dlBtns.forEach((btn) => {
        btn.href = data.latestDmg.url;
        btn.setAttribute("download", data.latestDmg.name);
      });
    }
  } catch {}
})();
