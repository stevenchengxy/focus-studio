import { api, database, json } from '@/lib/server/runtime';
import { getCommunityClientSession } from '@/lib/server/community-client';

export async function GET(request: Request) { return api(async () => {
  return json(await getCommunityClientSession(database(), request.headers.get('authorization')));
}); }
