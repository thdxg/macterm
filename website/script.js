// Live GitHub stats — stars and total release downloads.
// Fetched unauthenticated from the public API; if anything fails the
// placeholder dash is left in place rather than showing a broken value.
(function loadStats() {
  const REPO = "thdxg/macterm";
  const compact = new Intl.NumberFormat("en", {
    notation: "compact",
    maximumFractionDigits: 1,
  });

  const setStat = (id, value) => {
    const el = document.getElementById(id);
    if (el && typeof value === "number" && !Number.isNaN(value)) {
      el.textContent = compact.format(value);
    }
  };

  fetch(`https://api.github.com/repos/${REPO}`)
    .then((r) => (r.ok ? r.json() : Promise.reject()))
    .then((repo) => setStat("stat-stars", repo.stargazers_count))
    .catch(() => {});

  fetch(`https://api.github.com/repos/${REPO}/releases?per_page=100`)
    .then((r) => (r.ok ? r.json() : Promise.reject()))
    .then((releases) => {
      if (!Array.isArray(releases)) return;
      const total = releases.reduce(
        (sum, rel) =>
          sum + (rel.assets || []).reduce((s, a) => s + (a.download_count || 0), 0),
        0,
      );
      setStat("stat-downloads", total);
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
    const original = label.textContent;
    label.textContent = "Copied";
    btn.classList.add("is-copied");
    setTimeout(() => {
      label.textContent = original;
      btn.classList.remove("is-copied");
    }, 1600);
  });
});
