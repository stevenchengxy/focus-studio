'use client';
import { useEffect, useRef, useState } from 'react';
import { ArrowLeft, ArrowUpRight, Check, Copy, Download, EyeOff, Flag, FolderLock, LoaderCircle, Pencil, Trash2, Upload, X } from 'lucide-react';
import { useLocale } from '@/components/locale/locale-provider';
import { CommunityShell } from './shell';
import { MetadataFields, RightsConsent } from './publish';
import { communityRequest, errorCopy, signInPath, type CommunityItem } from './types';
import styles from './community.module.css';
import dialogStyles from './detail-dialog.module.css';
export function CommunityDetail({id}:{id:string}){
 const{t,locale}=useLocale();const[item,setItem]=useState<CommunityItem|null>(null);const[authenticated,setAuthenticated]=useState(false);const[loading,setLoading]=useState(true);const[error,setError]=useState<unknown>(null);const[busy,setBusy]=useState(false);const[editing,setEditing]=useState(false);const[consent,setConsent]=useState(false);const[copied,setCopied]=useState(false);const[confirm,setConfirm]=useState<'delete'|'unpublish'|null>(null);const[report,setReport]=useState(false);const[reported,setReported]=useState(false);const[reason,setReason]=useState('copyright');const[details,setDetails]=useState('');const[videoFailed,setVideoFailed]=useState(false);
 const[fields,setFields]=useState({title:'',description:'',productUrl:'',category:'demo' as 'demo'|'ai-video',authorName:''});
 const endpoint=`/api/community/${encodeURIComponent(id)}`;
 const confirmationDialog=useRef<HTMLDialogElement>(null);
 const returnFocus=useRef<HTMLElement|null>(null);
 const ownerActionButton=useRef<HTMLButtonElement>(null);
 const restoreFocus=()=>{(returnFocus.current?.isConnected?returnFocus.current:ownerActionButton.current)?.focus();};
 useEffect(()=>{
  const dialog=confirmationDialog.current;if(!dialog)return;
  if(confirm){
   returnFocus.current=document.activeElement instanceof HTMLElement?document.activeElement:null;
   if(!dialog.open)dialog.showModal();
  }else if(dialog.open){dialog.close();restoreFocus();}
 },[confirm]);
 const closeConfirmation=()=>{if(!busy)setConfirm(null);};
 function toggleEditing(){
  if(item)setFields({title:item.title,description:item.description,productUrl:item.productUrl||'',category:item.category,authorName:item.authorName});
  setEditing(value=>!value);setError(null);
 }

 useEffect(()=>{const controller=new AbortController();setLoading(true);setError(null);setVideoFailed(false);setEditing(false);setConfirm(null);setReport(false);setReported(false);communityRequest<{item:CommunityItem;authenticated:boolean}>(endpoint,{signal:controller.signal}).then(data=>{if(controller.signal.aborted)return;setItem(data.item);setAuthenticated(data.authenticated);setFields({title:data.item.title,description:data.item.description,productUrl:data.item.productUrl||'',category:data.item.category,authorName:data.item.authorName});}).catch(e=>{if(!controller.signal.aborted)setError(e);}).finally(()=>{if(!controller.signal.aborted)setLoading(false);});return()=>controller.abort();},[endpoint]);
 async function action(name:string){if(busy)return;setBusy(true);setError(null);try{
  if(name==='delete'){await communityRequest(endpoint,{method:'DELETE'});window.location.assign('/community/mine');return;}
  if(name==='report'){await communityRequest(`${endpoint}/report`,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({reason,details})});setReported(true);setReport(false);return;}
  const data=await communityRequest<{item:CommunityItem}>(name==='edit'?endpoint:`${endpoint}/${name}`,{method:name==='edit'?'PATCH':'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(name==='edit'?fields:name==='publish'?{license:'CC-BY-4.0',confirmRights:consent}:{})});
  setItem(data.item);setEditing(false);setConfirm(null);setConsent(false);
 }catch(e){setError(e);}finally{setBusy(false);}}
 async function copyAttribution(){if(!item)return;try{await navigator.clipboard.writeText(`${item.title} — ${item.authorName}\n${window.location.origin}/community/${item.id}\nCC BY 4.0 · https://creativecommons.org/licenses/by/4.0/`);setCopied(true);setTimeout(()=>setCopied(false),2400);}catch{setError(new Error('clipboard'));}}
 const hasMedia=!!(item?.hasMedia??item?.uploaded);
 return <CommunityShell active={item?.isOwner?'mine':'explore'}><a href={item?.isOwner?'/community/mine':'/community'} className={styles.back}><ArrowLeft size={15}/>{item?.isOwner?t('My work','我的作品'):t('Community','社区')}</a>
  {!!error&&!confirm&&<div className={styles.alert} role="alert">{errorCopy(error,t)}</div>}
  {loading?<div className={styles.loading} role="status"><LoaderCircle size={18}/>{t('Opening video…','正在打开视频…')}</div>:!item?<section className={styles.empty}><EyeOff size={32}/><h1>{t('This work is not available.','此作品暂不可用。')}</h1><p>{t('It may be private or no longer shared. Sign in if this is your draft.','作品可能是私密草稿或已取消发布。如果是你的作品，请先登录。')}</p><a className={styles.primary} href={signInPath(`/community/${id}`)} target="_top">{t('Continue with ChatGPT','使用 ChatGPT 登录')}</a></section>:<>
   <header className={styles.detailHeader}><div><span className={styles.eyebrow}>{item.moderationHold?t('HIDDEN · UNDER REVIEW','已隐藏 · 审核中'):item.status==='draft'?t('PRIVATE DRAFT · ONLY YOU','私密草稿 · 仅自己可见'):item.category==='demo'?t('PRODUCT DEMO','产品 DEMO'):t('AI FOOTAGE','AI 素材')}</span><h1>{item.title}</h1><div className={styles.byline}><span className={styles.avatar}>{item.authorName.slice(0,1).toUpperCase()}</span><span>{item.authorName}</span><span>·</span><time>{new Date((item.publishedAt||item.createdAt)*1000).toLocaleDateString(locale==='zh'?'zh-CN':'en-US',{year:'numeric',month:'short',day:'numeric'})}</time></div></div>
   {hasMedia&&<a className={styles.primary} href={item.downloadUrl||undefined}><Download size={17}/>{t('Download video','下载视频')}</a>}</header>
   {item.isOwner&&item.moderationHold&&<section className={styles.alert} role="status"><div><strong>{t('Publishing is paused while this work is reviewed.','作品正在审核，暂时无法公开发布。')}</strong><p>{t('The community cannot access it. You can still edit its details or delete your copy.','其他用户暂时无法访问，你仍可以编辑介绍或删除副本。')}</p>{item.moderationReason&&<p>{t('Review note: ','审核说明：')}{item.moderationReason}</p>}</div></section>}
   <div className={styles.player}>{hasMedia?<video key={item.id} src={item.mediaUrl||undefined} poster={item.posterUrl||undefined} playsInline controls preload="metadata" aria-label={item.title} onError={()=>setVideoFailed(true)}/>:<div className={styles.empty}><FolderLock size={30}/><h2>{t('Upload not completed.','上传尚未完成。')}</h2><p>{t('This private draft has no playable video. Keep your original file, remove this draft below and start a new upload.','此私密草稿尚无可播放的视频。请保留本地原文件，在下方删除此草稿后重新上传。')}</p></div>}</div>
   {videoFailed&&<p className={styles.alert} role="status">{t('This browser cannot preview this video. Download it to play locally.','当前浏览器无法预览此视频，可以下载后在本地播放。')}</p>}
   <div className={styles.detailBody}><section className={styles.description}><h2>{t('About this creation','关于作品')}</h2><p>{item.description}</p>{item.productUrl&&<a className={styles.secondary} href={item.productUrl} target="_blank" rel="noopener noreferrer nofollow ugc">{t('Explore the product','了解产品')}<ArrowUpRight size={16}/></a>}</section><aside className={styles.licenseCard}>{item.status==='published'?<><span className={styles.eyebrow}>{t('READY TO REMIX','欢迎再创作')}</span><h3>CC BY 4.0</h3><p>{t('Download, adapt and reuse with credit. Mention any changes you make.','可下载、修改和复用。使用时请署名，并说明所做修改。')}</p><button className={styles.secondary} onClick={()=>void copyAttribution()}>{copied?<Check size={15}/>:<Copy size={15}/>} {copied?t('Copied','已复制'):t('Copy attribution','复制署名信息')}</button><a className={styles.textLink} href="https://creativecommons.org/licenses/by/4.0/" target="_blank" rel="noreferrer">{t('License details','许可说明')}<ArrowUpRight size={13}/></a></>:<><FolderLock size={21}/><h3>{t('Only you can see this.','仅自己可见。')}</h3><p>{t('Publish whenever you are ready. Your local original stays yours.','准备好再发布。本地原始文件不会改变。')}</p></>}</aside></div>
   {item.isOwner&&<section className={styles.ownerPanel}><div className={styles.ownerActions}><button ref={ownerActionButton} className={styles.secondary} onClick={toggleEditing} disabled={busy}>{editing?<X size={15}/>:<Pencil size={15}/>} {editing?t('Cancel editing','取消编辑'):t('Edit details','编辑介绍')}</button>{item.status==='published'&&<button className={styles.secondary} onClick={()=>{setError(null);setConfirm('unpublish');}} disabled={busy}><EyeOff size={15}/>{t('Unpublish','取消发布')}</button>}<button className={styles.dangerButton} onClick={()=>{setError(null);setConfirm('delete');}} disabled={busy}><Trash2 size={15}/>{t('Delete','删除')}</button></div>
    {editing&&<form className={styles.editForm} onSubmit={e=>{e.preventDefault();void action('edit');}}><MetadataFields value={fields} onChange={setFields} disabled={busy}/><button className={styles.primary} type="submit" disabled={busy}>{busy?t('Saving…','保存中…'):t('Save details','保存介绍')}</button></form>}
    {item.status==='draft'&&hasMedia&&!editing&&<div className={styles.publishDraft}><h2>{item.moderationHold?t('Publishing paused','发布已暂停'):t('Ready to share?','准备好分享了吗？')}</h2><RightsConsent checked={consent} onChange={setConsent} disabled={busy||item.moderationHold}/><button className={styles.primary} disabled={!consent||busy||item.moderationHold} onClick={()=>void action('publish')}><Upload size={16}/>{busy?t('Publishing…','发布中…'):t('Publish to community','发布到社区')}</button></div>}
   </section>}
   {item.status==='published'&&!item.isOwner&&<div className={styles.reportRow}>{reported?<span role="status">{t('Report received. Thank you for helping care for this community.','已收到举报，感谢你帮助维护社区。')}</span>:<button aria-expanded={report} aria-controls="report-panel" onClick={()=>setReport(!report)}><Flag size={14}/>{t('Report this work','举报作品')}</button>}</div>}
   {report&&<section id="report-panel" className={styles.reportPanel}><h3>{t('Report this work','举报作品')}</h3>{!authenticated?<a className={styles.primary} href={signInPath(`/community/${id}`)} target="_top">{t('Sign in to report','登录后举报')}</a>:<form onSubmit={e=>{e.preventDefault();void action('report');}}><label>{t('Reason','原因')}<select value={reason} onChange={e=>setReason(e.target.value)}><option value="copyright">{t('Copyright or ownership','版权或归属')}</option><option value="privacy">{t('Privacy','隐私')}</option><option value="inappropriate">{t('Inappropriate content','不当内容')}</option><option value="other">{t('Other','其他')}</option></select></label><label>{t('Details','补充说明')}<textarea value={details} onChange={e=>setDetails(e.target.value)} maxLength={1000} rows={3}/></label><button type="submit" className={styles.secondary} disabled={busy}>{t('Send report','提交举报')}</button></form>}</section>}
  </>}
  <dialog ref={confirmationDialog} className={`${styles.confirmDialog} ${dialogStyles.modal}`} aria-labelledby="confirm-title" aria-describedby="confirm-description" onCancel={event=>{event.preventDefault();closeConfirmation();}} onClose={()=>{setConfirm(null);restoreFocus();}} onClick={event=>{
   if(event.target!==event.currentTarget)return;
   const bounds=event.currentTarget.getBoundingClientRect();
   if(event.clientX<bounds.left||event.clientX>bounds.right||event.clientY<bounds.top||event.clientY>bounds.bottom)closeConfirmation();
  }}>
   {confirm&&<><h2 id="confirm-title">{confirm==='delete'?t('Delete this community copy?','删除这个社区副本？'):t('Unpublish this video?','取消发布这个视频？')}</h2>
   <p id="confirm-description">{confirm==='delete'?t('The uploaded video and its details will be permanently removed. Your local files are not affected.','将永久删除已上传的视频及介绍，本地文件不受影响。'):t('It will become a private draft, visible only to you.','作品会变成仅自己可见的私密草稿。')}</p>
   {item?.license==='CC-BY-4.0'&&<small>{t('Copies already downloaded under CC BY 4.0 keep their reuse rights.','已经按照 CC BY 4.0 下载的副本仍保留复用许可。')}</small>}
   {!!error&&<p className={styles.alert} role="alert">{errorCopy(error,t)}</p>}
   <div><button autoFocus className={styles.secondary} disabled={busy} onClick={closeConfirmation}>{t('Cancel','取消')}</button><button className={styles.primary} disabled={busy} onClick={()=>void action(confirm)}>{busy?t('Saving…','处理中…'):confirm==='delete'?t('Delete copy','删除副本'):t('Unpublish','取消发布')}</button></div></>}
  </dialog>
 </CommunityShell>;
}
