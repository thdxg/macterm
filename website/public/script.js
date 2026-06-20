// Live GitHub stats — stars and total release downloads.
// Requests go through the /api/stats endpoint, powered by Cloudflare Workers.
// The Worker fetches all pages of releases and caches the aggregated count.
(async function loadStats() {
  const compact = new Intl.NumberFormat("en", {
    notation: "compact",
    maximumFractionDigits: 1,
  });

  const setStat = (id, value, numSelector) => {
    const el = document.getElementById(id);
    if (!el || typeof value !== "number" || Number.isNaN(value)) return;
    const target = numSelector ? el.querySelector(numSelector) : el;
    if (!target) return;
    target.textContent = compact.format(value);
    el.hidden = false;
  };

  try {
    const r = await fetch("/api/stats");
    if (!r.ok) return;
    const data = await r.json();

    if (data.stars !== undefined) {
      setStat("stat-stars", data.stars, ".topnav-stars-num");
    }

    if (data.downloads > 0) {
      const el = document.getElementById("stat-downloads");
      if (el) {
        el.textContent = `${compact.format(data.downloads)} downloads`;
        el.hidden = false;
      }
    }

    if (data.latestDmg) {
      const btn = document.getElementById("download-btn");
      if (btn) {
        btn.href = data.latestDmg.url;
        btn.setAttribute("download", data.latestDmg.name);
      }
    }
  } catch {}
})();

// Copy-to-clipboard for the install command chips.
document.querySelectorAll(".copy-btn").forEach((btn) => {
  btn.addEventListener("click", async () => {
    const target = document.querySelector(btn.dataset.copy);
    if (!target) return;
    const text = target.textContent.trim();
    const label = btn.querySelector(".copy-label");
    try {
      await navigator.clipboard.writeText(text);
    } catch {
      // Fallback for browsers without the async clipboard API.
      const range = document.createRange();
      range.selectNodeContents(target);
      const sel = window.getSelection();
      sel.removeAllRanges();
      sel.addRange(range);
      document.execCommand("copy");
      sel.removeAllRanges();
    }
    // Text buttons swap their label; icon buttons rely on .is-copied alone.
    const original = label ? label.textContent : null;
    if (label) label.textContent = "Copied";
    btn.classList.add("is-copied");
    setTimeout(() => {
      if (label) label.textContent = original;
      btn.classList.remove("is-copied");
    }, 1600);
  });
});
