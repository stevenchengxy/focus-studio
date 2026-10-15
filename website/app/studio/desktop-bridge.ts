export interface DesktopCapabilities {platform:'win32'|'linux'|'darwin';systemAudio:'loopback'|'unavailable';microphone:true;}
export type CommunityConnectionState = {state:'idle'|'connecting'|'awaitingApproval'|'confirming'|'confirmed'|'error';userCode?:string;expiresIn?:number;error?:string;requiresReconnect?:boolean};
interface DesktopBridge {
  version:1;
  getCapabilities():Promise<DesktopCapabilities>;
  request(input:{path:string;method:'GET'|'POST';body?:unknown}):Promise<{status:number;body:unknown}>;
  startSignIn():Promise<{userCode:string;expiresIn:number}>;
  signOut():Promise<void>;
  onAccountChanged(fn:()=>void):()=>void;
  communityStatus?():Promise<CommunityConnectionState>;
  startCommunityConnection?():Promise<CommunityConnectionState>;
  cancelCommunityConnection?():Promise<CommunityConnectionState>;
  retryCommunityConfirmation?():Promise<CommunityConnectionState>;
  disconnectCommunity?():Promise<CommunityConnectionState>;
  onCommunityChanged?(fn:()=>void):()=>void;
  setActivity?(state:{recording:boolean;exporting:boolean}):void;
}
declare global {interface Window {focusDesktop?:DesktopBridge;}}
export async function studioRequest(path:string,body?:unknown){
  if(typeof window!=='undefined'&&window.focusDesktop?.version===1){
    const response=await window.focusDesktop.request({path,method:body===undefined?'GET':'POST',body});
    return {ok:response.status>=200&&response.status<300,status:response.status,json:async()=>response.body};
  }
  return fetch(path,body===undefined?{}:{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});
}
