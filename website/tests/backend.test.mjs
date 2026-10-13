import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { mkdtemp, readFile, readdir, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import ts from 'typescript';

// Run the real SQL against SQLite, matching D1's transactional batch semantics.
// Only the Cloudflare transport and Stripe HTTPS responses are mocked.
const temp=await mkdtemp(join(tmpdir(),'focus-backend-'));
for(const name of ['primitives','exports','devices','stripe','google-auth']) {
  const source=await readFile(new URL(`../lib/server/${name}.ts`,import.meta.url),'utf8');
  const js=ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.ES2022}}).outputText.replaceAll("'./primitives'","'./primitives.mjs'");
  await writeFile(join(temp,`${name}.mjs`),js);
}
const primitive=await import(pathToFileURL(join(temp,'primitives.mjs')));
const {reserveExport,updateExport,entitlement}=await import(pathToFileURL(join(temp,'exports.mjs')));
const {createDeviceGrant,approveDevice,exchangeDeviceGrant}=await import(pathToFileURL(join(temp,'devices.mjs')));
const {createCheckout,synchronizeCustomer,canonicalSubscriptions,requireBilling}=await import(pathToFileURL(join(temp,'stripe.mjs')));
const google=await import(pathToFileURL(join(temp,'google-auth.mjs')));
const sqlDir=new URL('../drizzle/',import.meta.url);
const migrations=(await readdir(sqlDir)).filter(n=>n.endsWith('.sql')).sort();
const sql=(await Promise.all(migrations.map(n=>readFile(new URL(n,sqlDir),'utf8')))).join('\n');
function database() {
  const db=new DatabaseSync(':memory:');db.exec('PRAGMA foreign_keys=ON;');db.exec(sql);
  function prepare(sql,args=[]){return {bind(...values){return prepare(sql,values)},async first(){return db.prepare(sql).get(...args)??null},async all(){return {results:db.prepare(sql).all(...args)}},async run(){const info=db.prepare(sql).run(...args);return {meta:{changes:Number(info.changes)}}},_run(){return db.prepare(sql).run(...args)}};}
  return {raw:db,prepare,async batch(statements){db.exec('BEGIN IMMEDIATE');try{const rows=statements.map(s=>s._run());db.exec('COMMIT');return rows;}catch(e){db.exec('ROLLBACK');throw e;}}};
}
function account(db,id='userA',customer=null){db.raw.prepare('INSERT INTO accounts(id,email,created_at,stripe_customer_id) VALUES(?,?,?,?)').run(id,`${id}@example.invalid`,100,customer);return {id,email:`${id}@example.invalid`,stripe_customer_id:customer,sync_version:0};}
const rejectCode=(code)=>error=>error?.code===code;
const env={STRIPE_SECRET_KEY:'fake-test-key',STRIPE_WEBHOOK_SECRET:'fake-signing-secret',STRIPE_MONTHLY_PRICE_ID:'price_monthly',STRIPE_YEARLY_PRICE_ID:'price_yearly'};
function subscription(status='active',end=99999){return {id:'sub_test',customer:'cus_test',status,items:{data:[{current_period_end:end,price:{id:'price_monthly'}}]}};}

test('one free export cannot be double-reserved by concurrent devices',async()=>{
 const db=database();account(db);const results=await Promise.allSettled(Array.from({length:20},(_,i)=>reserveExport(db,'userA',`job${i}`,'project',100)));
 assert.equal(results.filter(r=>r.status==='fulfilled').length,1);
 assert.ok(results.filter(r=>r.status==='rejected').every(r=>r.reason.code==='export_in_progress'));
 assert.equal(db.raw.prepare("SELECT COUNT(*) n FROM export_jobs WHERE status='reserved'").get().n,1);
});
test('failed/cancelled renders release trial; only successful commit consumes it, retry is idempotent',async()=>{
 const db=database();account(db);const first=await reserveExport(db,'userA','cancel','p',100);
 await updateExport(db,'userA',first.exportId,'release',101);
 const second=await reserveExport(db,'userA','success','p',102);
 assert.equal((await reserveExport(db,'userA','success','p',103)).exportId,second.exportId);
 await assert.rejects(reserveExport(db,'userA','success','other',103),rejectCode('idempotency_conflict'));
 await updateExport(db,'userA',second.exportId,'commit',104);await updateExport(db,'userA',second.exportId,'commit',105);
 assert.equal((await updateExport(db,'userA',second.exportId,'release',106)).status,'committed');
 await assert.rejects(reserveExport(db,'userA','again','p',107),rejectCode('subscription_required'));
 assert.equal((await entitlement(db,'userA',107)).freeExportsRemaining,0);
});
test('expired leases recover quota but cannot later commit or renew',async()=>{
 const db=database();account(db);const old=await reserveExport(db,'userA','old','p',100);
 const next=await reserveExport(db,'userA','new','p',7301);
 await assert.rejects(updateExport(db,'userA',old.exportId,'commit',7302),rejectCode('export_lease_expired'));
 await assert.rejects(updateExport(db,'userA',old.exportId,'renew',7302),rejectCode('export_lease_expired'));
 const renew=await updateExport(db,'userA',next.exportId,'renew',7400);assert.equal(renew.expiresAt,14600);
 await updateExport(db,'userA',next.exportId,'commit',14599);
});
test('account boundary hides other users exports',async()=>{
 const db=database();account(db);account(db,'userB');const job=await reserveExport(db,'userA','a','p',100);
 await assert.rejects(updateExport(db,'userB',job.exportId,'commit',101),rejectCode('export_not_found'));
 assert.equal((await reserveExport(db,'userB','a','p',101)).mode,'trial');
});
test('paid export does not consume trial; expired or past-due subscriptions do not authorize',async()=>{
 const db=database();account(db);
 db.raw.prepare('INSERT INTO subscriptions VALUES(?,?,?,?,?,?,?)').run('sub1','userA','active','monthly','price_monthly',1000,100);
 const a=await reserveExport(db,'userA','paidA','p',100);const b=await reserveExport(db,'userA','paidB','p',100);
 assert.equal(a.mode,'subscription');assert.equal(b.mode,'subscription');await updateExport(db,'userA',a.exportId,'commit',101);
 assert.equal((await entitlement(db,'userA',102)).freeExportsRemaining,1);
 db.raw.prepare("UPDATE subscriptions SET status='past_due'").run();
 await assert.rejects(updateExport(db,'userA',b.exportId,'commit',103),rejectCode('subscription_required'));
 assert.equal((await reserveExport(db,'userA','trial','p',103)).mode,'trial');
});
test('device approval is explicit, short-lived and returns hashed reusable token on delivery retry',async()=>{
 const db=database();account(db);const grant=await createDeviceGrant(db,'https://studio.test',100);
 assert.equal(await exchangeDeviceGrant(db,grant.deviceCode,101),null);
 assert.match(grant.userCode,/^[A-F0-9]{6}-[A-F0-9]{6}$/);
 await approveDevice(db,'userA',grant.userCode,'Mac',102);
 await assert.rejects(approveDevice(db,'userA',grant.userCode,'Other',103),rejectCode('code_unavailable'));
 const first=await exchangeDeviceGrant(db,grant.deviceCode,104);const retry=await exchangeDeviceGrant(db,grant.deviceCode,105);
 assert.equal(first.accessToken,retry.accessToken);assert.equal(db.raw.prepare('SELECT COUNT(*) n FROM device_tokens').get().n,1);
 const row=db.raw.prepare('SELECT * FROM device_tokens').get();assert.notEqual(row.hash,first.accessToken);assert.equal(row.hash,await primitive.sha256(first.accessToken));
 db.raw.prepare('UPDATE device_tokens SET revoked_at=106').run();await assert.rejects(exchangeDeviceGrant(db,grant.deviceCode,107),rejectCode('device_revoked'));
 await assert.rejects(exchangeDeviceGrant(db,grant.deviceCode,701),rejectCode('code_expired'));
});
test('CSRF checks reject cross-origin and absent browser Origin, permit native bearer only',()=>{
 const url='https://studio.test/api/export';
 assert.throws(()=>primitive.checkOrigin(new Request(url),'https://studio.test'),rejectCode('origin_rejected'));
 assert.throws(()=>primitive.checkOrigin(new Request(url,{headers:{Origin:'https://evil.test',Authorization:`Bearer fs_${'a'.repeat(64)}`}}),'https://studio.test',true),rejectCode('origin_rejected'));
 primitive.checkOrigin(new Request(url,{headers:{Origin:'https://studio.test'}}),'https://studio.test');
 primitive.checkOrigin(new Request(url,{headers:{Authorization:`Bearer fs_${'a'.repeat(64)}`}}),'https://studio.test',true);
 assert.throws(()=>primitive.checkOrigin(new Request(url,{headers:{Authorization:'Bearer bogus'}}),'https://studio.test',true),rejectCode('origin_rejected'));
});
test('bounded input rejects oversized, invalid and non-JSON requests',async()=>{
 await assert.rejects(primitive.readBody(new Request('https://studio.test',{method:'POST',body:'{}'})),rejectCode('json_required'));
 await assert.rejects(primitive.readBody(new Request('https://studio.test',{method:'POST',headers:{'Content-Type':'application/json'},body:'[1]'})),rejectCode('invalid_json'));
 await assert.rejects(primitive.readBody(new Request('https://studio.test',{method:'POST',headers:{'Content-Type':'application/json'},body:'x'.repeat(5000)})),rejectCode('body_too_large'));
});
test('Stripe signature verification rejects tampering and replay beyond five minutes',async()=>{
 const raw='{"id":"evt_test"}';const key=await crypto.subtle.importKey('raw',new TextEncoder().encode('secret'),{name:'HMAC',hash:'SHA-256'},false,['sign']);
 const signature=Buffer.from(await crypto.subtle.sign('HMAC',key,new TextEncoder().encode(`1000.${raw}`))).toString('hex');
 const header=`t=1000,v1=${signature}`;
 await primitive.verifyStripeSignature(raw,header,'secret',1100);
 await primitive.verifyStripeSignature(raw,`t=1000,v1=${'0'.repeat(64)},v1=${signature}`,'secret',1100);
 await assert.rejects(primitive.verifyStripeSignature(raw+' ',header,'secret',1100),rejectCode('invalid_signature'));
 await assert.rejects(primitive.verifyStripeSignature(raw,header,'secret',1301),rejectCode('invalid_signature'));
 await assert.rejects(primitive.verifyStripeSignature(raw,`t=1000,t=1000,v1=${signature}`,'secret',1100),rejectCode('invalid_signature'));
});
test('only configured, paid and unexpired Stripe plans authorize',()=>{
 assert.equal(canonicalSubscriptions([subscription('active')],'a',env,100)[0].active,true);
 assert.equal(canonicalSubscriptions([subscription('trialing')],'a',env,100)[0].active,false);
 assert.equal(canonicalSubscriptions([subscription('active',99)],'a',env,100)[0].active,false);
 const other=subscription();other.items.data[0].price.id='price_other';assert.equal(canonicalSubscriptions([other],'a',env,100).length,0);
 assert.throws(()=>requireBilling({}),rejectCode('billing_not_configured'));
});
test('an older in-flight canonical Stripe response cannot re-enable canceled subscription',async()=>{
 const db=database();account(db,'userA','cus_test');const previous=globalThis.fetch;
 let releaseFirst;let startedFirst;const firstStarted=new Promise(r=>startedFirst=r);let count=0;
 globalThis.fetch=async()=>{count++;if(count===1){startedFirst();return new Promise(r=>releaseFirst=()=>r(Response.json({data:[subscription('active')],has_more:false})));}return Response.json({data:[subscription('canceled')],has_more:false});};
 try{const old=synchronizeCustomer(db,env,'cus_test',100);await firstStarted;await synchronizeCustomer(db,env,'cus_test',101);releaseFirst();await assert.rejects(old,rejectCode('sync_in_progress'));assert.equal(db.raw.prepare('SELECT status FROM subscriptions').get().status,'canceled');}finally{globalThis.fetch=previous;}
});
test('checkout validates advertised prices and fixes return origin server-side',async()=>{
 const db=database();const acc=account(db,'userA','cus_test');const previous=globalThis.fetch;let sent;
 globalThis.fetch=async(url,options)=>{
   if(url.includes('subscriptions?'))return Response.json({data:[],has_more:false});
   if(url.includes('/prices/'))return Response.json({currency:'usd',unit_amount:2900,active:true,recurring:{interval:'month',interval_count:1}});
   if(url.endsWith('checkout/sessions')){sent=new URLSearchParams(options.body);return Response.json({id:'cs_fake',url:'https://checkout.stripe.com/fake',expires_at:86500});}
   throw new Error('Unexpected Stripe request');
 };
 try{const result=await createCheckout(db,env,acc,'monthly','https://studio.test',100);assert.equal(result.url,'https://checkout.stripe.com/fake');assert.equal(sent.get('success_url'),'https://studio.test/account?checkout=success');assert.equal(sent.get('line_items[0][price]'),'price_monthly');assert.equal(sent.get('mode'),'subscription');
   globalThis.fetch=async(url)=>url.includes('subscriptions?')?Response.json({data:[],has_more:false}):Response.json({currency:'usd',unit_amount:9,active:true,recurring:{interval:'month',interval_count:1}});
   await assert.rejects(createCheckout(db,env,acc,'monthly','https://studio.test',101),rejectCode('invalid_price_configuration'));
 }finally{globalThis.fetch=previous;}
});


const googleEnv={GOOGLE_CLIENT_ID:'test.apps.googleusercontent.com',GOOGLE_CLIENT_SECRET:'fake-test-google-secret',SESSION_SECRET:'a-test-only-secret-that-is-at-least-32-characters',SITE_ORIGIN:'https://studio.test'};
const rsa=await crypto.subtle.generateKey({name:'RSASSA-PKCS1-v1_5',modulusLength:2048,publicExponent:new Uint8Array([1,0,1]),hash:'SHA-256'},true,['sign','verify']);
const jwk={...await crypto.subtle.exportKey('jwk',rsa.publicKey),kid:'test-key',alg:'RS256',use:'sig'};
function b64(value){return Buffer.from(JSON.stringify(value)).toString('base64url');}
async function googleJWT(claims,header={alg:'RS256',kid:'test-key'}){const payload=`${b64(header)}.${b64(claims)}`;return `${payload}.${Buffer.from(await crypto.subtle.sign('RSASSA-PKCS1-v1_5',rsa.privateKey,new TextEncoder().encode(payload))).toString('base64url')}`;}
function googleClaims(nonce){return {iss:'https://accounts.google.com',aud:googleEnv.GOOGLE_CLIENT_ID,sub:'12345678',email:'person@example.invalid',email_verified:true,nonce,iat:1000,exp:4600};}
test('Google configuration stays disabled without credentials, cookies reject tampering, return paths stay local',async()=>{
 assert.equal(google.googleConfigured({}),false);assert.equal(google.googleConfigured(googleEnv),true);
 assert.equal(google.safeReturnTo('//evil.test'),'/account');assert.equal(google.safeReturnTo('/\\evil.test'),'/account');assert.equal(google.safeReturnTo('/api/auth/logout'),'/account');
 const token='a'.repeat(64);const signed=await google.signCookie(token,googleEnv.SESSION_SECRET);assert.equal(await google.verifyCookie(signed,googleEnv.SESSION_SECRET),token);assert.equal(await google.verifyCookie('b'+signed.slice(1),googleEnv.SESSION_SECRET),null);
 assert.match(google.cookieHeader('__Host-fs-session',signed,30),/HttpOnly; Secure; SameSite=Lax/);
});
test('Google ID tokens require RSA signature, exact audience, issuer, expiry, nonce and verified email',async()=>{
 const nonce='randomnonce';const claims=googleClaims(nonce);const nonceHash=await primitive.sha256(nonce);
 assert.deepEqual(await google.verifyGoogleIDToken(await googleJWT(claims),googleEnv.GOOGLE_CLIENT_ID,nonceHash,1100,[jwk]),{id:'google:12345678',email:'person@example.invalid'});
 for(const changed of [{aud:'attacker'}, {iss:'https://evil.test'}, {exp:1099}, {nonce:'wrong'}, {email_verified:false}, {azp:'otherclient'}])await assert.rejects(google.verifyGoogleIDToken(await googleJWT({...claims,...changed}),googleEnv.GOOGLE_CLIENT_ID,nonceHash,1100,[jwk]),rejectCode('invalid_google_identity'));
 await assert.rejects(google.verifyGoogleIDToken(await googleJWT(claims,{alg:'HS256',kid:'test-key'}),googleEnv.GOOGLE_CLIENT_ID,nonceHash,1100,[jwk]),rejectCode('invalid_google_identity'));
 const valid=await googleJWT(claims);const parts=valid.split('.');parts[1]=b64({...claims,sub:'hacked'});await assert.rejects(google.verifyGoogleIDToken(parts.join('.'),googleEnv.GOOGLE_CLIENT_ID,nonceHash,1100,[jwk]),rejectCode('invalid_google_identity'));
});
test('Google authorization code flow uses PKCE, single-use state and isolated durable sessions',async()=>{
 const db=database();account(db,'chatgpt-account');const previous=globalThis.fetch;
 const begin=await google.startGoogle(db,googleEnv,'/account?code=123456-ABCDEF',1000);const url=new URL(begin.url);const state=url.searchParams.get('state'),nonce=url.searchParams.get('nonce');
 assert.equal(url.searchParams.get('code_challenge_method'),'S256');assert.equal(url.searchParams.get('scope'),'openid email');assert.equal(url.searchParams.get('redirect_uri'),'https://studio.test/api/auth/google/callback');
 const saved=db.raw.prepare('SELECT * FROM oauth_requests').get();assert.notEqual(saved.state_hash,state);assert.equal(saved.nonce_hash,await primitive.sha256(nonce));
 const callback=`https://studio.test/api/auth/google/callback?state=${state}&code=auth-code`;
 await assert.rejects(google.finishGoogle(db,googleEnv,new Request(callback),1100),rejectCode('invalid_oauth_state'));
 let exchangeBody;
 globalThis.fetch=async(url,options)=>{
   if(url==='https://oauth2.googleapis.com/token'){exchangeBody=new URLSearchParams(options.body);return Response.json({id_token:await googleJWT(googleClaims(nonce))});}
   if(url==='https://www.googleapis.com/oauth2/v3/certs')return Response.json({keys:[jwk]});
   throw new Error('Unexpected provider URL');
 };
 try{
   const request=new Request(callback,{headers:{Cookie:begin.cookie.split(';')[0]}});
   const result=await google.finishGoogle(db,googleEnv,request,1100);assert.equal(result.location,'https://studio.test/account?code=123456-ABCDEF');assert.equal(exchangeBody.get('code_verifier'),saved.verifier);
   const sessionCookie=result.cookies.find(c=>c.startsWith(google.SESSION_COOKIE));const sessionRequest=new Request('https://studio.test/api/account',{headers:{Cookie:sessionCookie.split(';')[0]}});
   const identity=await google.webSessionAccount(db,googleEnv,sessionRequest,1101);assert.equal(identity.id,'google:12345678');assert.equal(db.raw.prepare('SELECT COUNT(*) n FROM accounts').get().n,2);
   await assert.rejects(google.finishGoogle(db,googleEnv,request,1102),rejectCode('invalid_oauth_state'));
   await google.revokeWebSession(db,googleEnv,sessionRequest);assert.equal(await google.webSessionAccount(db,googleEnv,sessionRequest,1103),null);
 }finally{globalThis.fetch=previous;}
});
test.after(async()=>{await rm(temp,{recursive:true,force:true});});
