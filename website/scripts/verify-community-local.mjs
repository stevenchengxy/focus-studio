import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
// Built Worker preview only: use fresh synthetic Sites identities so permanent
// confirmation from a previous run cannot hide a missing eligibility check.
const origin=process.env.COMMUNITY_TEST_ORIGIN||'http://127.0.0.1:5180';
if(!['127.0.0.1','localhost'].includes(new URL(origin).hostname))throw Error('This test only runs against a local development server.');
const movie=await readFile(new URL('../public/media/focus-studio-demo-flat.mp4',import.meta.url));
const poster=await readFile(new URL('../public/media/focus-studio-demo-flat.jpg',import.meta.url));
const fixture=crypto.randomUUID(),owner=`focus-local-owner-${fixture}`;
const auth={Origin:origin,'oai-authenticated-user-id':owner,'oai-authenticated-user-email':`${owner}@example.invalid`,'oai-authenticated-user-full-name':'Local%20community%20fixture','oai-authenticated-user-full-name-encoding':'percent-encoded-utf-8'};
const jsonHeaders={...auth,'Content-Type':'application/json'};
let id,communityToken;let checks=0;
const check=(value,expected)=>{assert.equal(value,expected);checks++;};
const call=async(path,init={})=>{
 try{
  const response=await fetch(origin+path,{...init,signal:AbortSignal.timeout(30000)});
  // Consume the network body even when a check only uses the status. The clone
  // keeps it available for later JSON/binary assertions without leaking sockets.
  await response.clone().arrayBuffer();
  return response;
 }catch(error){throw new Error(`${init.method||'GET'} ${path} failed`,{cause:error})}
};
const nativeJSON=(path,body={},token)=>call(path,{method:'POST',headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},body:JSON.stringify(body)});
const me=async()=>{const response=await call('/api/community/me',{headers:auth});check(response.status,200);const data=await response.json();check(data.viewerId,owner);return data};
try{
 check((await call('/api/community/me')).status,200);
 let response=await call('/api/community',{method:'POST',headers:{Origin:origin,'Content-Type':'application/json'},body:'{}'});check(response.status,401);
 response=await call('/api/community',{method:'POST',headers:{...jsonHeaders,Origin:'https://other.invalid'},body:'{}'});check(response.status,403);
 const metadata={title:`Local community lifecycle ${fixture}`,description:'Test-only synthetic showcase. Not a production publication.',category:'demo',authorName:'Focus Studio test',productUrl:'https://focus-studio.stevenchengxy19.chatgpt.site/',filename:'fixture.mp4',mimeType:'video/mp4',sizeBytes:movie.length};
 check((await me()).canPublish,false);check((await me()).clientConfirmed,false);
 response=await call('/api/community',{method:'POST',headers:jsonHeaders,body:JSON.stringify({...metadata,clientConfirmed:true})});check(response.status,403);check((await response.json()).error.code,'community_client_required');
 const fakeID='00000000-0000-4000-8000-000000000000';
 for(const [path,method,body,contentType] of [
  [`/api/community/${fakeID}`,'PATCH',JSON.stringify({title:'Blocked'}),'application/json'],
  [`/api/community/${fakeID}/publish`,'POST','{}','application/json'],
  [`/api/community/${fakeID}/media`,'PUT',movie,'video/mp4'],
  [`/api/community/${fakeID}/poster`,'PUT',poster,'image/jpeg'],
  [`/api/community/${fakeID}/poster`,'POST',poster,'image/jpeg'],
 ]){response=await call(path,{method,headers:{...auth,'Content-Type':contentType},body});const result=await response.text();assert.equal(response.status,403,`${method} ${path}: ${result.slice(0,180)}`);checks++;check(JSON.parse(result).error.code,'community_client_required')}
 response=await nativeJSON('/api/device/start',{purpose:'community'});check(response.status,200);const grant=await response.json();check(grant.purpose,'community');check(new URL(grant.verificationUriComplete).searchParams.get('purpose'),'community');
 response=await nativeJSON('/api/device/token',{deviceCode:grant.deviceCode});check(response.status,202);
 response=await call('/api/device/approve',{method:'POST',headers:jsonHeaders,body:JSON.stringify({userCode:grant.userCode,name:'Synthetic local community client'})});check(response.status,200);check((await me()).canPublish,false);
 response=await nativeJSON('/api/device/token',{deviceCode:grant.deviceCode});check(response.status,200);const token=await response.json();check(token.purpose,'community');communityToken=token.accessToken;check((await me()).clientConfirmed,false);
 response=await nativeJSON('/api/device/activate',{},communityToken);check(response.status,200);check((await response.json()).confirmed,true);
 check((await me()).canPublish,true);check((await me()).clientConfirmed,true);
 response=await call('/api/community',{method:'POST',headers:jsonHeaders,body:JSON.stringify(metadata)});check(response.status,201);const data=await response.json();id=data.item.id;check(data.item.status,'draft');
 check((await call(`/api/community/${id}`)).status,404);
 response=await call(data.uploadUrl,{method:'PUT',headers:{...auth,'Content-Type':'video/mp4'},body:movie});check(response.status,200);
 response=await call(`/api/community/${id}/poster`,{method:'PUT',headers:{...auth,'Content-Type':'image/jpeg'},body:poster});check(response.status,200);
 check((await call(`/api/community/${id}/media`)).status,404);check((await call(`/api/community/${id}/poster`)).status,404);
 response=await call(`/api/community/${id}/publish`,{method:'POST',headers:jsonHeaders,body:JSON.stringify({license:'CC-BY-4.0',confirmRights:false})});check(response.status,400);
 response=await call(`/api/community/${id}/publish`,{method:'POST',headers:jsonHeaders,body:JSON.stringify({license:'CC-BY-4.0',confirmRights:true})});check(response.status,200);
 response=await call(`/api/community?q=${encodeURIComponent(fixture)}`);const results=await response.json();check(results.items.some(item=>item.id===id),true);check(JSON.stringify(results).includes('@example.invalid'),false);
 response=await call(`/api/community/${id}/media`,{headers:{Range:'bytes=0-31'}});check(response.status,206);assert.deepEqual(Buffer.from(await response.arrayBuffer()),movie.subarray(0,32));checks++;
 response=await call(`/api/community/${id}/media?download=1`,{method:'HEAD'});check(response.status,200);check(response.headers.get('Content-Type'),'video/mp4');assert.match(response.headers.get('Content-Disposition'),/^attachment/);checks++;
 response=await call(`/api/community/${id}`,{method:'PATCH',headers:jsonHeaders,body:JSON.stringify({title:'Updated fixture'})});check(response.status,200);check((await response.json()).item.title,'Updated fixture');
 response=await call(`/api/community/${id}/unpublish`,{method:'POST',headers:jsonHeaders,body:'{}'});check(response.status,200);check((await call(`/api/community/${id}/media`)).status,404);check((await call(`/api/community/${id}/poster`)).status,404);
 response=await call(`/api/community/${id}`,{method:'DELETE',headers:auth});check(response.status,200);check((await call(`/api/community/${id}`,{headers:auth})).status,404);id=null;
 response=await call('/api/billing/checkout',{method:'POST',headers:jsonHeaders,body:JSON.stringify({plan:'monthly'})});check(response.status,409);check((await response.json()).error.code,'billing_paused');
 response=await nativeJSON('/api/device/revoke',{},communityToken);check(response.status,200);communityToken=undefined;check((await me()).canPublish,true);
 console.log(`Community local HTTP integration passed (${checks} checks). Unconfirmed denials, complete client pairing/callback, permanent confirmation, private drafts, upload, publish, search, previews, ranges, edits, unpublish, delete, and paused billing verified.`);
}finally{if(id)await call(`/api/community/${id}`,{method:'DELETE',headers:auth});if(communityToken)await nativeJSON('/api/device/revoke',{},communityToken);}
