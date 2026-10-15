"use client";

import { createContext, useContext, useEffect, useMemo, useSyncExternalStore, type ReactNode } from "react";
import { THEME_STORAGE_KEY, validTheme, type ResolvedTheme, type ThemePreference } from "./theme-settings";

const themeEvent = "focus-theme-change";
const systemQuery = "(prefers-color-scheme: dark)";
interface ThemeContextValue {
  theme: ThemePreference;
  resolvedTheme: ResolvedTheme;
  setTheme: (theme: ThemePreference) => void;
}
const ThemeContext = createContext<ThemeContextValue | null>(null);

function resolve(theme: ThemePreference): ResolvedTheme {
  return theme === "system" ? (window.matchMedia(systemQuery).matches ? "dark" : "light") : theme;
}

function apply(theme: ThemePreference) {
  const resolved = resolve(theme);
  const root = document.documentElement;
  root.dataset.themePreference = theme;
  root.dataset.theme = resolved;
  root.style.colorScheme = resolved;
}

function snapshot() {
  const theme = validTheme(document.documentElement.dataset.themePreference);
  return `${theme}:${resolve(theme)}`;
}

function subscribe(listener: () => void) {
  const query = window.matchMedia(systemQuery);
  const changed = () => {
    apply(validTheme(document.documentElement.dataset.themePreference));
    listener();
  };
  const stored = (event: StorageEvent) => {
    if (event.key !== THEME_STORAGE_KEY && event.key !== null) return;
    apply(validTheme(event.newValue));
    listener();
  };
  window.addEventListener(themeEvent, changed);
  window.addEventListener("storage", stored);
  query.addEventListener("change", changed);
  return () => {
    window.removeEventListener(themeEvent, changed);
    window.removeEventListener("storage", stored);
    query.removeEventListener("change", changed);
  };
}

function setTheme(theme: ThemePreference) {
  const next = validTheme(theme);
  apply(next);
  try { localStorage.setItem(THEME_STORAGE_KEY, next); } catch { /* Still usable in private/storage-restricted contexts. */ }
  window.dispatchEvent(new Event(themeEvent));
}

export function ThemeProvider({ children }: { children: ReactNode }) {
  // The server and hydration pass intentionally share one snapshot. The head
  // initializer has already applied the real palette before either can paint.
  const current = useSyncExternalStore(subscribe, snapshot, () => "light:light");
  const [theme, resolvedTheme] = current.split(":") as [ThemePreference, ResolvedTheme];
  useEffect(() => { apply(validTheme(document.documentElement.dataset.themePreference)); }, []);
  const value = useMemo(() => ({ theme, resolvedTheme, setTheme }), [theme, resolvedTheme]);
  return <ThemeContext.Provider value={value}>{children}</ThemeContext.Provider>;
}

export function useTheme() {
  const context = useContext(ThemeContext);
  if (!context) throw new Error("useTheme must be used within ThemeProvider");
  return context;
}
