'use client';
import { useEffect, useState } from 'react';
import { communityRequest } from './types';
import { ArrowDown, ArrowLeft, ArrowUpRight, Plus } from 'lucide-react';
import { LocaleToggle } from '@/components/locale/locale-toggle';
import { useLocale } from '@/components/locale/locale-provider';
import { ThemeToggle } from '@/components/theme/theme-toggle';
import styles from './community.module.css';
export function CommunityShell({children, active='explore'}:{children:React.ReactNode;active?:'explore'|'mine'|'new'}) {
  const {t}=useLocale();const[moderator,setModerator]=useState(false);
  useEffect(()=>{communityRequest<{isModerator?:boolean}>('/api/community/me').then(data=>setModerator(!!data.isModerator)).catch(()=>{});},[]);
  return <div className={styles.shell}>
    <a href="#community-main" className="skip-link">{t('Skip to content','跳转到内容')}</a>
    <header className={styles.header}><a className={styles.brand} href="/"><img src="/icons/icon-192.png" alt="" width="32" height="32"/><span>Focus Studio</span></a>
      <nav aria-label={t('Community navigation','社区导航')}><a href="/community" aria-current={active==='explore'?'page':undefined}>{t('Explore','发现')}</a><a href="/community/mine" aria-current={active==='mine'?'page':undefined}>{t('My work','我的作品')}</a></nav>
      <div className={styles.headerActions}><LocaleToggle/><ThemeToggle/><a className={styles.headerDownload} href="/?download=1"><ArrowDown size={16}/>{t('Get the app','下载软件')}</a></div>
    </header>
    <main id="community-main" className={styles.main}>{children}</main>
    <footer className={styles.footer}><a href="/"><ArrowLeft size={14}/>{t('Back to Focus Studio','返回官网')}</a><div>{moderator&&<a href="/community/moderation">{t('Review reports','审核举报')}</a>}<a href="/community/guidelines">{t('Sharing guidelines','分享规则')}</a><a href="/privacy">{t('Privacy','隐私')}</a><a href="/help">{t('Help','帮助')}<ArrowUpRight size={12}/></a></div></footer>
  </div>;
}
export function PublishLink(){const{t}=useLocale();return <a className={styles.primary} href="/community/new"><Plus size={17}/>{t('Share a creation','分享作品')}</a>;}
