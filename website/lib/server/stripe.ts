import { APIError, nowSeconds, sha256, subscriptionIsActive } from './primitives';
import type { AppEnv, Account } from './runtime';

export interface StripeSubscription { id:string; customer:string; status:string; current_period_end?:number; items:{data:Array<{current_period_end?:number;price:{id:string}}>}; }
interface StripeList { data: StripeSubscription[]; has_more: boolean }
export function requireBilling(env: AppEnv) {
  if (!env.STRIPE_SECRET_KEY || !env.STRIPE_WEBHOOK_SECRET || !env.STRIPE_MONTHLY_PRICE_ID || !env.STRIPE_YEARLY_PRICE_ID) throw new APIError(503, 'billing_not_configured', 'Subscriptions are not open yet. Your free export is available.');
  if (![env.STRIPE_MONTHLY_PRICE_ID, env.STRIPE_YEARLY_PRICE_ID].every(id => /^price_[A-Za-z0-9]+$/.test(id))) throw new APIError(503, 'billing_not_configured', 'Subscription prices need to be configured.');
}
export async function stripe<T>(env: AppEnv, path: string, body?: URLSearchParams, key?: string): Promise<T> {
  if (!env.STRIPE_SECRET_KEY) throw new APIError(503, 'billing_not_configured', 'Subscriptions are not open yet.');
  const response = await fetch(`https://api.stripe.com/v1/${path}`, {
    method: body ? 'POST' : 'GET', headers: { Authorization: `Bearer ${env.STRIPE_SECRET_KEY}`, ...(body ? {'Content-Type':'application/x-www-form-urlencoded'} : {}), ...(key ? {'Idempotency-Key':key} : {}) },
    body: body?.toString(), signal: AbortSignal.timeout(12000),
  });
  if (!response.ok) throw new APIError(502, 'billing_provider_error', 'The payment provider is unavailable. Please retry.');
  return await response.json() as T;
}
export function canonicalSubscriptions(subscriptions: StripeSubscription[], accountId: string, env: AppEnv, now: number) {
  return subscriptions.flatMap(sub => {
    const item = sub.items.data.find(item => item.price.id === env.STRIPE_MONTHLY_PRICE_ID || item.price.id === env.STRIPE_YEARLY_PRICE_ID);
    if (!item) return [];
    const end = item.current_period_end ?? sub.current_period_end ?? 0;
    return [{id:sub.id,accountId,status:sub.status,plan:item.price.id === env.STRIPE_MONTHLY_PRICE_ID ? 'monthly':'yearly',priceId:item.price.id,currentPeriodEnd:end,active:subscriptionIsActive(sub.status,end,now)}];
  });
}
export async function synchronizeCustomer(db: D1Database, env: AppEnv, customerId: string, now = nowSeconds()) {
  // A monotonically increasing synchronization generation prevents an older fetch
  // from overwriting a newer sync. Webhook timestamps alone cannot order Stripe state.
  const account = await db.prepare('UPDATE accounts SET sync_version=sync_version+1 WHERE stripe_customer_id=? RETURNING id,sync_version').bind(customerId).first<{id:string;sync_version:number}>();
  if (!account) return null;
  const list = await stripe<StripeList>(env, `subscriptions?customer=${encodeURIComponent(customerId)}&status=all&limit=100`);
  if (list.has_more) throw new APIError(503,'billing_sync_limit','Please contact support to refresh this account.');
  const records = canonicalSubscriptions(list.data, account.id, env, now);
  const statements = [db.prepare('DELETE FROM subscriptions WHERE account_id=? AND EXISTS(SELECT 1 FROM accounts WHERE id=? AND sync_version=?)').bind(account.id, account.id, account.sync_version)];
  for (const r of records) statements.push(db.prepare(`INSERT INTO subscriptions(id,account_id,status,plan,price_id,current_period_end,updated_at) SELECT ?,?,?,?,?,?,? WHERE EXISTS(SELECT 1 FROM accounts WHERE id=? AND sync_version=?)`).bind(r.id,account.id,r.status,r.plan,r.priceId,r.currentPeriodEnd,now,account.id,account.sync_version));
  await db.batch(statements);
  const current = await db.prepare('SELECT sync_version FROM accounts WHERE id=?').bind(account.id).first<{sync_version:number}>();
  if (current?.sync_version !== account.sync_version) throw new APIError(409,'sync_in_progress','Subscription synchronization is in progress. Please retry.');
  return records;
}
export async function ensureCustomer(db: D1Database, env: AppEnv, account: Account) {
  if (account.stripe_customer_id) return account.stripe_customer_id;
  const key = await sha256(account.id);
  const customer = await stripe<{id:string}>(env, 'customers', new URLSearchParams({email:account.email,'metadata[focus_account]':key}), `focus-customer-${key}`);
  await db.prepare('UPDATE accounts SET stripe_customer_id=? WHERE id=? AND stripe_customer_id IS NULL').bind(customer.id, account.id).run();
  return (await db.prepare('SELECT stripe_customer_id FROM accounts WHERE id=?').bind(account.id).first<{stripe_customer_id:string}>())!.stripe_customer_id;
}
export async function createCheckout(db: D1Database, env: AppEnv, account: Account, plan: string, origin: string, now = nowSeconds()) {
  requireBilling(env);
  if (!['monthly','yearly'].includes(plan)) throw new APIError(400,'invalid_plan','Choose monthly or yearly billing.');
  const customer = await ensureCustomer(db,env,account);
  const subs = await synchronizeCustomer(db,env,customer,now);
  if (subs?.some(s => s.active)) throw new APIError(409,'already_subscribed','You already have a subscription. Use Manage billing.');
  const priceId = (plan === 'monthly' ? env.STRIPE_MONTHLY_PRICE_ID : env.STRIPE_YEARLY_PRICE_ID)!;
  const price = await stripe<{currency:string;unit_amount:number;active:boolean;recurring?:{interval:string;interval_count:number}}>(env,`prices/${priceId}`);
  if (!price.active || price.currency !== 'usd' || price.unit_amount !== (plan === 'monthly' ? 2900:10800) || price.recurring?.interval !== (plan === 'monthly' ? 'month':'year') || price.recurring?.interval_count !== 1) throw new APIError(503,'invalid_price_configuration','Subscription pricing is being configured.');
  await db.batch([
    db.prepare('DELETE FROM checkout_sessions WHERE account_id=? AND expires_at<=?').bind(account.id,now),
    db.prepare('INSERT OR IGNORE INTO checkout_sessions(account_id,plan,request_key,expires_at) VALUES(?,?,?,?)').bind(account.id,plan,crypto.randomUUID(),now+1800),
  ]);
  const pending = (await db.prepare('SELECT * FROM checkout_sessions WHERE account_id=?').bind(account.id).first<{plan:string;request_key:string;session_id:string|null;url:string|null;expires_at:number}>())!;
  if (pending.session_id) {
    const existing = await stripe<{status:string;url:string|null}>(env,`checkout/sessions/${encodeURIComponent(pending.session_id)}`);
    if (existing.status === 'complete') throw new APIError(409,'payment_processing','Your checkout is complete. Refresh your account in a moment.');
    if (existing.status === 'open' && pending.plan === plan && existing.url) return {url:existing.url};
    if (existing.status === 'open') {
      // Switching plans explicitly expires the old checkout so both links cannot
      // create two subscriptions. Stripe owns checkout completion/expiry races.
      await stripe(env,`checkout/sessions/${encodeURIComponent(pending.session_id)}/expire`,new URLSearchParams(),`focus-expire-${pending.request_key}`);
    }
    await db.prepare('DELETE FROM checkout_sessions WHERE account_id=? AND request_key=?').bind(account.id,pending.request_key).run();
    return createCheckout(db,env,account,plan,origin,now);
  }
  if (pending.plan !== plan) throw new APIError(409,'checkout_in_progress','A checkout is being prepared. Please try again in a moment.');
  const session = await stripe<{id:string;url:string;expires_at:number}>(env, 'checkout/sessions',new URLSearchParams({mode:'subscription',customer,'line_items[0][price]':priceId,'line_items[0][quantity]':'1',success_url:`${origin}/account?checkout=success`,cancel_url:`${origin}/account?checkout=canceled`,'allow_promotion_codes':'false','client_reference_id':await sha256(account.id)}),`focus-checkout-${pending.request_key}`);
  await db.prepare('UPDATE checkout_sessions SET session_id=?,url=?,expires_at=? WHERE account_id=? AND request_key=?').bind(session.id,session.url,session.expires_at,account.id,pending.request_key).run();
  return {url:session.url};
}
