import { env } from 'cloudflare:workers';
import { getChatGPTUser } from '@/app/chatgpt-auth';
import { APIError, checkOrigin, nowSeconds, sha256 } from './primitives';
import { webSessionAccount } from './google-auth';
import { PRODUCT_ACCESS } from '../product-access';

export interface AppEnv { DB?: D1Database; SITE_ORIGIN?: string; STRIPE_SECRET_KEY?: string; STRIPE_WEBHOOK_SECRET?: string; STRIPE_MONTHLY_PRICE_ID?: string; STRIPE_YEARLY_PRICE_ID?: string; MAC_DOWNLOAD_URL?: string; WINDOWS_DOWNLOAD_URL?: string; LINUX_DOWNLOAD_URL?: string; DEMO_VIDEO_URL?: string; DEMO_POSTER_URL?: string; GOOGLE_CLIENT_ID?: string; GOOGLE_CLIENT_SECRET?: string; SESSION_SECRET?: string }
export const settings = () => env as unknown as AppEnv;
export function database(): D1Database {
  const db = settings().DB;
  if (!db) throw new APIError(503, 'storage_unavailable', 'Account storage is being configured. Please try again later.');
  return db;
}
export function siteOrigin(request: Request) {
  const configured = settings().SITE_ORIGIN;
  if (configured) { try { const url = new URL(configured); if (url.protocol === 'https:') return url.origin; } catch { /* fail closed */ }
    throw new APIError(503, 'configuration_error', 'The public site address is not configured.');
  }
  // Trusted deployed request host, never X-Forwarded-Host or browser-supplied return URLs.
  return new URL(request.url).origin;
}
export const billingConfigured = () => {
  const e = settings(); return PRODUCT_ACCESS.paymentsEnabled && !!(e.STRIPE_SECRET_KEY && e.STRIPE_WEBHOOK_SECRET && e.STRIPE_MONTHLY_PRICE_ID && e.STRIPE_YEARLY_PRICE_ID);
};
export type Account = { id: string; email: string; stripe_customer_id: string | null; sync_version: number };
export async function authenticate(request: Request, browserOnly = false): Promise<Account> {
  const db = database(); const auth = request.headers.get('authorization');
  if (auth) {
    if (browserOnly || !/^Bearer fs_[a-f0-9]{64}$/.test(auth)) throw new APIError(401, 'sign_in_required', 'Please sign in.');
    const account = await db.prepare(`SELECT a.* FROM accounts a JOIN device_tokens t ON a.id=t.account_id WHERE t.hash=? AND t.purpose='account' AND t.revoked_at IS NULL AND t.expires_at>?`).bind(await sha256(auth.slice(7)), nowSeconds()).first<Account>();
    if (!account) throw new APIError(401, 'device_expired', 'Reconnect this device to your account.');
    return account;
  }
  const webAccount = await webSessionAccount(db,settings(),request);
  if (webAccount) return webAccount;
  const user = await getChatGPTUser();
  if (!user) throw new APIError(401, 'sign_in_required', 'Sign in to continue.');
  return upsertChatGPTAccount(user);
}
/** Explicit Sites identity path for community pairing; Google cookies cannot override it. */
export async function upsertChatGPTAccount(user: {userId:string;email:string}): Promise<Account> {
  const db = database();
  await db.prepare(`INSERT INTO accounts(id,email,created_at) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET email=excluded.email`).bind(user.userId, user.email, nowSeconds()).run();
  return (await db.prepare('SELECT * FROM accounts WHERE id=?').bind(user.userId).first<Account>())!;
}
export function mutationGuard(request: Request, allowNative = true) { checkOrigin(request, siteOrigin(request), allowNative); }
export function json(data: unknown, status = 200) { return Response.json(data, { status, headers: { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' } }); }
export async function api(work: () => Promise<Response>) {
  try { return await work(); } catch (error) {
    if (error instanceof APIError) return json({ error: { code: error.code, message: error.message } }, error.status);
    // Never log raw Stripe errors, identity headers, tokens or SQL bind arguments.
    return json({ error: { code: 'service_error', message: 'The service is temporarily unavailable. Please retry.' } }, 503);
  }
}
export async function rateLimit(key: string, limit: number, windowSeconds: number, db = database()) {
  const now = nowSeconds();
  const hash = await sha256(key);
  const row = await db.prepare(`INSERT INTO rate_limits(key,count,expires_at) VALUES(?,1,?) ON CONFLICT(key) DO UPDATE SET count=CASE WHEN expires_at<=? THEN 1 ELSE count+1 END,expires_at=CASE WHEN expires_at<=? THEN excluded.expires_at ELSE expires_at END RETURNING count`).bind(hash, now + windowSeconds, now, now).first<{count:number}>();
  if (!row || row.count > limit) throw new APIError(429, 'too_many_requests', 'Too many requests. Please wait a moment.');
}
