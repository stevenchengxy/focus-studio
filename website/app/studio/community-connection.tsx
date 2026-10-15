'use client';
import { useEffect, useState } from 'react';
import { Check, LoaderCircle } from 'lucide-react';
import { useLocale } from '@/components/locale/locale-provider';
import type { CommunityConnectionState } from './desktop-bridge';

export function DesktopCommunityConnection() {
  const {t}=useLocale();
  const [state,setState]=useState<CommunityConnectionState>({state:'idle'});
  const [supported,setSupported]=useState(false);
  const [expanded,setExpanded]=useState(false);
  const [requesting,setRequesting]=useState(false);
  const [loadError,setLoadError]=useState(false);
  useEffect(()=>{
    const bridge=window.focusDesktop;
    if(!bridge?.communityStatus||!bridge.startCommunityConnection)return;
    setSupported(true);let active=true;
    const refresh=()=>bridge.communityStatus!().then(value=>{if(active){setState(value);setLoadError(false);}}).catch(()=>{if(active)setLoadError(true);});
    void refresh();const unsubscribe=bridge.onCommunityChanged?.(()=>void refresh());
    return()=>{active=false;unsubscribe?.();};
  },[]);
  const waiting=['connecting','awaitingApproval','confirming'].includes(state.state);
  async function act(method:'startCommunityConnection'|'cancelCommunityConnection'|'retryCommunityConfirmation'|'disconnectCommunity') {
    const action=window.focusDesktop?.[method];if(!action||requesting)return;
    setRequesting(true);setLoadError(false);
    try{setState(await action());}catch{setLoadError(true);}finally{setRequesting(false);}
  }
  return <details className="studio-community-connection" open={expanded} onToggle={event=>setExpanded(event.currentTarget.open)}>
    <summary>{state.state==='confirmed'&&<Check size={14}/>} {t('Community publishing','社区发布')}</summary>
    <section aria-label={t('Community publishing','社区发布')}>
      <h2>{t('Share from your account','连接账户，分享作品')}</h2>
      {!supported?<><p>{t('Update Focus Studio to connect this desktop app and enable publishing.','请更新 Focus Studio，以连接客户端并开通发布功能。')}</p><a href="/?download=1" target="_blank" rel="noreferrer">{t('Download the latest version','下载最新版')}</a></>:<>
        {state.state==='confirmed'?<><p role="status">{t('This app is confirmed. Sign in to the community with the same ChatGPT account to publish.','客户端已确认。请使用同一个 ChatGPT 账户登录社区发布作品。')}</p><a href="/community/new" target="_blank" rel="noreferrer">{t('Publish a creation','发布作品')}</a><button disabled={requesting} onClick={()=>void act('disconnectCommunity')}>{t('Disconnect this app','断开此客户端连接')}</button></>:<>
          <p>{t('Connect your ChatGPT account once in this app before uploading videos or footage to the community.','首次向社区上传视频或素材前，请在此客户端中连接一次 ChatGPT 账户。')}</p>
          {waiting&&<p role="status"><LoaderCircle size={14}/>{state.state==='awaitingApproval'?t('Approve the connection in your browser, then return here.','请在浏览器中批准连接，然后返回这里。'):t('Confirming this app…','正在确认客户端…')}</p>}
          {state.userCode&&<p className="studio-community-code">{state.userCode}</p>}
          {!waiting?<button disabled={requesting} onClick={()=>void act(state.state==='error'&&!state.requiresReconnect?'retryCommunityConfirmation':'startCommunityConnection')}>{requesting?t('Connecting…','正在连接…'):state.requiresReconnect?t('Reconnect ChatGPT','重新连接 ChatGPT'):t('Connect ChatGPT','连接 ChatGPT')}</button>:<button disabled={requesting} onClick={()=>void act('cancelCommunityConnection')}>{t('Cancel connection','取消连接')}</button>}
        </>}
        {(loadError||state.state==='error')&&<p role="alert">{t('Confirmation did not complete. Check your connection and try again.','确认未完成，请检查网络后重试。')}</p>}
      </>}
      <small>{t('Local recording, editing and export remain free without sign-in.','本地录制、剪辑和导出继续免费，无需登录。')}</small>
    </section>
  </details>;
}
