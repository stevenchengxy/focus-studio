'use client';
import { ArrowLeft, ArrowUpRight } from 'lucide-react';
import { useLocale } from '@/components/locale/locale-provider';
import { CommunityShell } from './shell';
import styles from './community.module.css';
export function CommunityShowcase(){const{t}=useLocale();return <CommunityShell><a className={styles.back} href="/community"><ArrowLeft size={15}/>{t('Discover','发现作品')}</a><div className={styles.player}><video src="/media/focus-studio-demo-flat.mp4" poster="/media/focus-studio-demo-flat.jpg" controls playsInline preload="metadata" aria-label={t('Official Focus Studio demo','Focus Studio 官方演示')}/></div><header className={styles.detailHeader}><div><span className={styles.eyebrow}>{t('OFFICIAL EXAMPLE','官方示例')}</span><h1>{t('A closer look','聚焦每个细节')}</h1><div className={styles.byline}><img src="/icons/icon-192.png" width="24" height="24" alt=""/>Focus Studio</div></div><a className={styles.primary} href="/?download=1">{t('Create your own','开始创作')}<ArrowUpRight size={16}/></a></header></CommunityShell>;}
