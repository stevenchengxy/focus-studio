"use client";
import { Globe2 } from "lucide-react";
import { useLocale, type Locale } from "./locale-provider";
import styles from "./locale-toggle.module.css";
export function LocaleToggle() {
  const { locale, setLocale, t } = useLocale();
  return <label className={styles.root}><Globe2 size={15} aria-hidden="true"/><select value={locale} aria-label={t("Language", "语言")} onChange={event => setLocale(event.target.value as Locale)}><option value="en">EN</option><option value="zh">简体中文</option></select></label>;
}
