import { api, database, json, mutationGuard, rateLimit } from '@/lib/server/runtime';
import { readBody, sha256 } from '@/lib/server/primitives';
import { activateCommunityClient } from '@/lib/server/community-client';
export async function POST(request: Request) { return api(async () => {
  mutationGuard(request, true);
  await readBody(request, 1024);
  const authorization = request.headers.get('authorization');
  await rateLimit(`community-activate:${await sha256(authorization ?? 'missing')}`, 30, 600);
  return json(await activateCommunityClient(database(), authorization));
}); }
