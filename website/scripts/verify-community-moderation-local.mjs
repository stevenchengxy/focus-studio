import assert from 'node:assert/strict';

// This exercises the built Worker behind a loopback-only Wrangler preview. The
// synthetic headers emulate Sites' trusted edge, never a public sign-in flow.
const origin=process.env.COMMUNITY_MODERATION_TEST_ORIGIN||'http://127.0.0.1:5180';
if(!['127.0.0.1','localhost'].includes(new URL(origin).hostname))throw Error('Moderation fixtures may only run on loopback.');
const moderator=process.env.COMMUNITY_MODERATION_TEST_ADMIN;
if(!moderator||!/^focus-local-reviewer-[a-f0-9-]+$/.test(moderator))throw Error('Provide the temporary focus-local-reviewer UUID configured only on the local preview.');
const fixture=crypto.randomUUID(),owner=`focus-local-owner-${fixture}`,reporter=`focus-local-reporter-${fixture}`;
const ids=new Set();let checks=0;let communityToken;
const check=(actual,expected)=>{assert.equal(actual,expected);checks++;};
const identity=id=>id?{'oai-authenticated-user-id':id,'oai-authenticated-user-email':`${id}@example.invalid`,'oai-authenticated-user-full-name':'Local%20review%20fixture','oai-authenticated-user-full-name-encoding':'percent-encoded-utf-8'}:{};
const call=(path,{id,method='GET',body,headers={}}={})=>fetch(origin+path,{method,headers:{...identity(id),...(method==='GET'||method==='HEAD'?{}:{Origin:origin}),...(body===undefined?{}:{'Content-Type':'application/json'}),...headers},...(body===undefined?{}:{body:JSON.stringify(body)})});
const expect=async(path,options,status=200)=>{const response=await call(path,options);check(response.status,status);return response;};
const nativeJSON=(path,body={},token)=>fetch(origin+path,{method:'POST',headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},body:JSON.stringify(body)});
const metadata={title:`Local moderation ${fixture}`,authorName:'Local fixture',category:'demo',filename:'fixture.mp4',mimeType:'video/mp4',sizeBytes:128};
const video=new Uint8Array(128);new DataView(video.buffer).setUint32(0,24);video.set(new TextEncoder().encode('ftypisom'),4);
async function create(){const response=await expect('/api/community',{id:owner,method:'POST',body:metadata},201);const data=await response.json();ids.add(data.item.id);return data.item.id;}
async function moderate(id,action,revision,status=200){return (await expect(`/api/community/${id}/moderate`,{id:moderator,method:'POST',body:{action,reason:`Local ${action} verification`,expectedRevision:revision}},status)).json();}
try{
 check((await (await expect('/api/community/me',{id:moderator})).json()).isModerator,true);
 check((await (await expect('/api/community/me',{id:owner})).json()).isModerator,false);
 await expect('/api/community/moderation',{},401);await expect('/api/community/moderation',{id:owner},403);
 let me=await (await expect('/api/community/me',{id:owner})).json();check(me.viewerId,owner);check(me.clientConfirmed,false);check(me.canPublish,false);
 const blocked=await expect('/api/community',{id:owner,method:'POST',body:{...metadata,clientConfirmed:true}},403);check((await blocked.json()).error.code,'community_client_required');
 let pairing=await nativeJSON('/api/device/start',{purpose:'community'});check(pairing.status,200);const grant=await pairing.json();check(grant.purpose,'community');check(new URL(grant.verificationUriComplete).searchParams.get('purpose'),'community');
 pairing=await nativeJSON('/api/device/token',{deviceCode:grant.deviceCode});check(pairing.status,202);
 await expect('/api/device/approve',{id:owner,method:'POST',body:{userCode:grant.userCode,name:'Synthetic moderation author client'}});
 check((await (await expect('/api/community/me',{id:owner})).json()).canPublish,false);
 pairing=await nativeJSON('/api/device/token',{deviceCode:grant.deviceCode});check(pairing.status,200);const token=await pairing.json();check(token.purpose,'community');communityToken=token.accessToken;
 check((await (await expect('/api/community/me',{id:owner})).json()).clientConfirmed,false);
 pairing=await nativeJSON('/api/device/activate',{},communityToken);check(pairing.status,200);check((await pairing.json()).confirmed,true);
 me=await (await expect('/api/community/me',{id:owner})).json();check(me.canPublish,true);check(me.clientConfirmed,true);
 check((await (await expect('/api/community/me',{id:reporter})).json()).canPublish,false);check((await (await expect('/api/community/me',{id:moderator})).json()).canPublish,false);
 const draft=await create();
 await expect(`/api/community/${draft}/moderate`,{id:moderator},404);await moderate(draft,'hide',0,404);
 await expect(`/api/community/${draft}/media`,{id:moderator},404);
 const id=await create();
 let response=await fetch(`${origin}/api/community/${id}/media`,{method:'PUT',headers:{...identity(owner),Origin:origin,'Content-Type':'video/mp4'},body:video});check(response.status,200);
 response=await fetch(`${origin}/api/community/${id}/poster`,{method:'PUT',headers:{...identity(owner),Origin:origin,'Content-Type':'image/jpeg'},body:new Uint8Array([255,216,255,224,0,0,255,217])});check(response.status,200);
 await expect(`/api/community/${id}/publish`,{id:owner,method:'POST',body:{license:'CC-BY-4.0',confirmRights:true}});
 await expect(`/api/community/${id}/report`,{id:reporter,method:'POST',body:{reason:'privacy',details:'Local synthetic report'}});
 await expect(`/api/community/${id}/moderate`,{id:moderator,method:'POST',body:{action:'hide',reason:'Must fail origin'},headers:{Origin:'https://other.invalid'}},403);
 await expect(`/api/community/${id}/moderate`,{id:owner,method:'POST',body:{action:'delete',reason:'Must fail role'}},403);
 let list=await (await expect(`/api/community/moderation?scope=all&q=${encodeURIComponent(fixture)}`,{id:moderator})).json();check(list.items.length,1);check(list.items[0].id,id);
 check(JSON.stringify(list).includes(owner),false);check(JSON.stringify(list).includes(reporter),false);
 let review=await (await expect(`/api/community/${id}/moderate`,{id:moderator})).json();check(review.reports.length,1);check(JSON.stringify(review).includes(reporter),false);
 check((await moderate(id,'hide',0)).item.moderationHold,true);
 await expect(`/api/community/${id}`,{},404);await expect(`/api/community/${id}/media`,{},404);await expect(`/api/community/${id}/poster`,{},404);
 await expect(`/api/community/${id}/publish`,{id:owner,method:'POST',body:{license:'CC-BY-4.0',confirmRights:true}},409);
 await moderate(id,'delete',0,409);
 const trashed=(await moderate(id,'delete',1)).item;check(!!trashed.deletedAt,true);check(trashed.hasMedia,true);check(trashed.moderationHold,true);
 await expect(`/api/community/${id}`,{id:owner},404);await expect(`/api/community/${id}/media`,{id:owner},404);
 await expect(`/api/community/${id}/media`,{id:moderator,headers:{Range:'bytes=0-31'}},206);await expect(`/api/community/${id}/poster`,{id:moderator});
 list=await (await expect(`/api/community/moderation?scope=deleted&q=${encodeURIComponent(fixture)}`,{id:moderator})).json();check(list.items.length,1);
 const restored=(await moderate(id,'restore',2)).item;check(restored.deletedAt,null);check(restored.moderationHold,true);check(restored.status,'published');
 await expect(`/api/community/${id}/media`,{},404);
 check((await moderate(id,'reinstate',3)).item.moderationHold,false);await expect(`/api/community/${id}/media`,{headers:{Range:'bytes=0-31'}},206);
 await expect(`/api/community/${id}/unpublish`,{id:owner,method:'POST',body:{}});
 await moderate(id,'delete',4);const privateRestore=(await moderate(id,'restore',5)).item;check(privateRestore.status,'draft');check(privateRestore.moderationHold,false);
 await expect(`/api/community/${id}/media`,{},404);
 review=await (await expect(`/api/community/${id}/moderate`,{id:moderator})).json();check(review.audit.length,6);check(review.audit.every(event=>event.actorId===moderator),true);
 await moderate(id,'delete',6);await expect(`/api/community/${id}`,{id:owner,method:'DELETE'});ids.delete(id);await moderate(id,'restore',7,404);
 pairing=await nativeJSON('/api/device/revoke',{},communityToken);check(pairing.status,200);communityToken=undefined;check((await (await expect('/api/community/me',{id:owner})).json()).canPublish,true);
 console.log(`Local moderation HTTP checks passed (${checks}). Client confirmation, unconfirmed reporter/moderator access, private drafts, role/origin guards, literal search, reports, R2 range/preview access, stale revisions, trash/restore, preserved author status and author deletion verified.`);
}finally{
 if(communityToken)await nativeJSON('/api/device/revoke',{},communityToken);
 for(const id of ids)await expect(`/api/community/${id}`,{id:owner,method:'DELETE'});
 console.log('Synthetic local uploads cleaned up. Existing work was not modified.');
}
