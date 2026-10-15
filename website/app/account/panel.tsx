'use client';
import { useCallback, useEffect, useState } from 'react';
import { ArrowDown, ArrowUpRight, Monitor, Plus } from 'lucide-react';
import { ThemeToggle } from '@/components/theme/theme-toggle';
import { LocaleToggle } from '@/components/locale/locale-toggle';
import { useLocale } from '@/components/locale/locale-provider';
import styles from './style.module.css';

type AccountState = { authenticated: boolean; viewerName?: string; account?: {email: string | null}; devices?: Array<{id:string;name:string;created_at:number;expires_at:number}> };
type AccountError = 'load' | 'retry' | 'action' | 'code';
export default function AccountPanel({code,signInUrl,signOutUrl,communityConnection=false}:{code:string;signInUrl:string;signOutUrl:string;communityConnection?:boolean}) {
  const { locale, t } = useLocale();
  const [account,setAccount] = useState<AccountState|null>(null);
  const [error,setError] = useState<AccountError|null>(null);
  const [busy,setBusy] = useState('');
  const [deviceCode,setDeviceCode] = useState(code);
  const [deviceName,setDeviceName] = useState('Focus Studio');
  const [approved,setApproved] = useState(false);
  const load = useCallback(async () => {
    try {
      // Community pairing must show the Sites/ChatGPT identity, even if an
      // unrelated legacy Google account cookie is also present.
      const response = await fetch(communityConnection?'/api/community/me':'/api/account',{cache:'no-store'});
      const data = await response.json() as AccountState;
      if ((!response.ok && response.status !== 401) || typeof data.authenticated !== 'boolean') throw new Error('account');
      setAccount(data);
    } catch { setError('load'); }
  },[communityConnection]);
  useEffect(() => {
    if(new URLSearchParams(window.location.search).get('auth') === 'retry') setError('retry');
    void load();
  },[load]);
  async function action(name:string,path:string,body:unknown={},method='POST') {
    setBusy(name); setError(null);
    try {
      const response=await fetch(path,{method,headers:{'Content-Type':'application/json'},body:method==='DELETE'?undefined:JSON.stringify(body)});
      const data=await response.json() as {url?:string;error?:{code?:string}};
      if(!response.ok) { setError(name==='approve' && [400,404,409,410].includes(response.status)?'code':'action'); return; }
      if(name==='logout') { window.location.assign(data.url || signOutUrl); return; }
      if(name==='approve') setApproved(true);
      await load();
    } catch {setError('action');} finally {setBusy('');}
  }
  const errorText = error === 'load' ? t('Your account could not be loaded. Please try again.','账户暂时无法加载，请重试。')
    : error === 'retry' ? t('Sign-in was canceled or expired. Please try again.','登录已取消或过期，请重新登录。')
    : error === 'code' ? t('This connection code is invalid or expired. Get a new code from the app.','连接码无效或已过期，请从软件中获取新的连接码。')
    : t('That action could not be completed. Please try again.','操作暂时无法完成，请重试。');
  return <main className={styles.shell}>
    <nav className={styles.nav} aria-label={t('Account navigation','账户导航')}>
      <a href="/" className={styles.brand}><img src="/icons/icon-192.png" width="34" height="34" alt=""/>Focus Studio</a>
      <div className={styles.navActions}><a href="/community">{t('Community','作品社区')}</a><LocaleToggle/><ThemeToggle/></div>
    </nav>
    <header><p className={styles.eyebrow}>{t('YOUR CREATIVE SPACE','你的创作空间')}</p><h1>{t('Make it yours.','把想法变成作品。')}</h1><p>{t('Your shared work and connected devices, in one place.','在这里管理你的分享作品与已连接设备。')}</p></header>
    {error&&<div role="alert" className={styles.error}>{errorText}<button onClick={()=>{setError(null);void load();}}>{t('Retry','重试')}</button></div>}
    {!account&&!error&&<p role="status">{t('Loading your account…','正在加载账户…')}</p>}
    {account&&!account.authenticated&&<section className={styles.card}>
      <h2>{t('A space for your best work.','给好作品一个空间。')}</h2><p>{t('Sign in to share demos and manage your devices. Recording, editing and exporting are currently free.','登录后分享 Demo、管理设备。目前录制、剪辑与导出全部免费。')}</p>
      <a className={styles.primary} href={signInUrl} target="_top">{t('Continue with ChatGPT','使用 ChatGPT 登录')}<ArrowUpRight size={16}/></a>
      <p className={styles.note}>{t('Use the same ChatGPT account for your community posts and devices.','请使用同一 ChatGPT 账户管理社区作品和设备。')}</p>
    </section>}
    {account?.authenticated&&<>
      <section className={styles.card}>
        <div className={styles.row}><div><p className={styles.eyebrow}>{t('ACCOUNT','账户')}</p><h2>{account.account?.email || account.viewerName || t('Your ChatGPT account','你的 ChatGPT 账户')}</h2></div><button className={styles.textButton} disabled={!!busy} onClick={()=>void action('logout','/api/auth/logout')}>{t('Sign out','退出登录')}</button></div>
        <div className={styles.quickLinks}>
          <a href="/community/mine"><Monitor size={19}/><span>{t('My shared work','我分享的作品')}</span><ArrowUpRight size={16}/></a>
          <a href="/community/new"><Plus size={19}/><span>{t('Share a demo','分享 Demo')}</span><ArrowUpRight size={16}/></a>
          <a href="/?download=1"><ArrowDown size={19}/><span>{t('Download Focus Studio','下载 Focus Studio')}</span><ArrowUpRight size={16}/></a>
        </div>
      </section>
      <section className={styles.card}>
        <details className={styles.connection} open={code ? true : undefined}>
          <summary>{communityConnection?t('Confirm community publishing','确认社区发布资格'):t('Connect your desktop app','连接桌面软件')}</summary>
          <p>{t('Enter the code shown in Focus Studio. Only approve a connection you started.','输入 Focus Studio 显示的连接码，仅批准由你发起的连接。')}</p>
          {approved?<p role="status" className={styles.success}>{communityConnection?t('Connection approved. Return to Focus Studio to finish confirmation, then open the community to publish.','连接已批准。请回到 Focus Studio 完成确认，再前往社区发布。'):t('Device connected. Return to Focus Studio to continue.','设备已批准，请回到 Focus Studio 继续。')}</p>:<form onSubmit={event=>{event.preventDefault();void action('approve','/api/device/approve',{userCode:deviceCode,name:deviceName.trim()});}}>
            <div className={styles.fields}>
              <label>{t('Connection code','连接码')}<input value={deviceCode} onChange={e=>setDeviceCode(e.target.value.toUpperCase())} placeholder="A1B2C3-D4E5F6" maxLength={13} autoComplete="off" spellCheck={false} required/></label>
              <label>{t('Device name','设备名称')}<input value={deviceName} onChange={e=>setDeviceName(e.target.value)} maxLength={80} required/></label>
            </div>
            <button type="submit" className={styles.primary} disabled={!!busy||!/^[A-F0-9]{6}-?[A-F0-9]{6}$/.test(deviceCode)||!deviceName.trim()}>{busy==='approve'?t('Connecting…','正在连接…'):t('Approve device','批准此设备')}</button>
          </form>}
        </details>
      </section>
      {!!account.devices?.length&&<section className={styles.card}><h2>{t('Connected devices','已连接设备')}</h2><div className={styles.devices}>{account.devices.map(device=><div className={styles.row} key={device.id}><div><strong>{device.name}</strong><p className={styles.note}>{t('Connected','连接于')} {new Date(device.created_at*1000).toLocaleDateString(locale==='zh'?'zh-CN':'en-US')}</p></div><button disabled={!!busy} onClick={()=>void action(device.id,`/api/device/tokens/${encodeURIComponent(device.id)}`,{},'DELETE')}>{busy===device.id?t('Disconnecting…','正在断开…'):t('Disconnect','断开连接')}</button></div>)}</div></section>}
    </>}
    <footer><a href="/">← {t('Back to Focus Studio','返回 Focus Studio')}</a><a href="/help">{t('Need a hand?','需要帮助？')}</a></footer>
  </main>;
}
