'use client';
import { useEffect, useState } from 'react';
import { ArrowDown, ArrowLeft, ArrowUpRight, Compass, FolderOpen, Plus, Search, ShieldCheck, Sparkles, UserRound } from 'lucide-react';
import { LocaleToggle } from '@/components/locale/locale-toggle';
import { useLocale } from '@/components/locale/locale-provider';
import { ThemeToggle } from '@/components/theme/theme-toggle';
import { communityRequest, signInPath } from './types';
import styles from './community.module.css';

type Section = 'explore' | 'ai' | 'mine' | 'new' | 'moderation' | 'guidelines' | 'profile';
type SearchControl = { value: string; onChange: (value: string) => void; placeholder?: string };
export function CommunityShell({children, active='explore', search}:{children:React.ReactNode;active?:Section;search?:SearchControl}) {
  const {t}=useLocale();
  const [identity,setIdentity]=useState<{authenticated:boolean;isModerator?:boolean;viewerName?:string;displayName?:string|null}|null>(null);
  useEffect(()=>{const controller=new AbortController();const refresh=()=>communityRequest<{authenticated:boolean;isModerator?:boolean;viewerName?:string;displayName?:string|null}>('/api/community/me',{signal:controller.signal}).then(data=>{if(!controller.signal.aborted)setIdentity(data);}).catch(()=>{});void refresh();window.addEventListener('focus-community-profile-updated',refresh);return()=>{controller.abort();window.removeEventListener('focus-community-profile-updated',refresh);};},[]);
  const links=[
    {id:'explore',href:'/community',label:t('Discover','发现作品'),Icon:Compass},
    {id:'ai',href:'/community/ai',label:t('AI footage','AI 素材'),Icon:Sparkles},
    {id:'mine',href:'/community/mine',label:t('My work','我的作品'),Icon:FolderOpen},
    ...(identity?.isModerator?[{id:'moderation',href:'/community/moderation',label:t('Admin','管理'),Icon:ShieldCheck}]:[]),
  ];
  const returnTo=active==='new'?'/community/new':active==='ai'?'/community/ai':active==='mine'?'/community/mine':active==='profile'?'/community/profile':active==='moderation'?'/community/moderation':'/community';
  return <div className={styles.shell}>
    <a href="#community-main" className="skip-link">{t('Skip to content','跳转到内容')}</a>
    <header className={styles.header}>
      <a className={styles.brand} href="/" aria-label={t('Focus Studio home','Focus Studio 官网')}><img src="/icons/icon-192.png" alt="" width="30" height="30"/><span>Focus Studio<small>{t('Community','创作社区')}</small></span></a>
      <form className={styles.headerSearch} role="search" action={active==='ai'?'/community/ai':active==='mine'?'/community/mine':active==='moderation'?'/community/moderation':'/community'} onSubmit={search?event=>event.preventDefault():undefined}>
        <Search size={17} aria-hidden="true"/><input name="q" type="search" maxLength={120} placeholder={search?.placeholder||t('Search creations','搜索作品')} aria-label={t('Search creations','搜索作品')} {...(search?{value:search.value,onChange:(event:React.ChangeEvent<HTMLInputElement>)=>search.onChange(event.target.value)}:{})}/>
      </form>
      <div className={styles.headerActions}><a className={styles.mobileAccount} href={identity?.authenticated?'/community/profile':signInPath(returnTo)} target={identity?.authenticated?undefined:'_top'} aria-label={identity?.authenticated?t('Profile','个人资料'):t('Sign in','登录')}><UserRound size={17}/></a><LocaleToggle/><ThemeToggle/><a className={styles.headerPublish} href="/community/new" aria-label={t('Publish a creation','发布作品')}><Plus size={17}/><span>{t('Publish','发布作品')}</span></a></div>
    </header>
    <aside className={styles.sidebar}>
      <nav aria-label={t('Community navigation','社区导航')}>{links.map(({id,href,label,Icon})=><a key={id} href={href} aria-current={active===id?'page':undefined}><Icon size={19}/><span>{label}</span></a>)}</nav>
      <div className={styles.sidebarBottom}>
        <a className={styles.accountLink} aria-current={active==='profile'?'page':undefined} href={identity?.authenticated?'/community/profile':signInPath(returnTo)} target={identity?.authenticated?undefined:'_top'}><UserRound size={18}/><span>{identity?.authenticated?t('Profile','个人资料'):t('Sign in','登录')}</span><ArrowUpRight size={13}/></a>
        <a className={styles.appLink} href="/?download=1"><ArrowDown size={17}/><span>{t('Get Focus Studio','下载 Focus Studio')}</span></a>
        <div className={styles.sidebarLinks}>{identity?.authenticated&&<a href="/account">{t('Account','账户')}</a>}<a href="/community/guidelines">{t('Guidelines','分享规则')}</a><a href="/privacy">{t('Privacy','隐私')}</a><a href="/help">{t('Help','帮助')}</a></div>
        <a className={styles.homeLink} href="/"><ArrowLeft size={13}/>{t('Back to website','返回官网')}</a>
      </div>
    </aside>
    <main id="community-main" className={styles.main}>{children}</main>
  </div>;
}
export function PublishLink({category}:{category?:'ai-video'}){const{t}=useLocale();return <a className={styles.primary} href={`/community/new${category?'?category=ai-video':''}`}><Plus size={16}/>{t('Publish a creation','发布作品')}</a>;}
