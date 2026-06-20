// Live GitHub stats — stars and total release downloads.
// Requests go through the same-origin /api/gh/ proxy, which nginx authenticates
// with a server-side token (see default.conf.template) — the token is never
// exposed to the browser. If anything fails the placeholder dash is left in
// place rather than showing a broken value.
(function loadStats() {
  const REPO = "thdxg/macterm";
  const GH = "/api/gh";
  const compact = new Intl.NumberFormat("en", {
    notation: "compact",
    maximumFractionDigits: 1,
  });

  // Write a fetched count into a stat element and reveal it. The number
  // lives in a `.<selector>-num` child when present (the navbar star count),
  // otherwise on the element itself (the download button count).
  const setStat = (id, value, numSelector) => {
    const el = document.getElementById(id);
    if (!el || typeof value !== "number" || Number.isNaN(value)) return;
    const target = numSelector ? el.querySelector(numSelector) : el;
    if (!target) return;
    target.textContent = compact.format(value);
    el.hidden = false;
  };

  fetch(`${GH}/repos/${REPO}`)
    .then((r) => (r.ok ? r.json() : Promise.reject()))
    .then((repo) => setStat("stat-stars", repo.stargazers_count, ".topnav-stars-num"))
    .catch(() => {});

  fetch(`${GH}/repos/${REPO}/releases?per_page=100`)
    .then((r) => (r.ok ? r.json() : Promise.reject()))
    .then((releases) => {
      if (!Array.isArray(releases)) return;
      const total = releases.reduce(
        (sum, rel) =>
          sum + (rel.assets || []).reduce((s, a) => s + (a.download_count || 0), 0),
        0,
      );
      const el = document.getElementById("stat-downloads");
      if (el && total > 0) {
        el.textContent = `${compact.format(total)} downloads`;
        el.hidden = false;
      }

      // Point the hero button straight at the latest .dmg so a click
      // downloads it instead of opening the GitHub Releases page. The DMG
      // asset is versioned, so the static releases/latest URL can't link it
      // directly; we resolve it from the freshest non-prerelease release.
      const latest = releases.find((rel) => rel && !rel.draft && !rel.prerelease);
      const dmg = (latest?.assets || []).find((a) => a.name?.endsWith(".dmg"));
      const btn = document.getElementById("download-btn");
      if (btn && dmg?.browser_download_url) {
        btn.href = dmg.browser_download_url;
        btn.setAttribute("download", dmg.name);
      }
    })
    .catch(() => {});
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
