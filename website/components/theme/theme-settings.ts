export type ThemePreference = "light" | "dark" | "system";
export type ResolvedTheme = "light" | "dark";
export const THEME_STORAGE_KEY = "focus-studio-theme";

export function validTheme(value: unknown): ThemePreference {
  return value === "system" || value === "dark" ? value : "light";
}

/** Runs synchronously in <head>, before themed content can paint. */
export const themeInitScript = `(()=>{let p="light";try{const s=localStorage.getItem("${THEME_STORAGE_KEY}");if(s==="light"||s==="dark"||s==="system")p=s}catch{}const t=p==="system"?(matchMedia("(prefers-color-scheme: dark)").matches?"dark":"light"):p;const r=document.documentElement;r.dataset.theme=t;r.dataset.themePreference=p;r.style.colorScheme=t})()`;
