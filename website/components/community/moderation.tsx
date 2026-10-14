'use client';
import {useEffect,useRef,useState} from 'react';
import {ChevronDown,ChevronUp,Eye,EyeOff,LoaderCircle,RotateCcw,ShieldCheck,Trash2,X} from 'lucide-react';
import {useLocale} from '@/components/locale/locale-provider';
import {CommunityShell} from './shell';
import {CommunityError,communityRequest,errorCopy,signInPath,type CommunityItem} from './types';
import shared from './community.module.css';
import styles from './moderation.module.css';

type Scope='all'|'published'|'reported'|'held'|'deleted';
type Action='hide'|'reinstate'|'delete'|'restore';
type Item=CommunityItem&{deletedAt:number|null;moderatedAt:number|null;moderatedBy:string|null;moderationRevision:number;reportCount?:number;lastReportAt?:number|null};
type Detail={item:Item;reports:{id:string;reason:string;details:string;createdAt:number}[];audit:{id:string;action:Action;reason:string;actorId:string;actorName:string;createdAt:number;revision:number}[]};
type Listing={items:Item[];nextCursor:string|null};
const scopes:Scope[]=['all','published','reported','held','deleted'];
export function CommunityModeration(){
  const {t,locale}=useLocale();
  const [scope,setScope]=useState<Scope>('all'),[query,setQuery]=useState(''),[category,setCategory]=useState('');
  const [items,setItems]=useState<Item[]>([]),[nextCursor,setNextCursor]=useState<string|null>(null),[refresh,setRefresh]=useState(0);
  const [loading,setLoading]=useState(true),[more,setMore]=useState(false),[error,setError]=useState<unknown>(null),[notice,setNotice]=useState('');
  const [selected,setSelected]=useState<string|null>(null),[detail,setDetail]=useState<Detail|null>(null),[detailError,setDetailError]=useState<unknown>(null);
  const [action,setAction]=useState<Action|null>(null),[reason,setReason]=useState(''),[busy,setBusy]=useState(false);
  const pageVersion=useRef(0);
  const params=new URLSearchParams({scope,limit:'24',...(query.trim()?{q:query.trim()}:{}),...(category?{category}:{})}).toString();
  const scopeName=(value:Scope)=>({all:t('All work','全部作品'),published:t('Published','已发布'),reported:t('Reported','被举报'),held:t('Taken down','已下架'),deleted:t('Trash','回收站')})[value];
  const actionName=(value:Action)=>({hide:t('Take down','下架'),reinstate:t('Reinstate','解除下架'),delete:t('Move to trash','移入回收站'),restore:t('Restore work','恢复作品')})[value];
  const date=(seconds:number)=>new Date(seconds*1000).toLocaleString(locale==='zh'?'zh-CN':'en-US',{dateStyle:'medium',timeStyle:'short'});
  const status=(item:Item)=>item.deletedAt?t('In trash','回收站'):item.moderationHold?t('Taken down','已下架'):item.status==='published'?t('Published','已发布'):t('Author unpublished','作者已取消发布');
  function copy(err:unknown){
    if(err instanceof CommunityError){
      if(err.code==='community_review_changed'||err.code==='community_invalid_moderation_state')return t('This work changed. Refresh it before reviewing.','作品状态已更改，请刷新后再处理。');
      if(err.code==='community_review_reason')return t('Enter a review reason, up to 500 characters.','请填写审核原因，最多 500 个字符。');
    }
    return errorCopy(err,t);
  }
  useEffect(()=>{
    pageVersion.current++;setMore(false);
    const controller=new AbortController();setLoading(true);setError(null);setSelected(null);setItems([]);setNextCursor(null);
    const timer=setTimeout(()=>{void communityRequest<Listing>(`/api/community/moderation?${params}`,{signal:controller.signal}).then(data=>{if(!controller.signal.aborted){setItems(data.items);setNextCursor(data.nextCursor);}}).catch(err=>{if(!controller.signal.aborted)setError(err);}).finally(()=>{if(!controller.signal.aborted)setLoading(false);});},200);
    return()=>{clearTimeout(timer);controller.abort();};
  },[params,refresh]);
  useEffect(()=>{
    setDetail(null);setDetailError(null);setAction(null);setReason('');
    if(!selected)return;
    const controller=new AbortController();
    void communityRequest<Detail>(`/api/community/${selected}/moderate`,{signal:controller.signal}).then(data=>{if(!controller.signal.aborted)setDetail(data);}).catch(err=>{if(!controller.signal.aborted)setDetailError(err);});
    return()=>controller.abort();
  },[selected]);
  async function loadMore(){
    if(!nextCursor||more)return;const version=pageVersion.current;setMore(true);setError(null);
    try{const data=await communityRequest<Listing>(`/api/community/moderation?${params}&cursor=${encodeURIComponent(nextCursor)}`);if(version!==pageVersion.current)return;setItems(old=>[...old,...data.items.filter(item=>!old.some(previous=>previous.id===item.id))]);setNextCursor(data.nextCursor);}catch(err){if(version===pageVersion.current)setError(err);}finally{if(version===pageVersion.current)setMore(false);}
  }
  async function submit(event:React.FormEvent){
    event.preventDefault();if(!detail||!action||busy)return;setBusy(true);setDetailError(null);setNotice('');
    try{await communityRequest(`/api/community/${detail.item.id}/moderate`,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action,reason:reason.trim(),expectedRevision:detail.item.moderationRevision})});setNotice(t('Review saved.','处理结果已保存。'));setSelected(null);setRefresh(value=>value+1);}catch(err){setDetailError(err);}finally{setBusy(false);}
  }
  const denied=error instanceof CommunityError&&['community_sign_in_required','community_moderator_required'].includes(error.code);
  return <CommunityShell active="moderation" search={{value:query,onChange:setQuery,placeholder:t('Search work or creators','搜索作品或作者')}}>
    <header className={styles.heading}><div><h1><ShieldCheck size={24}/>{t('Community management','社区管理')}</h1><p>{t('Review public work, reports and removed uploads.','管理公开作品、举报与回收站。')}</p></div><button type="button" className={shared.secondary} onClick={()=>setRefresh(value=>value+1)} disabled={loading||busy}><RotateCcw size={14}/>{t('Refresh','刷新')}</button></header>
    <div className={styles.toolbar}><nav aria-label={t('Review filters','管理筛选')}>{scopes.map(value=><button type="button" key={value} aria-pressed={scope===value} onClick={()=>setScope(value)} disabled={busy}>{scopeName(value)}</button>)}</nav><label><span className={styles.srOnly}>{t('Category','分类')}</span><select value={category} onChange={event=>setCategory(event.target.value)} disabled={busy}><option value="">{t('All categories','全部分类')}</option><option value="demo">{t('Product demos','产品演示')}</option><option value="ai-video">{t('AI footage','AI 素材')}</option></select></label></div>
    <div role="status" className={styles.notice}>{notice}</div>
    {!!error&&<div className={shared.alert} role="alert">{copy(error)}{error instanceof CommunityError&&error.code==='community_sign_in_required'&&<a href={signInPath('/community/moderation')} target="_top"> {t('Sign in','登录')}</a>}</div>}
    {loading?<div className={shared.loading}><LoaderCircle size={18}/>{t('Loading work…','加载作品…')}</div>:!items.length&&!error?<div className={shared.empty}><ShieldCheck size={30}/><h2>{t('No work in this view.','此筛选下暂无作品。')}</h2><p>{t('Change the filter or search to see other work.','可切换筛选或搜索其他作品。')}</p></div>:null}
    {!denied&&<div className={styles.list}>{items.map(item=><article key={item.id} className={styles.row}>
      <button type="button" className={styles.summary} aria-expanded={selected===item.id} aria-controls={`review-${item.id}`} disabled={busy} onClick={()=>setSelected(value=>value===item.id?null:item.id)}>
        <div className={styles.cover}>{item.posterUrl?<img src={item.posterUrl} alt="" loading="lazy"/>:<Eye size={19}/>}</div>
        <div className={styles.title}><h2>{item.title}</h2><span>{item.authorName} · {item.category==='ai-video'?t('AI footage','AI 素材'):t('Product demo','产品演示')}</span></div>
        <div className={styles.state}><span data-warning={!!item.moderationHold||!!item.deletedAt}>{status(item)}</span>{!!item.reportCount&&<small>{item.reportCount} {t('reports','条举报')}</small>}</div>
        {selected===item.id?<ChevronUp size={17}/>:<ChevronDown size={17}/>}</button>
      {selected===item.id&&<section className={styles.review} id={`review-${item.id}`} aria-label={t('Review details','审核详情')}>
        {!!detailError&&<div className={shared.alert} role="alert">{copy(detailError)}</div>}
        {!detail&&!detailError?<div className={shared.loading}><LoaderCircle size={16}/>{t('Loading details…','加载详情…')}</div>:detail&&<>
          <div className={styles.detailGrid}><div>{detail.item.mediaUrl&&<video controls playsInline preload="none" poster={detail.item.posterUrl||undefined} src={detail.item.mediaUrl}/>}<p className={styles.description}>{detail.item.description}</p></div><div className={styles.context}>
            {!!detail.reports.length&&<section><h3>{t('Reports','举报')} <span>{detail.reports.length===100?t('latest 100','最近 100 条'):detail.reports.length}</span></h3><ul>{detail.reports.map(report=><li key={report.id}><strong>{({copyright:t('Copyright','版权'),privacy:t('Privacy','隐私'),inappropriate:t('Inappropriate content','不当内容'),other:t('Other','其他')} as Record<string,string>)[report.reason]||report.reason}</strong><time dateTime={new Date(report.createdAt*1000).toISOString()}>{date(report.createdAt)}</time>{report.details&&<p>{report.details}</p>}</li>)}</ul></section>}
            <section><h3>{t('Review history','处理记录')}{detail.audit.length===100&&<span>{t('latest 100','最近 100 条')}</span>}</h3>{detail.audit.length?<ol>{detail.audit.map(event=><li key={event.id}><strong>{actionName(event.action)}</strong><time dateTime={new Date(event.createdAt*1000).toISOString()}>{date(event.createdAt)}</time><p>{event.reason}</p><small title={event.actorId}>{event.actorName}</small></li>)}</ol>:detail.item.moderatedAt?<p>{t('Earlier review','此前的审核')} · {date(detail.item.moderatedAt)}<br/>{detail.item.moderationReason}</p>:<p>{t('No decisions yet.','暂无处理记录。')}</p>}</section>
          </div></div>
          {action?<form className={styles.decision} onSubmit={submit}><div><strong>{actionName(action)}</strong><button type="button" aria-label={t('Cancel review','取消处理')} disabled={busy} onClick={()=>setAction(null)}><X size={17}/></button></div><p>{action==='delete'?t('The work leaves the community and the author’s library. Media stays in admin trash and can be restored.','作品将从社区和作者作品库移除，文件保留在管理回收站，可恢复。'):action==='restore'?t('Restore the work with its previous publication and takedown state.','恢复作品，并保留之前的发布与下架状态。'):action==='hide'?t('Public viewing and downloads stop. The creator can still manage their work.','停止公开浏览与下载，作者仍可管理自己的作品。'):t('Remove the takedown. Work unpublished by its creator stays private.','解除下架；作者已取消发布的作品仍保持私密。')}</p><label htmlFor={`reason-${item.id}`}>{t('Review reason','处理原因')}</label><textarea id={`reason-${item.id}`} value={reason} onChange={event=>setReason(event.target.value)} maxLength={500} required rows={2} disabled={busy}/><div className={styles.confirm}><button type="button" className={shared.secondary} onClick={()=>setAction(null)} disabled={busy}>{t('Cancel','取消')}</button><button type="submit" className={action==='delete'?styles.delete:shared.primary} disabled={busy||!reason.trim()}>{busy&&<LoaderCircle size={14}/>} {t('Confirm: ','确认')}{actionName(action)}</button></div></form>:<div className={styles.actions}>{detail.item.deletedAt?<button type="button" className={shared.secondary} onClick={()=>{setAction('restore');setReason('');}}><RotateCcw size={15}/>{actionName('restore')}</button>:<><button type="button" className={shared.secondary} onClick={()=>{setAction(detail.item.moderationHold?'reinstate':'hide');setReason('');}}>{detail.item.moderationHold?<Eye size={15}/>:<EyeOff size={15}/>} {actionName(detail.item.moderationHold?'reinstate':'hide')}</button><button type="button" className={styles.delete} onClick={()=>{setAction('delete');setReason('');}}><Trash2 size={15}/>{actionName('delete')}</button></>}</div>}
        </>}
      </section>}
    </article>)}</div>}
    {nextCursor&&<button type="button" className={`${shared.secondary} ${styles.more}`} onClick={loadMore} disabled={more||loading||busy}>{more?<LoaderCircle size={15}/>:<ChevronDown size={15}/>} {t('Load more','加载更多')}</button>}
  </CommunityShell>;
}
