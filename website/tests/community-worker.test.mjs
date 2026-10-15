import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile,readdir} from 'node:fs/promises';
import {Miniflare} from 'miniflare';
import ts from 'typescript';

// Exercise actual Workers FixedLengthStream, D1 and R2 implementations, without
// credentials, paid services, seeded production users or deployed storage.
test('community workerd upload, range access, transactional moderation trash/restore and author cleanup',async()=>{
 const main=`import {getCommunityProfile,saveCommunityProfile} from './community-profile.mjs';import {createCommunityPost,publishCommunityPost,unpublishCommunityPost,moderateCommunityPost,communityModerationDetail,moderationPost} from './community.mjs';import {uploadCommunityVideo,communityMediaResponse,communityMediaResponseForPost,deleteCommunityPost} from './community-media.mjs';
 export default {async fetch(request,env){try{const url=new URL(request.url),id=url.searchParams.get('id'),owner={id:'worker-fixture'};
 if(url.pathname==='/profile')return Response.json(request.method==='GET'?await getCommunityProfile(env.DB,owner.id):await saveCommunityProfile(env.DB,owner.id,await request.json()));
 if(url.pathname==='/draft'){const post=await createCommunityPost(env.DB,owner,await request.json());return Response.json(post)}
 if(url.pathname==='/upload')return Response.json(await uploadCommunityVideo(env.DB,env.BUCKET,id,owner,request));
 if(url.pathname==='/publish')return Response.json(await publishCommunityPost(env.DB,id,owner,{license:'CC-BY-4.0',confirmRights:true}));
 if(url.pathname==='/moderate')return Response.json(await moderateCommunityPost(env.DB,id,{id:'worker-moderator',name:'Worker reviewer'},await request.json()));
 if(url.pathname==='/review')return Response.json(await communityModerationDetail(env.DB,id));
 if(url.pathname==='/review-media')return await communityMediaResponseForPost(env.BUCKET,await moderationPost(env.DB,id),request);
 if(url.pathname==='/unpublish')return Response.json(await unpublishCommunityPost(env.DB,id,owner));
 if(url.pathname==='/media')return await communityMediaResponse(env.DB,env.BUCKET,id,undefined,request);
 if(url.pathname==='/delete'){await deleteCommunityPost(env.DB,env.BUCKET,id,owner);return Response.json({deleted:true})}
 return new Response('Not found',{status:404});}catch(error){return Response.json({code:error.code??'worker_error',message:error.message},{status:error.status??500})}}};`;
 const modules=[{type:'ESModule',path:'worker.mjs',contents:main}];
 for(const name of ['primitives','community-profile','community','community-media']){
  const source=await readFile(new URL(`../lib/server/${name}.ts`,import.meta.url),'utf8');
  let contents=ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.ES2022}}).outputText;
  for(const dependency of ['primitives','community-profile','community'])contents=contents.replaceAll(`'./${dependency}'`,`'./${dependency}.mjs'`);
  modules.push({type:'ESModule',path:`${name}.mjs`,contents});
 }
 const mf=new Miniflare({modules,compatibilityDate:'2026-05-15',d1Databases:['DB'],r2Buckets:['BUCKET']});
 try {
  const db=await mf.getD1Database('DB'),bucket=await mf.getR2Bucket('BUCKET');
  const sqlDir=new URL('../drizzle/',import.meta.url);
  for(const name of (await readdir(sqlDir)).filter(name=>name.endsWith('.sql')).sort()){
   const sql=await readFile(new URL(name,sqlDir),'utf8');for(const statement of sql.split('--> statement-breakpoint').map(s=>s.trim()).filter(Boolean))await db.prepare(statement).run();
  }
  const bytes=new Uint8Array(128*1024);new DataView(bytes.buffer).setUint32(0,24);bytes.set(new TextEncoder().encode('ftypisom'),4);bytes.fill(80,24);
  const metadata={title:'Worker upload fixture',authorName:'Test maker',category:'demo',filename:'stream.mp4',mimeType:'video/mp4',sizeBytes:bytes.length};
  let response=await mf.dispatchFetch('https://fixture.test/draft',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(metadata)});assert.equal(response.status,200);const post=await response.json();
  response=await mf.dispatchFetch('https://fixture.test/profile',{method:'PATCH',headers:{'Content-Type':'application/json'},body:JSON.stringify({displayName:'Worker creator'})});assert.equal(response.status,200);assert.equal((await response.json()).displayName,'Worker creator');assert.equal((await db.prepare('SELECT author_name FROM community_posts WHERE id=?').bind(post.id).first()).author_name,'Worker creator');
  response=await mf.dispatchFetch(`https://fixture.test/upload?id=${post.id}`,{method:'PUT',headers:{'Content-Type':'video/mp4'},body:bytes});const upload=await response.json();assert.equal(response.status,200,JSON.stringify(upload));assert.equal(upload.media_state,'ready');assert.equal((await bucket.head(upload.object_key)).size,bytes.length);
  assert.equal((await mf.dispatchFetch(`https://fixture.test/media?id=${post.id}`)).status,404);
  assert.equal((await mf.dispatchFetch(`https://fixture.test/publish?id=${post.id}`,{method:'POST'})).status,200);
  response=await mf.dispatchFetch(`https://fixture.test/media?id=${post.id}`,{headers:{Range:'bytes=100-199'}});assert.equal(response.status,206);assert.equal(response.headers.get('Content-Range'),`bytes 100-199/${bytes.length}`);assert.deepEqual(new Uint8Array(await response.arrayBuffer()),bytes.slice(100,200));
  response=await mf.dispatchFetch(`https://fixture.test/media?id=${post.id}`,{method:'HEAD'});assert.equal(response.headers.get('Content-Length'),String(bytes.length));assert.equal((await response.arrayBuffer()).byteLength,0);
  const moderate=async(action,expectedRevision)=>{const result=await mf.dispatchFetch(`https://fixture.test/moderate?id=${post.id}`,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action,reason:`Worker ${action} review`,expectedRevision})});return {status:result.status,body:await result.json()};};
  assert.equal((await moderate('hide',0)).status,200);assert.equal((await moderate('delete',0)).status,409);
  assert.equal((await mf.dispatchFetch(`https://fixture.test/unpublish?id=${post.id}`,{method:'POST'})).status,200);
  const deleted=await moderate('delete',1);assert.equal(deleted.status,200);assert.equal(deleted.body.status,'draft');assert.ok(deleted.body.deleted_at);assert.ok(await bucket.head(upload.object_key));
  assert.equal((await mf.dispatchFetch(`https://fixture.test/media?id=${post.id}`)).status,404);assert.equal((await mf.dispatchFetch(`https://fixture.test/review-media?id=${post.id}`,{method:'HEAD'})).status,200);
  const restored=await moderate('restore',2);assert.equal(restored.status,200);assert.equal(restored.body.moderation_hold,1);assert.equal(restored.body.status,'draft');assert.equal(restored.body.deleted_at,null);
  assert.equal((await mf.dispatchFetch(`https://fixture.test/publish?id=${post.id}`,{method:'POST'})).status,409);
  assert.equal((await moderate('reinstate',3)).status,200);assert.equal((await mf.dispatchFetch(`https://fixture.test/media?id=${post.id}`)).status,404);
  assert.equal((await mf.dispatchFetch(`https://fixture.test/publish?id=${post.id}`,{method:'POST'})).status,200);
  const history=await (await mf.dispatchFetch(`https://fixture.test/review?id=${post.id}`)).json();assert.deepEqual(history.audit.map(x=>x.action),['reinstate','restore','delete','hide']);assert.ok(history.audit.every(x=>x.actorId==='worker-moderator'));assert.equal((await db.prepare('SELECT COUNT(*) n FROM community_moderation_audit').first()).n,4);
  assert.equal((await mf.dispatchFetch(`https://fixture.test/delete?id=${post.id}`,{method:'DELETE'})).status,200);assert.equal(await bucket.head(upload.object_key),null);
  response=await mf.dispatchFetch('https://fixture.test/draft',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(metadata)});const invalid=await response.json();
  response=await mf.dispatchFetch(`https://fixture.test/upload?id=${invalid.id}`,{method:'PUT',headers:{'Content-Type':'video/mp4'},body:new Uint8Array(bytes.length)});assert.equal(response.status,415);assert.equal((await bucket.list()).objects.length,0);
 }finally{await mf.dispose();}
});
