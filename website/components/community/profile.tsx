'use client';
import { useEffect, useState } from 'react';
import { ArrowUpRight, Check, LoaderCircle, UserRound } from 'lucide-react';
import { useLocale } from '@/components/locale/locale-provider';
import { CommunityShell } from './shell';
import { CommunityError, communityRequest, errorCopy, signInPath } from './types';
import styles from './community.module.css';
export function CommunityProfile(){
 const{t}=useLocale();const[displayName,setDisplayName]=useState('');const[storedName,setStoredName]=useState('');const[loading,setLoading]=useState(true);const[busy,setBusy]=useState(false);const[anonymous,setAnonymous]=useState(false);const[error,setError]=useState<unknown>(null);const[saved,setSaved]=useState(false);const[attempt,setAttempt]=useState(0);
 useEffect(()=>{const controller=new AbortController();setLoading(true);setError(null);communityRequest<{displayName:string|null}>('/api/community/profile',{signal:controller.signal}).then(data=>{if(controller.signal.aborted)return;setDisplayName(data.displayName||'');setStoredName(data.displayName||'');setAnonymous(false);}).catch(error=>{if(controller.signal.aborted)return;if(error instanceof CommunityError&&/sign_in|auth/.test(error.code))setAnonymous(true);else setError(error);}).finally(()=>{if(!controller.signal.aborted)setLoading(false);});return()=>controller.abort();},[attempt]);
 async function save(){if(busy||!displayName.trim())return;setBusy(true);setSaved(false);setError(null);try{const data=await communityRequest<{displayName:string}>('/api/community/profile',{method:'PATCH',headers:{'Content-Type':'application/json'},body:JSON.stringify({displayName:displayName.trim()})});setDisplayName(data.displayName);setStoredName(data.displayName);setSaved(true);window.dispatchEvent(new Event('focus-community-profile-updated'));}catch(error){setError(error);}finally{setBusy(false);}}
 return <CommunityShell active="profile"><header className={styles.pageHeading}><h1>{t('Profile','个人资料')}</h1></header>
 {loading?<div className={styles.loading} role="status"><LoaderCircle size={17}/>{t('Loading…','加载中…')}</div>:anonymous?<section className={styles.empty}><UserRound size={28}/><h2>{t('Choose your creator name','设置你的创作者昵称')}</h2><a className={styles.primary} href={signInPath('/community/profile')} target="_top">{t('Continue with ChatGPT','使用 ChatGPT 登录')}<ArrowUpRight size={15}/></a></section>:<form className={styles.profileForm} onSubmit={event=>{event.preventDefault();void save();}}>
  <span className={styles.profileAvatar}>{displayName.trim().slice(0,1).toUpperCase()||<UserRound size={26}/>}</span>
  <fieldset className={styles.fields} disabled={busy}><label>{t('Creator name','创作者昵称')}<input value={displayName} onChange={event=>{setDisplayName(event.target.value);setSaved(false);}} maxLength={64} required autoComplete="nickname" placeholder={t('Your public name','公开显示的名称')} aria-describedby="profile-name-note"/></label></fieldset>
  <p id="profile-name-note">{t('Shown on all your community creations.','显示在你所有社区作品上。')}</p>
  {!!error&&<div className={styles.alert} role="alert">{error instanceof CommunityError&&error.code==='too_many_requests'?t('Please wait a moment before saving again.','请稍等片刻后再保存。'):errorCopy(error,t)}<button type="button" onClick={()=>setAttempt(value=>value+1)}>{t('Reload','重新加载')}</button></div>}
  <div className={styles.formActions}><button type="submit" className={styles.primary} disabled={busy||!displayName.trim()||displayName.trim()===storedName}>{busy?t('Saving…','保存中…'):t('Save name','保存昵称')}</button>{saved&&<span className={styles.savedMessage} role="status"><Check size={15}/>{t('Saved','已保存')}</span>}</div>
 </form>}
 </CommunityShell>;
}
