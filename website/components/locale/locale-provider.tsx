'use client';
import { createContext, useCallback, useContext, useEffect, useMemo, useSyncExternalStore, type ReactNode } from 'react';
export type Locale = 'en' | 'zh';
const key = 'focus-studio-locale';
const changeEvent = 'focus-studio-locale-change';
let sessionLocale: Locale | null = null;
type LocaleContextValue = { locale: Locale; setLocale: (value: Locale) => void; t: (en: string, zh: string) => string };
const LocaleContext = createContext<LocaleContextValue | null>(null);
function preferredLocale(): Locale {
  if (sessionLocale) return sessionLocale;
  try { const saved = localStorage.getItem(key); if (saved === 'en' || saved === 'zh') return saved; } catch { /* Restricted storage still supports this session's choice. */ }
  return navigator.language.toLowerCase().startsWith('zh') ? 'zh' : 'en';
}
function subscribe(onChange: () => void) {
  const sync = (event: StorageEvent) => {
    if (event.key === key || event.key === null) { sessionLocale = null; onChange(); }
  };
  window.addEventListener('storage', sync);
  window.addEventListener(changeEvent, onChange);
  return () => { window.removeEventListener('storage', sync); window.removeEventListener(changeEvent, onChange); };
}
const serverLocale = (): Locale => 'en';
export function LocaleProvider({ children }: { children: ReactNode }) {
  const locale = useSyncExternalStore(subscribe, preferredLocale, serverLocale);
  useEffect(() => { document.documentElement.lang = locale === 'zh' ? 'zh-CN' : 'en'; document.documentElement.dataset.locale = locale; }, [locale]);
  const setLocale = useCallback((next: Locale) => {
    if (next !== 'en' && next !== 'zh') return;
    sessionLocale = next;
    try { localStorage.setItem(key, next); } catch { /* Keep the in-memory preference when persistence is unavailable. */ }
    window.dispatchEvent(new Event(changeEvent));
  }, []);
  const t = useCallback((en: string, zh: string) => locale === 'zh' ? zh : en, [locale]);
  const value = useMemo(() => ({ locale, setLocale, t }), [locale, setLocale, t]);
  return <LocaleContext.Provider value={value}>{children}</LocaleContext.Provider>;
}
export function useLocale() {
  const value = useContext(LocaleContext);
  if (!value) throw new Error('useLocale requires LocaleProvider');
  return value;
}
