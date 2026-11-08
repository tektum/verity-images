// Theme cycles Auto (no data-theme, follows the OS) -> Light -> Dark. The
// inline head script applies the saved choice before first paint.
{
  const KEY = "verity-theme";
  const MODES = ["auto", "light", "dark"];
  const root = document.documentElement;
  const toggle = document.querySelector("#theme-toggle");
  let mode = root.dataset.theme ?? "auto";

  const label = () => {
    toggle.textContent = `Theme: ${mode[0].toUpperCase()}${mode.slice(1)}`;
  };

  if (toggle) {
    label();
    toggle.addEventListener("click", () => {
      mode = MODES[(MODES.indexOf(mode) + 1) % MODES.length];
      if (mode === "auto") delete root.dataset.theme;
      else root.dataset.theme = mode;
      try {
        if (mode === "auto") localStorage.removeItem(KEY);
        else localStorage.setItem(KEY, mode);
      } catch {
        // Storage can be unavailable (privacy mode); the choice lasts for this page.
      }
      label();
    });
  }
}
