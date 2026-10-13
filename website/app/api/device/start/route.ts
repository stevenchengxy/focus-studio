import { api, database, json, mutationGuard, rateLimit, siteOrigin } from '@/lib/server/runtime';
import { readBody } from '@/lib/server/primitives';
import { createDeviceGrant } from '@/lib/server/devices';
export async function POST(request: Request) { return api(async () => {
  if (request.headers.has('origin')) mutationGuard(request, false);
  await readBody(request);
  // CF-Connecting-IP is provided by the hosting edge; global cap bounds storage too.
  await rateLimit(`pair-start:${request.headers.get('cf-connecting-ip') ?? 'unavailable'}`, 12, 600);
  return json(await createDeviceGrant(database(), siteOrigin(request)));
}); }
