'use client';
import { useEffect, useRef, useState } from 'react';
import { ArrowUpRight, Film, FolderLock, LoaderCircle, Play, Search, Sparkles } from 'lucide-react';
import { useLocale } from '@/components/locale/locale-provider';
import { CommunityShell, PublishLink } from './shell';
import { communityRequest, CommunityError, errorCopy, signInPath, type CommunityItem } from './types';
import styles from './community.module.css';

type GalleryMode='explore'|'ai'|'mine';
export function CommunityGallery({mine=false,mode}:{mine?:boolean;mode?:GalleryMode}){
 const section=mode||(mine?'mine':'explore');const own=section==='mine';
 const{t}=useLocale();const[category,setCategory]=useState('');const[status,setStatus]=useState('');
 const[items,setItems]=useState<CommunityItem[]>([]);const[cursor,setCursor]=useState<string|null>(null);const[loading,setLoading]=useState(true);const[error,setError]=useState<unknown>(null);const[anonymous,setAnonymous]=useState(false);const[query,setQuery]=useState('');const[refresh,setRefresh]=useState(0);const[search,setSearch]=useState('');const[queryReady,setQueryReady]=useState(false);const generation=useRef(0);
 const activeCategory=section==='ai'?'ai-video':category;
 useEffect(()=>{const initialQuery=new URLSearchParams(window.location.search).get('q')?.slice(0,120)||'';setQuery(initialQuery);setSearch(initialQuery.trim());setQueryReady(true);},[]);
 useEffect(()=>{if(!queryReady)return;const timer=setTimeout(()=>setSearch(query.trim()),250);return()=>clearTimeout(timer);},[query,queryReady]);
 useEffect(()=>{if(!queryReady)return;generation.current++;const controller=new AbortController();setLoading(true);setError(null);setAnonymous(false);setItems([]);setCursor(null);
 communityRequest<{items:CommunityItem[];nextCursor:string|null}>(`/api/community${own?'/mine':''}?limit=${own?50:24}&category=${encodeURIComponent(activeCategory)}&q=${encodeURIComponent(search)}`,{signal:controller.signal}).then(data=>{if(controller.signal.aborted)return;setItems(data.items);setCursor(data.nextCursor);}).catch(err=>{if(controller.signal.aborted)return;if(err instanceof CommunityError&&/sign_in|auth/.test(err.code))setAnonymous(true);else setError(err);}).finally(()=>{if(!controller.signal.aborted)setLoading(false);});return()=>controller.abort();
 },[own,activeCategory,refresh,search,queryReady]);
 async function more(){const current=generation.current;setLoading(true);setError(null);try{const data=await communityRequest<{items:CommunityItem[];nextCursor:string|null}>(`/api/community${own?'/mine':''}?category=${encodeURIComponent(activeCategory)}&q=${encodeURIComponent(search)}&cursor=${encodeURIComponent(cursor||'')}`);if(current!==generation.current)return;setItems(old=>[...old,...data.items.filter(x=>!old.some(y=>y.id===x.id))]);setCursor(data.nextCursor);}catch(err){if(current===generation.current)setError(err);}finally{if(current===generation.current)setLoading(false);}}
 const visible=items.filter(item=>!own||!status||item.status===status);
 const hasFilter=!!search||!!status||!!category;
 return <CommunityShell active={section} search={{value:query,onChange:setQuery,placeholder:section==='ai'?t('Search AI footage','搜索 AI 素材'):own?t('Search my work','搜索我的作品'):t('Search creations or creators','搜索作品或创作者')}}>
   <header className={styles.pageHeading}><h1>{section==='ai'?t('AI footage','AI 素材'):own?t('My work','我的作品'):t('Discover','发现作品')}</h1>{own?<span className={styles.pageHint}><FolderLock size={13}/>{t('Drafts are private','草稿仅自己可见')}</span>:<span className={styles.pageHint}>{section==='ai'?t('Download. Make it yours.','下载素材，继续创作。'):t('Made with Focus Studio','用 Focus Studio 创作')}</span>}</header>
   <div className={styles.toolbar}>
     {own?<div className={styles.filters} role="group" aria-label={t('Publication status','发布状态')}>{[['',t('All','全部')],['published',t('Published','已发布')],['draft',t('Drafts','草稿')]].map(([value,label])=><button key={value} aria-pressed={status===value} onClick={()=>setStatus(value)}>{label}</button>)}</div>:section==='explore'?<div className={styles.filters} role="group" aria-label={t('Filter creations','筛选作品')}>{[['',t('All creations','全部作品')],['demo',t('Product demos','产品 Demo')]].map(([value,label])=><button key={value} aria-pressed={category===value} onClick={()=>setCategory(value)}>{label}</button>)}<a href="/community/ai"><Sparkles size={14}/>{t('AI footage','AI 素材')}<ArrowUpRight size={12}/></a></div>:<span className={styles.subtleLabel}><Sparkles size={14}/>{t('AI-generated videos','AI 生成视频')}</span>}
     {own?<select className={styles.categorySelect} value={category} onChange={event=>setCategory(event.target.value)} aria-label={t('Category','分类')}><option value="">{t('All categories','全部分类')}</option><option value="demo">{t('Product demos','产品 Demo')}</option><option value="ai-video">{t('AI footage','AI 素材')}</option></select>:<span className={styles.sortLabel}>{t('Latest','最新发布')}</span>}
   </div>
   {!!error&&<div className={styles.alert} role="alert">{errorCopy(error,t)}<button onClick={()=>setRefresh(n=>n+1)}>{t('Retry','重试')}</button></div>}
   {anonymous?<section className={styles.empty}><FolderLock size={29}/><h2>{t('Sign in to see your work','登录后查看你的作品')}</h2><a className={styles.primary} href={signInPath('/community/mine')} target="_top">{t('Continue with ChatGPT','使用 ChatGPT 登录')}<ArrowUpRight size={15}/></a></section>:<>
     {!!visible.length&&<div className={styles.grid}>{visible.map(item=><CreationCard key={item.id} item={item} own={own}/>)}</div>}
     {loading&&!items.length?<div className={styles.grid} aria-label={t('Loading creations','正在加载作品')} aria-busy="true">{[0,1,2].map(index=><div key={index} className={styles.skeletonCard} aria-hidden="true"><div/><span/><span/></div>)}</div>:loading?<div className={styles.loading} role="status"><LoaderCircle size={17}/>{t('Loading…','加载中…')}</div>:null}
     {!loading&&!error&&!visible.length&&<section className={styles.empty}>
       {hasFilter?<Search size={28}/>:section==='ai'?<Sparkles size={28}/>:own?<FolderLock size={28}/>:<Film size={28}/>}
       <h2>{hasFilter?t('No matching creations','暂无匹配作品'):own?t('Your creations will appear here','你的作品会显示在这里'):section==='ai'?t('No AI footage shared yet','还没有分享的 AI 素材'):t('No community creations yet','社区还没有作品')}</h2>
       {hasFilter?<button className={styles.secondary} onClick={()=>{setQuery('');setCategory('');setStatus('');}}>{t('Clear filters','清除筛选')}</button>:<PublishLink category={section==='ai'?'ai-video':undefined}/>}
     </section>}
     {cursor&&!loading&&<div className={styles.more}><button className={styles.secondary} onClick={()=>void more()}>{t('Load more','加载更多')}</button></div>}
   </>}
   {!own&&!loading&&!error&&!query&&!items.length&&section==='explore'&&<section className={styles.exampleSection} aria-labelledby="official-example-title"><h2 id="official-example-title">{t('From Focus Studio','Focus Studio 官方示例')}</h2><div className={styles.grid}><a href="/community/showcase" className={styles.card}><div className={styles.cardMedia}><img src="/media/focus-studio-demo-flat.jpg" loading="lazy" alt=""/><span className={styles.cardPlay}><Play size={18} fill="currentColor"/></span><span className={styles.cardBadge}>{t('Official example','官方示例')}</span></div><div className={styles.cardInfo}><h3>{t('A closer look','聚焦每个细节')}</h3><div className={styles.cardByline}><img src="/icons/icon-192.png" width="20" height="20" alt=""/><span>Focus Studio</span></div></div></a></div></section>}
 </CommunityShell>;
}
function CreationCard({item,own}:{item:CommunityItem;own:boolean}){
 const{t}=useLocale();
 const badge=item.moderationHold?t('Under review','审核中'):own&&item.status==='draft'?t('Private draft','私密草稿'):own?t('Published','已发布'):item.category==='demo'?t('Product demo','产品 Demo'):t('AI footage','AI 素材');
 return <article className={styles.card}>
   <a className={styles.cardMedia} href={`/community/${item.id}`} aria-label={`${t('Watch','观看')} ${item.title}`}>{item.posterUrl?<img src={item.posterUrl} loading="lazy" decoding="async" alt=""/>:<div className={styles.cardPlaceholder}>{item.category==='demo'?<Film size={31}/>:<Sparkles size={31}/>}</div>}<span className={styles.cardPlay}><Play size={18} fill="currentColor"/></span><span className={styles.cardBadge}>{badge}</span></a>
   <div className={styles.cardInfo}><h3><a href={`/community/${item.id}`}>{item.title}</a></h3><div className={styles.cardByline}><span className={styles.miniAvatar}>{item.authorName.slice(0,1).toUpperCase()}</span><span>{item.authorName}</span></div></div>
 </article>;
}
