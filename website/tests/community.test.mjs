import test from 'node:test';
import assert from 'node:assert/strict';
import {DatabaseSync} from 'node:sqlite';
import {mkdtemp,readFile,readdir,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {pathToFileURL} from 'node:url';
import ts from 'typescript';
const temp=await mkdtemp(join(tmpdir(),'focus-community-'));
for(const name of ['primitives','community-profile','community','community-media','community-runtime','community-routes']) {
 const source=await readFile(new URL(`../lib/server/${name}.ts`,import.meta.url),'utf8');
 let js=ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.ES2022}}).outputText;
 for(const dependency of ['primitives','community-profile','community','community-media','community-runtime','runtime'])js=js.replaceAll(`'./${dependency}'`,`'./${dependency}.mjs'`);
 js=js.replaceAll("'cloudflare:workers'","'./fixtures.mjs'").replaceAll("'@/app/chatgpt-auth'","'./fixtures.mjs'");
 await writeFile(join(temp,`${name}.mjs`),js);
}
await writeFile(join(temp,'fixtures.mjs'),`export const env={get BUCKET(){return globalThis.__communityFixture.bucket},get COMMUNITY_MODERATOR_IDS(){return globalThis.__communityFixture.moderatorIDs}};export async function getChatGPTUser(){return globalThis.__communityFixture.user;}`);
await writeFile(join(temp,'runtime.mjs'),`import {APIError,checkOrigin} from './primitives.mjs';export const database=()=>globalThis.__communityFixture.db;export const mutationGuard=(request,allowNative)=>checkOrigin(request,'https://studio.test',allowNative);export async function rateLimit(key,limit){const map=globalThis.__communityFixture.rates;const count=(map.get(key)||0)+1;map.set(key,count);if(count>limit)throw new APIError(429,'too_many_requests','Too many requests.');}export async function api(work){try{return await work()}catch(error){return Response.json({error:{code:error.code||'service_error'}},{status:error.status||503})}}`);
const core=await import(pathToFileURL(join(temp,'community.mjs')));
const profiles=await import(pathToFileURL(join(temp,'community-profile.mjs')));
const media=await import(pathToFileURL(join(temp,'community-media.mjs')));
const routes=await import(pathToFileURL(join(temp,'community-routes.mjs')));
const sqlDir=new URL('../drizzle/',import.meta.url);
const sql=(await Promise.all((await readdir(sqlDir)).filter(n=>n.endsWith('.sql')).sort().map(n=>readFile(new URL(n,sqlDir),'utf8')))).join('\n');
function database(){const raw=new DatabaseSync(':memory:');raw.exec('PRAGMA foreign_keys=ON');raw.exec(sql);function prepare(sql,args=[]){const run=()=>({meta:{changes:Number(raw.prepare(sql).run(...args).changes)}});return{bind(...values){return prepare(sql,values)},async first(){return raw.prepare(sql).get(...args)??null},async all(){return{results:raw.prepare(sql).all(...args)}},async run(){return run()},_run:run}}return{raw,prepare,async batch(statements){raw.exec('BEGIN IMMEDIATE');try{const results=statements.map(statement=>statement._run());raw.exec('COMMIT');return results}catch(error){raw.exec('ROLLBACK');throw error}}}}
class Bucket {
 objects=new Map();beforeStore=null;failDelete=false;
 async put(key,input){const bytes=new Uint8Array(await new Response(input).arrayBuffer());if(this.beforeStore)await this.beforeStore(key);this.objects.set(key,bytes);return{size:bytes.length,httpEtag:'"fixture-etag"'}}
 async head(key){const bytes=this.objects.get(key);return bytes?{size:bytes.length,httpEtag:'"fixture-etag"'}:null}
 async get(key,options){const bytes=this.objects.get(key);if(!bytes)return null;const range=options?.range;return{body:new Response(range?bytes.slice(range.offset,range.offset+range.length):bytes).body}}
 async delete(keys){if(this.failDelete)throw Error('fixture storage failure');for(const key of Array.isArray(keys)?keys:[keys])this.objects.delete(key)}
}
const owner={id:'trusted-sites-owner',name:'Aster Maker'},other={id:'different-sites-user'};
const metadata={title:'A product tour',description:'A focused product demo',caption:'One step at a time.',productUrl:'https://product.example/demo',category:'demo',authorName:'Aster Maker',filename:'product-tour.mp4',mimeType:'video/mp4',sizeBytes:64};
function bytes(size=64){const data=new Uint8Array(size);new DataView(data.buffer).setUint32(0,24);data.set(new TextEncoder().encode('ftypisom'),4);return data}
const jpg=new Uint8Array([255,216,255,224,0,0,255,217]);
const bad=code=>error=>error.code===code;
const fixed=()=>new TransformStream();
function uploadRequest(data=bytes(),mime='video/mp4'){return new Request('https://studio.test/api/community/id/media',{method:'PUT',headers:{'Content-Type':mime,Origin:'https://studio.test'},body:data})}
async function create(db,changes={},viewer=owner){return core.createCommunityPost(db,viewer,{...metadata,...changes},100)}
async function ready(db,bucket,changes={}){const post=await create(db,changes);return media.uploadCommunityVideo(db,bucket,post.id,owner,uploadRequest(bytes(post.size_bytes),post.mime_type),fixed,101)}
async function published(db,bucket,changes={}){const post=await ready(db,bucket,changes);return core.publishCommunityPost(db,post.id,owner,{license:'CC-BY-4.0',confirmRights:true},102)}
function fixture(user={userId:owner.id,email:'private@example.invalid',fullName:owner.name,displayName:owner.name}){const state={db:database(),bucket:new Bucket(),user,rates:new Map()};globalThis.__communityFixture=state;return state}
function jsonRequest(data={},method='POST',origin='https://studio.test'){return new Request('https://studio.test/api/community',{method,headers:{Origin:origin,'Content-Type':'application/json'},body:JSON.stringify(data)})}

test('drafts remain private and owner fields cannot be supplied through metadata',async()=>{
 const db=database();const post=await create(db);assert.equal(post.status,'draft');assert.equal((await core.listCommunityPosts(db,new URL('https://studio.test/api/community'))).items.length,0);
 for(const viewer of [undefined,other.id])await assert.rejects(core.getCommunityPost(db,post.id,viewer),bad('community_not_found'));
 assert.equal((await core.getCommunityPost(db,post.id,owner.id)).title,metadata.title);
 await assert.rejects(core.editCommunityPost(db,post.id,other,{title:'Stolen'}),bad('community_not_found'));
 await assert.rejects(core.editCommunityPost(db,post.id,owner,{ownerId:other.id,status:'published'}),bad('community_invalid_metadata'));
 await assert.rejects(core.listCommunityPosts(db,new URL('https://studio.test/api/community/mine'),null,true),bad('community_sign_in_required'));
});
test('quotas reserve atomically across tabs, include drafts, and do not share user capacity',async()=>{
 const db=database();const results=await Promise.allSettled(Array.from({length:25},()=>create(db)));
 assert.equal(results.filter(v=>v.status==='fulfilled').length,20);assert.ok(results.filter(v=>v.status==='rejected').every(v=>v.reason.code==='community_quota_exceeded'));
 await create(db,{},other);const db2=database();for(let i=0;i<5;i++)await create(db2,{sizeBytes:core.COMMUNITY_MAX_BYTES});await assert.rejects(create(db2),bad('community_quota_exceeded'));
});
test('metadata rejects email names, unsafe URLs, filenames, formats and oversized declarations',async()=>{
 const db=database();for(const [change,code] of [[{authorName:'private@example.invalid'},'community_public_name_required'],[{productUrl:'javascript:alert(1)'},'community_invalid_url'],[{productUrl:'https://name:secret@example.com'},'community_invalid_url'],[{filename:'../clip.mp4'},'community_invalid_filename'],[{mimeType:'text/html'},'community_video_required'],[{sizeBytes:core.COMMUNITY_MAX_BYTES+1},'community_file_too_large'],[{title:'\u0000oops'},'community_invalid_metadata']])await assert.rejects(create(db,change),bad(code));
});
test('validated upload requires explicit reusable-license publication and public DTO never leaks identity',async()=>{
 const db=database(),bucket=new Bucket(),post=await create(db);
 await assert.rejects(core.publishCommunityPost(db,post.id,owner,{license:'CC-BY-4.0',confirmRights:true}),bad('community_upload_required'));
 const uploaded=await media.uploadCommunityVideo(db,bucket,post.id,owner,uploadRequest(),fixed,101);assert.equal(uploaded.media_state,'ready');assert.equal(bucket.objects.size,1);
 await assert.rejects(core.publishCommunityPost(db,post.id,owner,{}),bad('community_license_required'));
 const live=await core.publishCommunityPost(db,post.id,owner,{license:'CC-BY-4.0',confirmRights:true},102),dto=core.communityItem(live);
 assert.equal(dto.status,'published');assert.equal(dto.license,'CC-BY-4.0');assert.equal(dto.hasMedia,true);assert.equal(dto.isOwner,false);assert.equal(dto.uploadState,undefined);
 assert.ok(!JSON.stringify(dto).includes(owner.id));assert.ok(!JSON.stringify(dto).includes('object_key'));assert.match(dto.attribution,/Aster Maker/);
 await core.unpublishCommunityPost(db,post.id,owner,103);await assert.rejects(core.getCommunityPost(db,post.id),bad('community_not_found'));assert.equal((await core.getCommunityPost(db,post.id,owner.id)).license,'CC-BY-4.0');
});
test('upload detects forged MIME signatures, underflow and overflow without publishing partial R2 objects',async()=>{
 for(const [data,code] of [[new Uint8Array(64),'community_invalid_video'],[bytes(63),'community_size_mismatch'],[bytes(65),'community_size_mismatch']]){
  const db=database(),bucket=new Bucket(),post=await create(db);await assert.rejects(media.uploadCommunityVideo(db,bucket,post.id,owner,uploadRequest(data),fixed),bad(code));assert.equal(bucket.objects.size,0);assert.equal((await core.getCommunityPost(db,post.id,owner.id)).media_state,'failed');
 }
 const db=database(),bucket=new Bucket(),post=await create(db,{filename:'clip.webm',mimeType:'video/webm'});const webm=new Uint8Array(64);webm.set([0x1a,0x45,0xdf,0xa3]);webm.set(new TextEncoder().encode('webm'),8);assert.equal((await media.uploadCommunityVideo(db,bucket,post.id,owner,uploadRequest(webm,'video/webm'),fixed)).media_state,'ready');
});
test('concurrent upload and delete cannot leave a public or orphan media object',async()=>{
 const db=database(),bucket=new Bucket(),post=await create(db);let release,started;const waiting=new Promise(r=>started=r);bucket.beforeStore=()=>{started();return new Promise(r=>release=r)};
 const uploading=media.uploadCommunityVideo(db,bucket,post.id,owner,uploadRequest(),fixed,101);await waiting;await assert.rejects(media.uploadCommunityVideo(db,bucket,post.id,owner,uploadRequest(),fixed,102),bad('community_upload_in_progress'));
 await media.deleteCommunityPost(db,bucket,post.id,owner,103);release();await assert.rejects(uploading,bad('community_upload_cancelled'));assert.equal(bucket.objects.size,0);assert.equal(db.raw.prepare('SELECT count(*) n FROM community_posts').get().n,0);
});
test('upload abort leaves a retryable failed draft and no stored object',async()=>{
 const db=database(),bucket=new Bucket(),post=await create(db);const cancel=new AbortController();cancel.abort();const request=new Request('https://studio.test',{method:'PUT',headers:{'Content-Type':'video/mp4'},body:bytes(),signal:cancel.signal});
 await assert.rejects(media.uploadCommunityVideo(db,bucket,post.id,owner,request,fixed));assert.equal(bucket.objects.size,0);assert.equal((await core.getCommunityPost(db,post.id,owner.id)).media_state,'failed');
});
test('JPEG thumbnails are optional, private and independent of valid uploaded videos',async()=>{
 const db=database(),bucket=new Bucket(),post=await ready(db,bucket);await assert.rejects(media.uploadCommunityPoster(db,bucket,post.id,owner,uploadRequest(bytes(),'image/jpeg')),bad('community_jpeg_required'));assert.equal((await core.getCommunityPost(db,post.id,owner.id)).media_state,'ready');assert.equal(bucket.objects.size,1);
 const withPoster=await media.uploadCommunityPoster(db,bucket,post.id,owner,uploadRequest(jpg,'image/jpeg'));assert.match(core.communityItem(withPoster,owner.id).posterUrl,/\/poster$/);assert.equal(bucket.objects.size,2);
 await assert.rejects(media.communityMediaResponse(db,bucket,post.id,undefined,new Request('https://studio.test'),true),bad('community_not_found'));
 const response=await media.communityMediaResponse(db,bucket,post.id,owner.id,new Request('https://studio.test'),true);assert.equal(response.headers.get('Content-Type'),'image/jpeg');assert.deepEqual(new Uint8Array(await response.arrayBuffer()),jpg);
 await assert.rejects(media.uploadCommunityPoster(db,bucket,post.id,owner,uploadRequest(new Uint8Array(512*1024+1),'image/jpeg')),bad('community_poster_too_large'));
});
test('thumbnail replacement cleans up the predecessor captured when its lock is acquired',async()=>{
 const db=database(),bucket=new Bucket(),post=await ready(db,bucket);
 await media.uploadCommunityPoster(db,bucket,post.id,owner,uploadRequest(jpg,'image/jpeg'),101);
 const basePrepare=db.prepare;let intervened=false;
 function prepare(sql,args=[]){const inner=basePrepare(sql).bind(...args);return{
  bind(...values){return prepare(sql,values)},
  async first(){const row=await inner.first();if(!intervened&&sql.startsWith('SELECT * FROM community_posts WHERE id=')){
   intervened=true;await media.uploadCommunityPoster(db,bucket,post.id,owner,uploadRequest(jpg,'image/jpeg'),102);
  }return row},all:()=>inner.all(),run:()=>inner.run()
 }}
 const result=await media.uploadCommunityPoster({...db,prepare},bucket,post.id,owner,uploadRequest(jpg,'image/jpeg'),103);
 assert.equal(bucket.objects.size,2);assert.ok(bucket.objects.has(result.object_key));assert.ok(bucket.objects.has(result.poster_key));
});
test('media serves safe partial/HEAD/download responses and gates unpublished clips',async()=>{
 const db=database(),bucket=new Bucket(),post=await published(db,bucket);const partial=await media.communityMediaResponse(db,bucket,post.id,undefined,new Request('https://studio.test/media?download=1',{headers:{Range:'bytes=8-15'}}));
 assert.equal(partial.status,206);assert.equal(partial.headers.get('Content-Range'),'bytes 8-15/64');assert.match(partial.headers.get('Content-Disposition'),/^attachment/);assert.equal((await partial.arrayBuffer()).byteLength,8);
 const head=await media.communityMediaResponse(db,bucket,post.id,undefined,new Request('https://studio.test',{method:'HEAD',headers:{Range:'bytes=-10'}}));assert.equal(head.status,206);assert.equal(head.headers.get('Content-Length'),'10');assert.equal((await head.arrayBuffer()).byteLength,0);
 const noMatch=await media.communityMediaResponse(db,bucket,post.id,undefined,new Request('https://studio.test',{headers:{Range:'bytes=8-15','If-Range':'"different"'}}));assert.equal(noMatch.status,200);assert.equal((await noMatch.arrayBuffer()).byteLength,64);
 for(const range of ['bytes=99-','bytes=0-1,8-9','bytes=-0',`bytes=-${'9'.repeat(500)}`]){const response=await media.communityMediaResponse(db,bucket,post.id,undefined,new Request('https://studio.test',{headers:{Range:range}}));assert.equal(response.status,416);assert.equal(response.headers.get('Content-Range'),'bytes */64')}
 await core.unpublishCommunityPost(db,post.id,owner);await assert.rejects(media.communityMediaResponse(db,bucket,post.id,undefined,new Request('https://studio.test')),bad('community_not_found'));
});
test('report persists privately once per user; deletion clears video, poster and reports',async()=>{
 const db=database(),bucket=new Bucket(),post=await ready(db,bucket);await media.uploadCommunityPoster(db,bucket,post.id,owner,uploadRequest(jpg,'image/jpeg'));await core.publishCommunityPost(db,post.id,owner,{license:'CC-BY-4.0',confirmRights:true});
 await core.reportCommunityPost(db,post.id,other,{reason:'privacy',details:'Please review'});await core.reportCommunityPost(db,post.id,other,{reason:'copyright'});assert.equal(db.raw.prepare('SELECT count(*) n FROM community_reports').get().n,1);await assert.rejects(core.reportCommunityPost(db,post.id,owner,{reason:'other'}),bad('community_own_report'));
 await media.deleteCommunityPost(db,bucket,post.id,other);assert.equal(bucket.objects.size,2);bucket.failDelete=true;await assert.rejects(media.deleteCommunityPost(db,bucket,post.id,owner));await assert.rejects(core.getCommunityPost(db,post.id,owner.id),bad('community_not_found'));assert.equal(bucket.objects.size,2);
 bucket.failDelete=false;await media.deleteCommunityPost(db,bucket,post.id,owner);await media.deleteCommunityPost(db,bucket,post.id,owner);assert.equal(bucket.objects.size,0);assert.equal(db.raw.prepare('SELECT count(*) n FROM community_reports').get().n,0);
});
test('public pagination filters categories and never crosses private drafts',async()=>{
 const db=database(),bucket=new Bucket();for(let i=0;i<4;i++)await published(db,bucket,{title:`Demo ${i}`});await published(db,bucket,{category:'ai-video'});await create(db);
 const first=await core.listCommunityPosts(db,new URL('https://studio.test/api/community?category=demo&limit=2'));const second=await core.listCommunityPosts(db,new URL(`https://studio.test/api/community?category=demo&limit=2&cursor=${first.nextCursor}`));assert.equal(first.items.length,2);assert.equal(second.items.length,2);assert.equal(new Set([...first.items,...second.items].map(x=>x.id)).size,4);assert.equal(second.nextCursor,null);
 const mine=await core.listCommunityPosts(db,new URL('https://studio.test/api/community/mine'),owner,true);assert.equal(mine.items.length,6);assert.ok(mine.items.every(item=>item.isOwner));
});
test('search matches public metadata, bounds input and treats LIKE metacharacters literally',async()=>{
 const db=database(),bucket=new Bucket();await published(db,bucket,{title:'100% clarity',description:'A financial dashboard'});await published(db,bucket,{title:'Other product',authorName:'Another Creator'});await create(db,{title:'Hidden clarity'});
 const search=q=>core.listCommunityPosts(db,new URL(`https://studio.test/api/community?q=${encodeURIComponent(q)}`));
 assert.equal((await search('financial')).items.length,1);assert.equal((await search('Another Creator')).items.length,1);assert.equal((await search('%')).items.length,1);assert.equal((await search('_')).items.length,0);assert.equal((await search("' OR 1=1 --")).items.length,0);assert.equal((await search('Hidden')).items.length,0);
 await assert.rejects(search('a'.repeat(121)),bad('community_invalid_search'));
});
test('HTTP adapters require Sites identity and same-origin writes, never disclose fallback email',async()=>{
 const f=fixture(null);let response=await routes.createCommunity(jsonRequest(metadata));assert.equal(response.status,401);f.user={userId:owner.id,email:'private@example.invalid',fullName:null,displayName:'private@example.invalid'};
 response=await routes.communityMe();const me=await response.json();assert.equal(me.authenticated,true);assert.equal(me.viewerName,undefined);assert.equal(me.maxUploadBytes,core.COMMUNITY_MAX_BYTES);
 response=await routes.createCommunity(jsonRequest(metadata,'POST','https://attacker.test'));assert.equal(response.status,403);const bearer=new Request('https://studio.test/api/community',{method:'POST',headers:{'Content-Type':'application/json',Authorization:`Bearer fs_${'a'.repeat(64)}`},body:JSON.stringify(metadata)});assert.equal((await routes.createCommunity(bearer)).status,403);
 response=await routes.createCommunity(jsonRequest({...metadata,title:'<script>alert(1)</script>'}));assert.equal(response.status,201);const serialized=await response.text();assert.ok(!serialized.includes('<script>'));assert.ok(serialized.includes('\\u003cscript'));
 const {item,uploadUrl}=JSON.parse(serialized);assert.equal(uploadUrl,`/api/community/${item.id}/media`);assert.equal(item.isOwner,true);f.user={userId:other.id,email:'other@example.invalid',fullName:'Other',displayName:'Other'};
 assert.equal((await routes.detailCommunity(new Request('https://studio.test'),item.id)).status,404);assert.equal((await routes.editCommunity(jsonRequest({title:'Replace'},'PATCH'),item.id)).status,404);f.user=null;assert.equal((await routes.listCommunity(new Request('https://studio.test/api/community/mine'),true)).status,401);
});
test('HTTP adapters apply per-author creation rate before reserving more storage',async()=>{
 fixture();for(let i=0;i<10;i++)assert.equal((await routes.createCommunity(jsonRequest(metadata))).status,201);const blocked=await routes.createCommunity(jsonRequest(metadata));assert.equal(blocked.status,429);assert.equal((await blocked.json()).error.code,'too_many_requests');
});
test('persistent profile is private, validates names and overrides old per-work form values',async()=>{
 const f=fixture();assert.deepEqual(await profiles.getCommunityProfile(f.db,owner.id),{displayName:null});
 assert.deepEqual(await (await routes.readCommunityProfile()).json(),{displayName:null});
 let response=await routes.updateCommunityProfile(jsonRequest({displayName:'  星河 Studio  '},'PATCH'));assert.equal(response.status,200);assert.deepEqual(await response.json(),{displayName:'星河 Studio'});
 let me=await (await routes.communityMe()).json();assert.equal(me.displayName,'星河 Studio');assert.equal(me.viewerName,'星河 Studio');assert.equal(me.viewerId,owner.id);assert.ok(!JSON.stringify(me).includes('private@example.invalid'));
 const post=await create(f.db,{authorName:'Stale form name'});assert.equal(post.author_name,'星河 Studio');
 assert.equal((await core.editCommunityPost(f.db,post.id,owner,{title:'Updated title',authorName:'Another alias'})).author_name,'星河 Studio');
 assert.equal((await create(f.db,{authorName:undefined})).author_name,'星河 Studio');
 for(const displayName of ['', '   ', 'a'.repeat(65), 'a\nb', 'a\u0000b'])await assert.rejects(profiles.saveCommunityProfile(f.db,owner.id,{displayName}),bad('community_invalid_profile'));
 for(const displayName of ['person@example.invalid','person@localhost'])await assert.rejects(profiles.saveCommunityProfile(f.db,owner.id,{displayName}),bad('community_public_name_required'));
 await assert.rejects(profiles.saveCommunityProfile(f.db,owner.id,{displayName:'Good',ownerId:other.id}),bad('community_invalid_profile'));
 assert.deepEqual(await profiles.getCommunityProfile(f.db,other.id),{displayName:null});
 f.user=null;assert.equal((await routes.readCommunityProfile()).status,401);assert.equal((await routes.updateCommunityProfile(jsonRequest({displayName:'No identity'},'PATCH'))).status,401);
 assert.equal((await (await routes.communityMe()).json()).displayName,null);
});
test('profile rename atomically synchronizes only owner author names without changing project data or state',async()=>{
 const db=database(),bucket=new Bucket();const publishedPost=await published(db,bucket),draft=await create(db),otherPost=await create(db,{},other);
 await core.moderateCommunityPost(db,publishedPost.id,{id:'moderator'},{action:'hide',reason:'Review'},150);
 const before=db.raw.prepare('SELECT * FROM community_posts ORDER BY id').all();
 await profiles.saveCommunityProfile(db,owner.id,{displayName:'New name'},200);
 const after=db.raw.prepare('SELECT * FROM community_posts ORDER BY id').all();
 assert.deepEqual(after.map(row=>({...row})),before.map(row=>({...row,author_name:row.owner_id===owner.id?'New name':row.author_name})));
 assert.equal((await core.getCommunityPost(db,draft.id,owner.id)).status,'draft');assert.equal((await core.getCommunityPost(db,otherPost.id,other.id)).author_name,metadata.authorName);
 await profiles.saveCommunityProfile(db,owner.id,{displayName:'Final name'},300);const profile=db.raw.prepare('SELECT * FROM community_profiles WHERE owner_id=?').get(owner.id);assert.equal(profile.created_at,200);assert.equal(profile.updated_at,300);assert.equal(profile.display_name,'Final name');
});
test('failed attribution sync rolls back profile change and concurrent create/edit keep canonical name',async()=>{
 const db=database(),post=await create(db);await profiles.saveCommunityProfile(db,owner.id,{displayName:'Original'},100);
 db.raw.exec("CREATE TRIGGER reject_rename BEFORE UPDATE OF author_name ON community_posts BEGIN SELECT RAISE(ABORT,'fixture rejection'); END");
 await assert.rejects(profiles.saveCommunityProfile(db,owner.id,{displayName:'Should roll back'},200));assert.equal((await profiles.getCommunityProfile(db,owner.id)).displayName,'Original');assert.equal((await core.getCommunityPost(db,post.id,owner.id)).author_name,'Original');
 db.raw.exec('DROP TRIGGER reject_rename');
 await Promise.all([create(db,{authorName:'Old form'}),core.editCommunityPost(db,post.id,owner,{authorName:'Old form',description:'Changed content'}),profiles.saveCommunityProfile(db,owner.id,{displayName:'Concurrent final'},300)]);
 assert.ok(db.raw.prepare('SELECT author_name FROM community_posts WHERE owner_id=?').all(owner.id).every(row=>row.author_name==='Concurrent final'));
 assert.equal((await core.getCommunityPost(db,post.id,owner.id)).description,'Changed content');
});
test('profile API rejects cross-origin changes, isolates accounts and rate limits repeated renames',async()=>{
 const f=fixture();assert.equal((await routes.updateCommunityProfile(jsonRequest({displayName:'Bad origin'},'PATCH','https://attacker.test'))).status,403);
 for(let i=0;i<20;i++)assert.equal((await routes.updateCommunityProfile(jsonRequest({displayName:`Creator ${i}`},'PATCH'))).status,200);
 assert.equal((await routes.updateCommunityProfile(jsonRequest({displayName:'Rate limited'},'PATCH'))).status,429);
 f.user={userId:other.id,email:'other@example.invalid',fullName:'Other',displayName:'Other'};assert.deepEqual(await (await routes.readCommunityProfile()).json(),{displayName:null});
 assert.equal((await routes.updateCommunityProfile(jsonRequest({displayName:'Different creator'},'PATCH'))).status,200);assert.equal((await profiles.getCommunityProfile(f.db,owner.id)).displayName,'Creator 19');
 assert.equal((await (await routes.communityMe()).json()).viewerName,'Different creator');
});
test('moderation defaults deny, uses trusted identity, hides all public access and prevents owner republish',async()=>{
 const f=fixture(),post=await published(f.db,f.bucket);await core.reportCommunityPost(f.db,post.id,other,{reason:'privacy',details:'Contains personal information'});
 assert.equal((await routes.reviewCommunity(new Request('https://studio.test'))).status,403);assert.equal((await routes.moderateCommunity(jsonRequest({action:'hide'}),post.id)).status,403);
 f.moderatorIDs='moderator-one';f.user={userId:'moderator-one',email:'private-moderator@example.invalid',fullName:'Moderator',displayName:'Moderator'};
 assert.equal((await (await routes.communityMe()).json()).isModerator,true);
 const reports=await (await routes.reviewCommunity(new Request('https://studio.test'))).json();assert.equal(reports.items.length,1);assert.ok(!JSON.stringify(reports).includes(other.id));assert.ok(!JSON.stringify(reports).includes('private-moderator'));
 let response=await routes.moderateCommunity(jsonRequest({action:'hide',reason:'Privacy review'}),post.id);assert.equal(response.status,200);assert.equal((await response.json()).item.moderationHold,true);
 assert.equal((await core.listCommunityPosts(f.db,new URL('https://studio.test'))).items.length,0);await assert.rejects(core.getCommunityPost(f.db,post.id),bad('community_not_found'));
 await assert.rejects(core.publishCommunityPost(f.db,post.id,owner,{license:'CC-BY-4.0',confirmRights:true}),bad('community_moderation_hold'));
 await assert.rejects(core.editCommunityPost(f.db,post.id,owner,{moderationHold:false}),bad('community_invalid_metadata'));
 f.user=null;assert.equal((await routes.readCommunityMedia(new Request('https://studio.test'),post.id)).status,404);
 f.user={userId:'moderator-one',email:'private-moderator@example.invalid',fullName:'Moderator',displayName:'Moderator'};
 assert.equal((await routes.readCommunityMedia(new Request('https://studio.test'),post.id)).status,200);
 const unrelated=await ready(f.db,f.bucket);assert.equal((await routes.readCommunityMedia(new Request('https://studio.test'),unrelated.id)).status,404);
 await core.unpublishCommunityPost(f.db,post.id,owner);response=await routes.moderateCommunity(jsonRequest({action:'reinstate',reason:'Review complete'}),post.id);assert.equal(response.status,200);assert.equal((await response.json()).item.status,'draft');await assert.rejects(core.getCommunityPost(f.db,post.id),bad('community_not_found'));
 assert.equal((await core.publishCommunityPost(f.db,post.id,owner,{license:'CC-BY-4.0',confirmRights:true})).status,'published');
});
test('moderation lists filter and paginate eligible work while keeping private drafts and identities private',async()=>{
 const db=database(),bucket=new Bucket(),moderator={id:'admin',name:'Reviewer'};
 const publicPost=await published(db,bucket,{title:'Public 100% demo'}),held=await published(db,bucket,{title:'Held demo'}),reported=await published(db,bucket,{title:'Reported AI',category:'ai-video'}),trash=await published(db,bucket,{title:'Trash demo'}),draft=await ready(db,bucket,{title:'Unrelated private draft'});
 await core.moderateCommunityPost(db,held.id,moderator,{action:'hide',reason:'Review privacy'},200);
 await core.reportCommunityPost(db,reported.id,other,{reason:'copyright',details:'Evidence only visible to moderators'},210);await core.unpublishCommunityPost(db,reported.id,owner,220);
 await core.moderateCommunityPost(db,trash.id,moderator,{action:'delete',reason:'Removed from the community'},230);
 const list=(query='')=>core.listCommunityModeration(db,new URL(`https://studio.test/api/community/moderation?${query}`));
 assert.deepEqual(new Set((await list()).items.map(x=>x.id)),new Set([publicPost.id,held.id,reported.id]));
 for(const [scope,id] of [['published',publicPost.id],['held',held.id],['reported',reported.id],['deleted',trash.id]])assert.deepEqual((await list(`scope=${scope}`)).items.map(x=>x.id),[id]);
 assert.deepEqual((await list('category=ai-video')).items.map(x=>x.id),[reported.id]);assert.equal((await list('q=%25')).items.length,1);assert.equal((await list('q=_')).items.length,0);assert.equal((await list('q=private')).items.length,0);
 const first=await list('limit=2'),second=await list(`limit=2&cursor=${first.nextCursor}`);assert.equal(first.items.length,2);assert.equal(second.items.length,1);assert.equal(new Set([...first.items,...second.items].map(x=>x.id)).size,3);assert.equal(second.nextCursor,null);
 const serialized=JSON.stringify(await list('scope=reported'));for(const secret of ['owner_id',owner.id,other.id,'object_key','reporter_id','Evidence only visible'])assert.ok(!serialized.includes(secret));
 const detail=await core.communityModerationDetail(db,reported.id);assert.equal(detail.reports[0].details,'Evidence only visible to moderators');assert.ok(!JSON.stringify(detail).includes(other.id));
 await assert.rejects(core.moderationPost(db,draft.id),bad('community_not_found'));await assert.rejects(core.communityModerationDetail(db,draft.id),bad('community_not_found'));
 for(const query of ['scope=drafts','category=private','limit=51','limit=0','cursor=invalid',`q=${'a'.repeat(121)}`])await assert.rejects(list(query));
});
test('moderator trash preserves media, history and author publication choices through restore',async()=>{
 const f=fixture(),moderator={id:'admin',name:'Trusted reviewer'},post=await ready(f.db,f.bucket);await media.uploadCommunityPoster(f.db,f.bucket,post.id,owner,uploadRequest(jpg,'image/jpeg'));await core.publishCommunityPost(f.db,post.id,owner,{license:'CC-BY-4.0',confirmRights:true});
 await core.reportCommunityPost(f.db,post.id,other,{reason:'privacy'});
 const hidden=await core.moderateCommunityPost(f.db,post.id,moderator,{action:'hide',reason:'Privacy review',expectedRevision:0},200);assert.equal(hidden.moderation_revision,1);
 await core.unpublishCommunityPost(f.db,post.id,owner,201);
 const removed=await core.moderateCommunityPost(f.db,post.id,moderator,{action:'delete',reason:'Pending author correction',expectedRevision:1},202);
 assert.equal(removed.status,'draft');assert.equal(removed.deleted_at,202);assert.equal(removed.moderation_deleted_at,202);assert.equal(removed.moderation_hold,1);assert.ok(await f.bucket.head(post.object_key));
 for(const who of [undefined,owner.id,moderator.id])await assert.rejects(core.getCommunityPost(f.db,post.id,who),bad('community_not_found'));
 assert.ok(!(await core.listCommunityPosts(f.db,new URL('https://studio.test'),owner,true)).items.some(x=>x.id===post.id));
 f.user={userId:moderator.id,fullName:moderator.name};f.moderatorIDs=moderator.id;
 assert.equal((await routes.readCommunityMedia(new Request('https://studio.test'),post.id)).status,200);assert.equal((await routes.readCommunityMedia(new Request('https://studio.test'),post.id,true)).status,200);assert.equal((await routes.reviewCommunityItem(new Request('https://studio.test'),post.id)).status,200);
 f.user={userId:owner.id,fullName:owner.name};assert.equal((await routes.readCommunityMedia(new Request('https://studio.test'),post.id)).status,404);assert.equal((await routes.reviewCommunityItem(new Request('https://studio.test'),post.id)).status,403);
 const restored=await core.moderateCommunityPost(f.db,post.id,moderator,{action:'restore',reason:'Author may revise',expectedRevision:2},203);assert.equal(restored.deleted_at,null);assert.equal(restored.moderation_deleted_at,null);assert.equal(restored.status,'draft');assert.equal(restored.moderation_hold,1);
 await assert.rejects(core.publishCommunityPost(f.db,post.id,owner,{license:'CC-BY-4.0',confirmRights:true}),bad('community_moderation_hold'));
 const reinstated=await core.moderateCommunityPost(f.db,post.id,moderator,{action:'reinstate',reason:'Review complete',expectedRevision:3},204);assert.equal(reinstated.status,'draft');assert.equal(reinstated.moderation_hold,0);await assert.rejects(core.getCommunityPost(f.db,post.id),bad('community_not_found'));
 const review=await core.communityModerationDetail(f.db,post.id);assert.deepEqual(review.audit.map(x=>x.action),['reinstate','restore','delete','hide']);assert.deepEqual(review.audit.map(x=>x.revision),[4,3,2,1]);assert.ok(review.audit.every(x=>x.actorId===moderator.id&&x.actorName===moderator.name));assert.equal(review.audit[0].createdAt,204);
 assert.equal(core.communityItem(reinstated).moderatedBy,undefined);assert.equal(core.communityItem(reinstated).moderationRevision,undefined);assert.equal(core.communityItem(reinstated,owner.id).moderationReason,'Review complete');
});
test('an author can permanently remove their moderator-trashed upload, and failed owner deletion is never admin-restorable',async()=>{
 const db=database(),bucket=new Bucket(),post=await published(db,bucket),moderator={id:'admin'};
 await core.moderateCommunityPost(db,post.id,moderator,{action:'delete',reason:'Community removal'},200);
 bucket.failDelete=true;await assert.rejects(media.deleteCommunityPost(db,bucket,post.id,owner,201));
 assert.equal(db.raw.prepare('SELECT moderation_deleted_at FROM community_posts WHERE id=?').get(post.id).moderation_deleted_at,null);
 await assert.rejects(core.moderationPost(db,post.id),bad('community_not_found'));await assert.rejects(core.moderateCommunityPost(db,post.id,moderator,{action:'restore',reason:'Must not undo author deletion'}),bad('community_not_found'));
 assert.equal((await core.listCommunityModeration(db,new URL('https://studio.test?scope=deleted'))).items.length,0);
 bucket.failDelete=false;await media.deleteCommunityPost(db,bucket,post.id,owner,202);assert.equal(await bucket.head(post.object_key),null);assert.equal(db.raw.prepare('SELECT COUNT(*) n FROM community_moderation_audit').get().n,0);
});
test('review state changes and audit are atomic and stale or malformed requests cannot change work',async()=>{
 const db=database(),bucket=new Bucket(),post=await published(db,bucket),moderator={id:'admin'};
 for(const body of [{action:'hide'},{action:'hide',reason:' '},{action:'hide',reason:'a'.repeat(501)}])await assert.rejects(core.moderateCommunityPost(db,post.id,moderator,body),bad('community_review_reason'));
 for(const body of [{action:'publish',reason:'No'},{action:'hide',reason:'No',ownerId:'spoof'},{action:'hide',reason:'No',expectedRevision:-1}])await assert.rejects(core.moderateCommunityPost(db,post.id,moderator,body),bad('community_invalid_moderation'));
 await assert.rejects(core.moderateCommunityPost(db,post.id,moderator,{action:'restore',reason:'Not deleted'}),bad('community_invalid_moderation_state'));
 db.raw.exec("CREATE TRIGGER fail_review_update BEFORE UPDATE OF moderation_revision ON community_posts BEGIN SELECT RAISE(ABORT,'fixture rejection'); END");
 await assert.rejects(core.moderateCommunityPost(db,post.id,moderator,{action:'hide',reason:'Should roll back'}));assert.equal(db.raw.prepare('SELECT COUNT(*) n FROM community_moderation_audit').get().n,0);assert.equal((await core.getCommunityPost(db,post.id)).moderation_hold,0);db.raw.exec('DROP TRIGGER fail_review_update');
 const race=await Promise.allSettled([core.moderateCommunityPost(db,post.id,moderator,{action:'hide',reason:'First',expectedRevision:0}),core.moderateCommunityPost(db,post.id,{id:'another-admin'},{action:'delete',reason:'Second',expectedRevision:0})]);
 assert.equal(race.filter(x=>x.status==='fulfilled').length,1);assert.equal(race.find(x=>x.status==='rejected').reason.code,'community_review_changed');assert.equal(db.raw.prepare('SELECT COUNT(*) n FROM community_moderation_audit').get().n,1);
 await assert.rejects(core.moderateCommunityPost(db,post.id,moderator,{action:'delete',reason:'Stale',expectedRevision:0}),bad('community_review_changed'));
});
test('moderation rechecks author visibility inside the transaction and role checks reject forged or cross-origin requests',async()=>{
 const f=fixture(),post=await published(f.db,f.bucket),privatePost=await ready(f.db,f.bucket);f.moderatorIDs='admin';f.user={userId:'admin',fullName:'Reviewer'};
 assert.equal((await routes.moderateCommunity(jsonRequest({action:'hide',reason:'No CSRF'},'POST','https://attacker.test'),post.id)).status,403);
 assert.equal((await routes.moderateCommunity(jsonRequest({action:'hide',reason:'No private access'}),privatePost.id)).status,404);assert.equal((await routes.reviewCommunityItem(new Request('https://studio.test'),privatePost.id)).status,404);
 f.user={userId:'ordinary-user',fullName:'Admin'};assert.equal((await routes.moderateCommunity(jsonRequest({action:'delete',reason:'Spoof',moderatorId:'admin'}),post.id)).status,403);assert.equal((await routes.reviewCommunity(new Request('https://studio.test'))).status,403);
 f.user=null;assert.equal((await routes.reviewCommunity(new Request('https://studio.test'))).status,401);assert.equal((await routes.reviewCommunityItem(new Request('https://studio.test'),post.id)).status,401);
 const originalBatch=f.db.batch;f.db.batch=async statements=>{f.db.raw.prepare("UPDATE community_posts SET status='draft' WHERE id=?").run(post.id);return originalBatch(statements);};
 await assert.rejects(core.moderateCommunityPost(f.db,post.id,{id:'admin'},{action:'delete',reason:'Author unpublished concurrently'}),bad('community_review_changed'));
 assert.equal(f.db.raw.prepare('SELECT COUNT(*) n FROM community_moderation_audit').get().n,0);assert.equal((await core.getCommunityPost(f.db,post.id,owner.id)).deleted_at,null);
});
test('author deletion wins a race after a moderator reads trash and before restoration commits',async()=>{
 const db=database(),bucket=new Bucket(),post=await published(db,bucket),moderator={id:'admin'};
 await core.moderateCommunityPost(db,post.id,moderator,{action:'delete',reason:'Admin trash'},200);
 const batch=db.batch;db.batch=async statements=>{await media.deleteCommunityPost(db,bucket,post.id,owner,201);return batch(statements);};
 await assert.rejects(core.moderateCommunityPost(db,post.id,moderator,{action:'restore',reason:'Stale restoration',expectedRevision:1},202),bad('community_review_changed'));
 assert.equal(await bucket.head(post.object_key),null);assert.equal(db.raw.prepare('SELECT COUNT(*) n FROM community_posts WHERE id=?').get(post.id).n,0);assert.equal(db.raw.prepare('SELECT COUNT(*) n FROM community_moderation_audit').get().n,0);
});
test.after(async()=>{await rm(temp,{recursive:true,force:true});});
