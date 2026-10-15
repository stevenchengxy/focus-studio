'use client';
import { useEffect, useState } from 'react';
import { ArrowDown, ArrowUpRight, Check, Monitor, RefreshCw, Settings2 } from 'lucide-react';
import { useLocale } from '@/components/locale/locale-provider';
import styles from './community.module.css';

export function CommunityClientRequirement({onRefresh,checking=false}:{onRefresh:()=>void;checking?:boolean}) {
  const {t}=useLocale();
  const [isMac,setIsMac]=useState(false);
  useEffect(()=>{setIsMac(/Macintosh|Mac OS X/.test(navigator.userAgent)&&!navigator.maxTouchPoints);},[]);
  return <section className={styles.clientRequirement} aria-labelledby="community-client-title">
    <div className={styles.clientConnectionMark}><Monitor size={25} aria-hidden="true"/><span><Check size={11}/></span></div>
    <h2 id="community-client-title">{t('Connect your app','连接你的客户端')}</h2>
    <p>{t('One connection. Then share whenever you like.','首次连接后，即可随时分享作品。')}</p>
    <ol className={styles.clientSteps}>
      <li><Settings2 size={16}/><span>{t('Open Settings','打开设置')}</span></li>
      <li><span className={styles.clientStepNumber}>2</span><span>{t('Connect ChatGPT','连接 ChatGPT')}</span></li>
      <li><Check size={16}/><span>{t('Confirm in app','客户端确认')}</span></li>
    </ol>
    <div className={styles.clientActions}>
      {isMac?<a className={styles.primary} href="focusstudio://settings/community">{t('Open Focus Studio','打开 Focus Studio')}<ArrowUpRight size={16}/></a>:<a className={styles.primary} href="/?download=1" target="_blank" rel="noreferrer"><ArrowDown size={16}/>{t('Download Focus Studio','下载 Focus Studio')}</a>}
      <button type="button" className={styles.secondary} onClick={onRefresh} disabled={checking} aria-busy={checking}><RefreshCw size={15} className={checking?styles.clientChecking:undefined}/>{checking?t('Checking…','检查中…'):t('Check connection','检查连接')}</button>
    </div>
    <details className={styles.clientHelp}><summary>{t('Where do I connect?','在哪里连接？')}</summary>
      <p>{t('Mac: Settings → Community connection. Connect the same ChatGPT account, then confirm in the app.','Mac：点击首页或 AI 助手右上角「设置」，选择「社区连接」，连接同一个 ChatGPT 账号并确认。')}</p>
      <p>{t('Windows / Linux: open Community publishing in the desktop app.','Windows / Linux：在客户端中打开「社区发布」。')}</p>
      <a href="/?download=1" target="_blank" rel="noreferrer"><ArrowDown size={14}/>{t('Get the latest app','下载最新版客户端')}</a>
    </details>
    <small>{t('Local recording and export stay free. No sign-in needed.','本地录制与导出始终免费，无需登录。')}</small>
  </section>;
}
