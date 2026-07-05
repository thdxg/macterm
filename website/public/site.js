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

// --- Live GitHub stats: point Download buttons at the latest .dmg,
//     and show the star count next to the GitHub link if present. ---
(async function loadStats() {
  const starEls = document.querySelectorAll("[data-stat-stars]");
  const dlBtns = document.querySelectorAll("[data-download-latest]");
  if (!starEls.length && !dlBtns.length) return;
  const compact = new Intl.NumberFormat("en", {
    notation: "compact",
    maximumFractionDigits: 1,
  });
  try {
    const r = await fetch("/api/stats");
    if (!r.ok) return;
    const data = await r.json();
    if (typeof data.stars === "number" && data.stars > 0) {
      starEls.forEach((el) => {
        el.textContent = compact.format(data.stars);
        el.hidden = false;
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
