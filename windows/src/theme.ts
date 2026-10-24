import { invoke } from "@tauri-apps/api/core";

export type Appearance = "system" | "light" | "dark";

let current: Appearance = "system";
const media = window.matchMedia("(prefers-color-scheme: dark)");

function applyResolved() {
  const resolved = current === "system" ? (media.matches ? "dark" : "light") : current;
  document.documentElement.dataset.theme = resolved;
  document.documentElement.dataset.appearance = current;
}

export function applyAppearance(mode: Appearance) {
  current = mode;
  applyResolved();
}

export async function initAppearance() {
  try {
    applyAppearance(await invoke<Appearance>("get_appearance"));
  } catch {
    applyAppearance("system");
  }
  media.addEventListener("change", () => {
    if (current === "system") applyResolved();
  });
}
