'use client';
import { ArrowDown, Monitor, RefreshCw } from 'lucide-react';
import { useLocale } from '@/components/locale/locale-provider';
import styles from './community.module.css';

export function CommunityClientRequirement({onRefresh,checking=false}:{onRefresh:()=>void;checking?:boolean}) {
  const {t}=useLocale();
  return <section className={styles.clientRequirement} aria-labelledby="community-client-title">
    <Monitor size={28} aria-hidden="true"/>
    <h2 id="community-client-title">{t('Connect Focus Studio before sharing','连接客户端后，即可分享')}</h2>
    <p>{t('Your ChatGPT sign-in is ready. To upload videos or AI footage, confirm this account once in the installed app.','你已登录 ChatGPT。上传视频或 AI 素材前，请在安装好的客户端中确认一次当前账户。')}</p>
    <ol>
      <li>{t('Download, install and open the latest Focus Studio.','下载、安装并打开最新版 Focus Studio。')}</li>
      <li>{t('In the app, open Community publishing and connect the same ChatGPT account.','在客户端的“社区发布”中连接同一个 ChatGPT 账户。')}</li>
      <li>{t('Finish the confirmation in the app, then return here and check again.','在客户端看到确认成功后，回到这里重新检查。')}</li>
    </ol>
    <div><a className={styles.primary} href="/?download=1" target="_blank" rel="noreferrer"><ArrowDown size={16}/>{t('Download Focus Studio','下载 Focus Studio')}</a><button type="button" className={styles.secondary} onClick={onRefresh} disabled={checking}><RefreshCw size={15}/>{checking?t('Checking…','正在检查…'):t('Check confirmation','重新检查确认状态')}</button></div>
    <small>{t('Browsing stays open to everyone. Recording, editing and local exports do not require sign-in.','浏览社区无需登录；本地录制、剪辑和导出也无需登录。')}</small>
  </section>;
}
