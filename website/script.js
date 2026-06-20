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
