'use client';
import { useCallback, useEffect, useState } from 'react';
import { ThemeToggle } from '@/components/theme/theme-toggle';
import styles from './style.module.css';
type AccountState = { authenticated: boolean; account?:{email:string}; entitlement?:{plan:string;subscriptionStatus:string;freeExportsRemaining:number;activeExportId:string|null}; billingConfigured:boolean; googleConfigured:boolean; devices?:Array<{id:string;name:string;created_at:number;expires_at:number}> };
export default function AccountPanel({code,signInUrl,signOutUrl}:{code:string;signInUrl:string;signOutUrl:string}) {
  const [account,setAccount] = useState<AccountState|null>(null);
  const [error,setError] = useState(''); const [busy,setBusy] = useState('');
  const [deviceCode,setDeviceCode] = useState(code); const [deviceName,setDeviceName] = useState('My Focus Studio'); const [approved,setApproved] = useState(false);
  const load = useCallback(async () => {
    try { const response=await fetch('/api/account',{cache:'no-store'});const data=await response.json() as AccountState & {error?:{message:string}};if(!response.ok&&response.status!==401)throw new Error(data.error?.message??'Could not load your account.');setAccount(data); }
    catch(e){setError(e instanceof Error?e.message:'Could not load your account.');}
  },[]);
  useEffect(()=>{if(new URLSearchParams(window.location.search).get('auth')==='retry')setError('Sign-in was canceled or expired. Please try again.');void load();},[load]);
  async function action(name:string,path:string,body:unknown={},method='POST') {
    setBusy(name);setError('');
    try { const response=await fetch(path,{method,headers:{'Content-Type':'application/json'},body:method==='DELETE'?undefined:JSON.stringify(body)});const data=await response.json() as {url?:string;error?:{message:string}};if(!response.ok)throw new Error(data.error?.message??'Please try again.');if(data.url){window.location.assign(data.url);return;}if(name==='approve')setApproved(true);await load(); }
    catch(e){setError(e instanceof Error?e.message:'Please try again.');}finally{setBusy('');}
  }
  const paid=account?.entitlement?.plan==='monthly'||account?.entitlement?.plan==='yearly';
  return <main className={styles.shell}>
    <nav className={styles.nav}><a href="/" className={styles.brand}><span>▣</span> Focus Studio</a><div className={styles.navActions}><a href="/studio">Browser studio ↗</a><ThemeToggle/></div></nav>
    <header><p className={styles.eyebrow}>YOUR CREATIVE SPACE</p><h1>Ready when you are.</h1><p>One account. Your exports, subscription and connected devices.</p></header>
    {error&&<div role="alert" className={styles.error}>{error}<button onClick={()=>{setError('');void load();}}>Retry</button></div>}
    {!account&&!error&&<p role="status">Loading your account…</p>}
    {account&&!account.authenticated&&<section className={styles.card}><h2>Your first export is on us.</h2><p>Sign in to claim one free completed export. A canceled or failed export does not use it.</p><a className={styles.primary} href={signInUrl} target="_top">Continue with ChatGPT <span>↗</span></a><div style={{marginTop:12}}>{account.googleConfigured?<a className={styles.primary} href={`/api/auth/google/start?returnTo=${encodeURIComponent(`/account${deviceCode?`?code=${deviceCode}`:''}`)}`} target="_top">Continue with Google ↗</a>:<button disabled>Google sign-in · coming soon</button>}</div><p className={styles.note}>Use the same sign-in method for your subscription and connected devices.</p></section>}
    {account?.authenticated&&<>
      <section className={styles.card}><div className={styles.row}><div><p className={styles.eyebrow}>ACCOUNT</p><h2>{account.account?.email}</h2></div><button className={styles.textButton} onClick={()=>void action('logout','/api/auth/logout')}>Sign out</button></div><div className={styles.plan}><strong>{paid?'Focus Studio Pro':account.entitlement?.freeExportsRemaining?'1 free export':'Free export used'}</strong><span>{paid?(account.entitlement?.plan==='yearly'?'$108 billed yearly':'$29 billed monthly'):account.entitlement?.activeExportId?'Export in progress':'Create freely. Export when it feels right.'}</span></div>
        {paid?<button className={styles.primary} disabled={!!busy} onClick={()=>void action('portal','/api/billing/portal')}>{busy==='portal'?'Opening…':'Manage billing'}</button>:<div className={styles.prices}><button disabled={!!busy||!account.billingConfigured} onClick={()=>void action('monthly','/api/billing/checkout',{plan:'monthly'})}><strong>$29<span>/month</span></strong><span>{busy==='monthly'?'Opening checkout…':'Billed monthly'}</span></button><button disabled={!!busy||!account.billingConfigured} onClick={()=>void action('yearly','/api/billing/checkout',{plan:'yearly'})}><strong>$9<span>/month</span></strong><span>{busy==='yearly'?'Opening checkout…':'$108 billed yearly'}</span></button></div>}
        {!account.billingConfigured&&<p className={styles.note}>Paid plans are not open yet. You will not be charged.</p>}
        {account.entitlement?.activeExportId&&<div className={styles.plan}><strong style={{fontSize:16}}>An export is in progress.</strong><span>If an app closed unexpectedly, release its reservation here. That export will no longer be able to finish.</span><button disabled={!!busy} onClick={()=>void action('release',`/api/exports/${encodeURIComponent(account.entitlement!.activeExportId!)}/release`)}>Release unfinished export</button></div>}
        <button className={styles.textButton} onClick={()=>void load()}>Refresh account</button>
      </section>
      <section className={styles.card}><p className={styles.eyebrow}>CONNECT YOUR APP</p><h2>Bring your account to desktop.</h2><p>Enter the code shown in Focus Studio. Only approve a connection you started yourself.</p>{approved?<p role="status" className={styles.success}>Device approved. Return to Focus Studio to finish connecting.</p>:<form onSubmit={event=>{event.preventDefault();void action('approve','/api/device/approve',{userCode:deviceCode,name:deviceName});}}><div className={styles.fields}><label>Connection code<input value={deviceCode} onChange={e=>setDeviceCode(e.target.value.toUpperCase())} placeholder="A1B2C3-D4E5F6" maxLength={13} autoComplete="off" required /></label><label>Device name<input value={deviceName} onChange={e=>setDeviceName(e.target.value)} maxLength={80} required /></label></div><button type="submit" className={styles.primary} disabled={!!busy||deviceCode.replace('-','').length!==12}>{busy==='approve'?'Connecting…':'Approve this device'}</button></form>}</section>
      {!!account.devices?.length&&<section className={styles.card}><h2>Connected devices</h2><div className={styles.devices}>{account.devices.map(device=><div className={styles.row} key={device.id}><div><strong>{device.name}</strong><p className={styles.note}>Connected {new Date(device.created_at*1000).toLocaleDateString()}</p></div><button disabled={!!busy} onClick={()=>void action(device.id,`/api/device/tokens/${encodeURIComponent(device.id)}`,{},'DELETE')}>Disconnect</button></div>)}</div></section>}
    </>}
    <footer><a href="/">← Back to Focus Studio</a><span>Made for clear ideas.</span></footer>
  </main>;
}
