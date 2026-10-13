import { api, authenticate, database, json, mutationGuard, rateLimit, settings, siteOrigin } from '@/lib/server/runtime';
import { readBody, requireText } from '@/lib/server/primitives';
import { createCheckout } from '@/lib/server/stripe';
export async function POST(request: Request) { return api(async () => {
  mutationGuard(request); const account = await authenticate(request);
  await rateLimit(`checkout:${account.id}`, 10, 600);
  const body = await readBody(request);
  return json(await createCheckout(database(),settings(),account,requireText(body.plan,'plan',20),siteOrigin(request)));
}); }
