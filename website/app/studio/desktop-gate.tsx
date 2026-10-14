"use client";

import { lazy, Suspense, useEffect, useState } from 'react';
import { useLocale } from '@/components/locale/locale-provider';
import { LocaleToggle } from '@/components/locale/locale-toggle';
import { Brand } from '@/components/marketing/focus-home';
import './desktop-bridge';

const DesktopEditor = lazy(() => import('./studio').then(module => ({default: module.BrowserStudio})));

/** Product routing only: this bridge check is not an authorization boundary. */
export function DesktopGate() {
  const {t}=useLocale();
  const [desktop, setDesktop] = useState(false);
  useEffect(() => {
    let active = true;
    const bridge = window.focusDesktop;
    if (bridge?.version === 1 && typeof bridge.getCapabilities === 'function') {
      bridge.getCapabilities().then(value => {
        if (active && ['win32', 'linux', 'darwin'].includes(value.platform)) setDesktop(true);
      }).catch(() => {});
    }
    return () => { active = false; };
  }, []);
  if (desktop) return <Suspense fallback={<main className="desktop-download-gate" role="status">{t('Opening Focus Studio…','正在打开 Focus Studio…')}</main>}><DesktopEditor /></Suspense>;
  return <main className="desktop-download-gate"><Brand /><LocaleToggle/><div>
    <h1>{t('Your studio.','你的创作空间。')}<br />{t('On your desktop.','就在桌面。')}</h1>
    <p>{t('Download Focus Studio to record, edit and export for free.','下载 Focus Studio，免费录制、剪辑与导出。')}</p>
    <nav aria-label="Download Focus Studio">
      <a href="/api/download/mac?channel=preview">{t('Download for Mac','下载 Mac 版')}</a>
      <a href="/api/download/windows?channel=preview">{t('Windows preview','Windows 预览版')}</a>
      <a href="/api/download/linux?channel=preview">{t('Linux preview','Linux 预览版')}</a>
    </nav>
    <small>{t('Windows and Linux previews load the editor online. Recording and exports stay on your device.','Windows 和 Linux 预览版需联网加载编辑器。录屏与导出文件保存在本地。')}</small>
    <a className="desktop-gate-home" href="/">{t('Back to Focus Studio','返回官网')}</a>
  </div></main>;
}
