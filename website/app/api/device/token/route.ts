import { api, database, json, mutationGuard, rateLimit } from '@/lib/server/runtime';
import { readBody, requireText } from '@/lib/server/primitives';
import { exchangeDeviceGrant } from '@/lib/server/devices';
export async function POST(request: Request) { return api(async () => {
  if (request.headers.has('origin')) mutationGuard(request, false);
  const body = await readBody(request); const code = requireText(body.deviceCode, 'deviceCode', 64);
  await rateLimit(`pair-poll:${request.headers.get('cf-connecting-ip') ?? 'unavailable'}`, 120, 60);
  const result = await exchangeDeviceGrant(database(), code);
  return result ? json(result) : json({status:'authorization_pending'}, 202);
}); }
