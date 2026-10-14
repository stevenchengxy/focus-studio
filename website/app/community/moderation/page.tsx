'use client';
import { useEffect, useState } from 'react';
import { ArrowUpRight, Eye, EyeOff, LoaderCircle, ShieldCheck } from 'lucide-react';
import { CommunityShell } from '@/components/community/shell';
import { communityRequest, errorCopy, type CommunityItem } from '@/components/community/types';
import { useLocale } from '@/components/locale/locale-provider';
import styles from '@/components/community/community.module.css';
type Report={id:string;reason:string;details:string;createdAt:number;item:CommunityItem};
export default function Page(){
 const{t}=useLocale();const[reports,setReports]=useState<Report[]>([]);const[loading,setLoading]=useState(true);const[error,setError]=useState<unknown>(null);const[busy,setBusy]=useState('');const[reason,setReason]=useState('');
 useEffect(()=>{communityRequest<{reports:Report[]}>('/api/community/moderation').then(data=>setReports(data.reports)).catch(setError).finally(()=>setLoading(false));},[]);
 async function review(item:CommunityItem){setBusy(item.id);setError(null);try{const result=await communityRequest<{item:CommunityItem}>(`/api/community/${item.id}/moderate`,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action:item.moderationHold?'restore':'hide',reason})});setReports(old=>old.map(row=>row.item.id===item.id?{...row,item:result.item}:row));}catch(e){setError(e);}finally{setBusy('');}}
 return <CommunityShell active="moderation"><section className={styles.hero}><div><span className={styles.eyebrow}>FOCUS STUDIO</span><h1>{t('Community care.','社区审核。')}</h1><p>{t('Review reported creations. Hidden videos cannot be downloaded or republished by their author.','处理被举报作品。隐藏后，公众无法下载，作者也无法重新发布。')}</p></div><ShieldCheck size={35}/></section>
 {!!error&&<div className={styles.alert} role="alert">{errorCopy(error,t)}</div>}
 {loading?<div className={styles.loading}><LoaderCircle size={18}/>{t('Loading reports…','加载举报…')}</div>:<>{!error&&!reports.length&&<div className={styles.empty}><ShieldCheck size={33}/><h2>{t('No reports to review.','暂无待处理举报。')}</h2></div>}{!!reports.length&&<label className={styles.moderationReason}>{t('Review note · visible to the creator','审核说明 · 对作者可见')}<input value={reason} onChange={e=>setReason(e.target.value)} maxLength={500} placeholder={t('Explain a hide or restore decision','说明隐藏或恢复的原因')}/></label>}<div className={styles.moderationList}>{reports.map(row=><article key={row.id} className={styles.moderationCard}><video src={row.item.mediaUrl||undefined} poster={row.item.posterUrl||undefined} controls preload="none" playsInline/><div><span className={styles.eyebrow}>{row.reason} · {row.item.moderationHold?t('HIDDEN','已隐藏'):t('VISIBLE','可见')}</span><h2>{row.item.title}</h2><p>{row.details||t('No additional details.','无补充说明。')}</p>{row.item.moderationReason&&<p>{row.item.moderationReason}</p>}<div><a href={`/community/${row.item.id}`} className={styles.textLink}>{t('View details','查看详情')}<ArrowUpRight size={13}/></a><button disabled={!!busy} className={styles.secondary} onClick={()=>void review(row.item)}>{row.item.moderationHold?<Eye size={15}/>:<EyeOff size={15}/>} {busy===row.item.id?t('Saving…','保存中…'):row.item.moderationHold?t('Restore access','恢复访问'):t('Hide video','隐藏视频')}</button></div></div></article>)}</div></>}
 </CommunityShell>;
}
