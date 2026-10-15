"use client";

import { useEffect, useId, useRef, useState } from "react";
import { Check, Monitor, Moon, Sun } from "lucide-react";
import { useTheme } from "./theme-provider";
import { useLocale } from "@/components/locale/locale-provider";
import styles from "./theme-toggle.module.css";

const options = [
  { value: "light" as const, label: "Light", zh: "浅色", Icon: Sun },
  { value: "dark" as const, label: "Dark", zh: "深色", Icon: Moon },
  { value: "system" as const, label: "System", zh: "跟随系统", Icon: Monitor },
];

export function ThemeToggle({ className = "" }: { className?: string }) {
  const { t } = useLocale();
  const { theme, setTheme } = useTheme();
  const [open, setOpen] = useState(false);
  const root = useRef<HTMLDivElement>(null);
  const trigger = useRef<HTMLButtonElement>(null);
  const id = useId();
  const ActiveIcon = options.find((option) => option.value === theme)!.Icon;

  useEffect(() => {
    if (!open) return;
    root.current?.querySelector<HTMLButtonElement>('[aria-checked="true"]')?.focus();
    const outside = (event: PointerEvent) => {
      if (event.target instanceof Node && !root.current?.contains(event.target)) setOpen(false);
    };
    const escape = (event: KeyboardEvent) => {
      if (event.key === "Escape") { setOpen(false); trigger.current?.focus(); }
    };
    document.addEventListener("pointerdown", outside);
    document.addEventListener("keydown", escape);
    return () => {
      document.removeEventListener("pointerdown", outside);
      document.removeEventListener("keydown", escape);
    };
  }, [open]);

  return <div className={`${styles.root} ${className}`} ref={root} onBlur={(event) => {
    if (!event.currentTarget.contains(event.relatedTarget as Node | null)) setOpen(false);
  }}>
    <button type="button" className={styles.toggle} ref={trigger} aria-label={t(`Appearance: ${theme}. Change theme`, `外观：${options.find(option => option.value === theme)!.zh}。切换主题`)} title={t("Appearance", "外观")} aria-haspopup="menu" aria-expanded={open} aria-controls={open ? id : undefined} onClick={() => setOpen(!open)} onKeyDown={(event) => {
      if (event.key === "ArrowDown" || event.key === "ArrowUp") { event.preventDefault(); setOpen(true); }
    }}><ActiveIcon size={16} strokeWidth={1.7}/></button>
    {open && <div className={styles.menu} role="menu" aria-label={t("Appearance", "外观")} id={id} onKeyDown={(event) => {
      const items = Array.from(event.currentTarget.querySelectorAll<HTMLButtonElement>('[role="menuitemradio"]'));
      const index = items.indexOf(document.activeElement as HTMLButtonElement);
      if (event.key === "ArrowDown" || event.key === "ArrowUp") {
        event.preventDefault(); items[(index + (event.key === "ArrowDown" ? 1 : items.length - 1)) % items.length]?.focus();
      } else if (event.key === "Home" || event.key === "End") {
        event.preventDefault(); items[event.key === "Home" ? 0 : items.length - 1]?.focus();
      }
    }}>{options.map(({ value, label, zh, Icon }) => <button type="button" key={value} role="menuitemradio" aria-checked={theme === value} className={styles.option} onClick={() => { setTheme(value); setOpen(false); trigger.current?.focus(); }}><Icon size={15}/><span>{t(label, zh)}</span>{theme === value && <Check size={13}/>}</button>)}</div>}
  </div>;
}
