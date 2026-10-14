import { api, authenticate, json, mutationGuard, rateLimit, settings, siteOrigin } from '@/lib/server/runtime';
import { APIError, readBody } from '@/lib/server/primitives';
import { requireBilling, requireProductPayments, stripe } from '@/lib/server/stripe';
export async function POST(request: Request) { return api(async () => {
  mutationGuard(request); requireProductPayments(); const account = await authenticate(request); await readBody(request);
  await rateLimit(`portal:${account.id}`, 20, 600);
  requireBilling(settings());
  if (!account.stripe_customer_id) throw new APIError(404,'no_subscription','No billing account yet.');
  const session = await stripe<{url:string}>(settings(),'billing_portal/sessions',new URLSearchParams({customer:account.stripe_customer_id,return_url:`${siteOrigin(request)}/account`}));
  return json({url:session.url});
}); }
