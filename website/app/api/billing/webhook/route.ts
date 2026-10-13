import { api, database, json, settings } from '@/lib/server/runtime';
import { APIError, boundedText, nowSeconds, verifyStripeSignature } from '@/lib/server/primitives';
import { requireBilling, synchronizeCustomer } from '@/lib/server/stripe';
export async function POST(request: Request) { return api(async () => {
  const env = settings(); requireBilling(env);
  const raw = await boundedText(request,256*1024);
  await verifyStripeSignature(raw,request.headers.get('stripe-signature'),env.STRIPE_WEBHOOK_SECRET!);
  let event: {id:string;type:string;data:{object:{customer?:string|{id:string}}}};
  try { event = JSON.parse(raw); } catch { throw new APIError(400,'invalid_event','Invalid webhook event.'); }
  if (!/^evt_[A-Za-z0-9]+$/.test(event.id ?? '') || typeof event.type !== 'string') throw new APIError(400,'invalid_event','Invalid webhook event.');
  const db = database();
  if (await db.prepare('SELECT id FROM webhook_events WHERE id=?').bind(event.id).first()) return json({received:true,duplicate:true});
  const relevant = event.type.startsWith('customer.subscription.') || ['checkout.session.completed','checkout.session.async_payment_succeeded','invoice.paid','invoice.payment_failed'].includes(event.type);
  if (relevant) {
    const value = event.data?.object?.customer;
    const customer = typeof value === 'string' ? value : value?.id;
    if (!customer || !/^cus_[A-Za-z0-9]+$/.test(customer)) throw new APIError(400,'invalid_event','Missing billing customer.');
    await synchronizeCustomer(db,env,customer);
  }
  // Insert only after successful canonical synchronization. A failed fetch is
  // retryable; duplicate or out-of-order events never blindly grant entitlement.
  await db.prepare('INSERT OR IGNORE INTO webhook_events(id,processed_at) VALUES(?,?)').bind(event.id,nowSeconds()).run();
  return json({received:true});
}); }
