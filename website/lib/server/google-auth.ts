import { APIError, nowSeconds, randomSecret, sha256 } from './primitives';
import type { Account, AppEnv } from './runtime';
export const OAUTH_COOKIE = '__Host-fs-oauth';
export const SESSION_COOKIE = '__Host-fs-session';
export function googleConfigured(env: AppEnv) { return !!(env.GOOGLE_CLIENT_ID?.endsWith('.apps.googleusercontent.com') && env.GOOGLE_CLIENT_SECRET && (env.SESSION_SECRET?.length ?? 0) >= 32 && env.SITE_ORIGIN?.startsWith('https://')); }
function requireGoogle(env: AppEnv) { if (!googleConfigured(env)) throw new APIError(503,'google_not_configured','Google sign-in is not configured yet. Continue with ChatGPT.'); }
export const cookieHeader = (name:string,value:string,maxAge:number) => `${name}=${value}; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=${maxAge}`;
export function readCookie(request: Request, name: string) { return (request.headers.get('cookie') ?? '').split(';').map(x=>x.trim()).find(x=>x.startsWith(`${name}=`))?.slice(name.length+1) ?? ''; }
function base64URL(data: Uint8Array) { return btoa(String.fromCharCode(...data)).replaceAll('+','-').replaceAll('/','_').replace(/=+$/,''); }
function decodeURL(value:string) { return Uint8Array.from(atob(value.replaceAll('-','+').replaceAll('_','/')),c=>c.charCodeAt(0)); }
async function cookieKey(secret:string,usage:KeyUsage[]) { return crypto.subtle.importKey('raw',new TextEncoder().encode(secret),{name:'HMAC',hash:'SHA-256'},false,usage); }
export async function signCookie(token:string,secret:string) { const signature=await crypto.subtle.sign('HMAC',await cookieKey(secret,['sign']),new TextEncoder().encode(token));return `${token}.${base64URL(new Uint8Array(signature))}`; }
export async function verifyCookie(value:string,secret:string) {
  const parts=value.split('.');if(parts.length!==2||!/^[a-f0-9]{64}$/.test(parts[0])||!/^[A-Za-z0-9_-]{43}$/.test(parts[1]))return null;
  try{return await crypto.subtle.verify('HMAC',await cookieKey(secret,['verify']),decodeURL(parts[1]),new TextEncoder().encode(parts[0]))?parts[0]:null;}catch{return null;}
}
export function safeReturnTo(value:string|null) {
  if(!value||!value.startsWith('/')||value.startsWith('//')||value.length>512)return '/account';
  try{const u=new URL(value,'https://focus.invalid');return u.origin==='https://focus.invalid'&&!u.pathname.startsWith('/api/')&&!u.pathname.includes('signin-with-chatgpt')?u.pathname+u.search:'/account';}catch{return '/account';}
}
export async function startGoogle(db:D1Database,env:AppEnv,returnTo:string|null,now=nowSeconds()) {
  requireGoogle(env);const state=randomSecret(),nonce=randomSecret(),verifier=randomSecret();
  await db.batch([
    db.prepare('DELETE FROM oauth_requests WHERE expires_at<=?').bind(now),
    db.prepare('INSERT INTO oauth_requests(state_hash,nonce_hash,verifier,return_to,expires_at) SELECT ?,?,?,?,? WHERE (SELECT COUNT(*) FROM oauth_requests)<1000').bind(await sha256(state),await sha256(nonce),verifier,safeReturnTo(returnTo),now+600),
  ]);
  if(!await db.prepare('SELECT state_hash FROM oauth_requests WHERE state_hash=?').bind(await sha256(state)).first())throw new APIError(429,'sign_in_busy','Please try signing in again shortly.');
  const origin=new URL(env.SITE_ORIGIN!).origin;
  const challenge=base64URL(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(verifier))));
  const query=new URLSearchParams({client_id:env.GOOGLE_CLIENT_ID!,redirect_uri:`${origin}/api/auth/google/callback`,response_type:'code',scope:'openid email',state,nonce,code_challenge:challenge,code_challenge_method:'S256',prompt:'select_account'});
  return {url:`https://accounts.google.com/o/oauth2/v2/auth?${query}`,cookie:cookieHeader(OAUTH_COOKIE,await signCookie(state,env.SESSION_SECRET!),600)};
}
type GoogleJWK = JsonWebKey & {kid:string;alg?:string;use?:string};
let cachedKeys:{keys:GoogleJWK[];until:number}|null=null;
async function googleKeys(now:number,force=false) {
  if(!force&&cachedKeys&&cachedKeys.until>now)return cachedKeys.keys;
  const response=await fetch('https://www.googleapis.com/oauth2/v3/certs',{signal:AbortSignal.timeout(10000)});
  if(!response.ok)throw new APIError(502,'identity_provider_error','Google sign-in is temporarily unavailable.');
  const data=await response.json() as {keys?:GoogleJWK[]};
  if(!Array.isArray(data.keys)||!data.keys.length||data.keys.length>20)throw new APIError(502,'identity_provider_error','Google sign-in is temporarily unavailable.');
  const age=Math.min(3600,Math.max(60,Number(response.headers.get('cache-control')?.match(/max-age=(\d+)/)?.[1]??300)));
  cachedKeys={keys:data.keys,until:now+age};return data.keys;
}
export async function verifyGoogleIDToken(token:string,clientId:string,nonceHash:string,now=nowSeconds(),providedKeys?:GoogleJWK[]) {
  const fail=()=>new APIError(401,'invalid_google_identity','Google identity could not be verified. Please sign in again.');
  if(typeof token!=='string'||token.length>16384)throw fail();const parts=token.split('.');if(parts.length!==3)throw fail();
  let header:{alg:string;kid:string};let claims:Record<string,unknown>;
  try{header=JSON.parse(new TextDecoder().decode(decodeURL(parts[0])));claims=JSON.parse(new TextDecoder().decode(decodeURL(parts[1])));}catch{throw fail();}
  if(header.alg!=='RS256'||typeof header.kid!=='string'||header.kid.length>128)throw fail();
  let keys=providedKeys??await googleKeys(now);let jwk=keys.find(k=>k.kid===header.kid);
  if(!jwk&&!providedKeys){keys=await googleKeys(now,true);jwk=keys.find(k=>k.kid===header.kid);}
  if(!jwk||jwk.kty!=='RSA'||(jwk.alg&&jwk.alg!=='RS256')||(jwk.use&&jwk.use!=='sig'))throw fail();
  try{const key=await crypto.subtle.importKey('jwk',jwk,{name:'RSASSA-PKCS1-v1_5',hash:'SHA-256'},false,['verify']);if(!await crypto.subtle.verify('RSASSA-PKCS1-v1_5',key,decodeURL(parts[2]),new TextEncoder().encode(`${parts[0]}.${parts[1]}`)))throw fail();}catch{throw fail();}
  const aud=claims.aud;const audienceMatches=aud===clientId||(Array.isArray(aud)&&aud.includes(clientId)&&claims.azp===clientId);
  if(!audienceMatches||(claims.azp!==undefined&&claims.azp!==clientId)||!['https://accounts.google.com','accounts.google.com'].includes(String(claims.iss))||typeof claims.exp!=='number'||claims.exp<=now||typeof claims.iat!=='number'||claims.iat>now+60||claims.iat<now-7200||typeof claims.nonce!=='string'||await sha256(claims.nonce)!==nonceHash||typeof claims.sub!=='string'||!/^[A-Za-z0-9_-]{1,255}$/.test(claims.sub)||claims.email_verified!==true||typeof claims.email!=='string'||claims.email.length>320)throw fail();
  return {id:`google:${claims.sub}`,email:claims.email};
}
export async function finishGoogle(db:D1Database,env:AppEnv,request:Request,now=nowSeconds()) {
  requireGoogle(env);const url=new URL(request.url);const state=url.searchParams.get('state')??'',code=url.searchParams.get('code')??'';
  const cookie=await verifyCookie(readCookie(request,OAUTH_COOKIE),env.SESSION_SECRET!);
  if(!/^[a-f0-9]{64}$/.test(state)||!cookie||await sha256(state)!==await sha256(cookie)||!code||code.length>4096)throw new APIError(400,'invalid_oauth_state','Your sign-in expired. Please try again.');
  // Consume state exactly once before exchanging the authorization code.
  const saved=await db.prepare('DELETE FROM oauth_requests WHERE state_hash=? AND expires_at>? RETURNING nonce_hash,verifier,return_to').bind(await sha256(state),now).first<{nonce_hash:string;verifier:string;return_to:string}>();
  if(!saved)throw new APIError(400,'invalid_oauth_state','Your sign-in expired. Please try again.');
  const origin=new URL(env.SITE_ORIGIN!).origin;
  const response=await fetch('https://oauth2.googleapis.com/token',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams({code,client_id:env.GOOGLE_CLIENT_ID!,client_secret:env.GOOGLE_CLIENT_SECRET!,redirect_uri:`${origin}/api/auth/google/callback`,grant_type:'authorization_code',code_verifier:saved.verifier}),signal:AbortSignal.timeout(12000)});
  if(!response.ok)throw new APIError(401,'google_exchange_failed','Google sign-in expired. Please try again.');
  const data=await response.json() as {id_token?:string};
  const identity=await verifyGoogleIDToken(data.id_token??'',env.GOOGLE_CLIENT_ID!,saved.nonce_hash,now);
  const token=randomSecret();const maxAge=30*86400;
  await db.batch([
    db.prepare('INSERT INTO accounts(id,email,created_at) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET email=excluded.email').bind(identity.id,identity.email,now),
    db.prepare('DELETE FROM web_sessions WHERE expires_at<=?').bind(now),
    db.prepare('INSERT INTO web_sessions(hash,account_id,expires_at) VALUES(?,?,?)').bind(await sha256(token),identity.id,now+maxAge),
  ]);
  return {location:`${origin}${safeReturnTo(saved.return_to)}`,cookies:[cookieHeader(SESSION_COOKIE,await signCookie(token,env.SESSION_SECRET!),maxAge),cookieHeader(OAUTH_COOKIE,'',0)]};
}
export async function webSessionAccount(db:D1Database,env:AppEnv,request:Request,now=nowSeconds()) {
  if(!env.SESSION_SECRET)return null;const token=await verifyCookie(readCookie(request,SESSION_COOKIE),env.SESSION_SECRET);if(!token)return null;
  return db.prepare('SELECT a.* FROM accounts a JOIN web_sessions s ON a.id=s.account_id WHERE s.hash=? AND s.expires_at>?').bind(await sha256(token),now).first<Account>();
}
export async function revokeWebSession(db:D1Database,env:AppEnv,request:Request) {
  const token=env.SESSION_SECRET?await verifyCookie(readCookie(request,SESSION_COOKIE),env.SESSION_SECRET):null;
  if(token)await db.prepare('DELETE FROM web_sessions WHERE hash=?').bind(await sha256(token)).run();
  return cookieHeader(SESSION_COOKIE,'',0);
}
