import { api, authenticate, database, json, mutationGuard, rateLimit } from '@/lib/server/runtime';
import { readBody, requireText } from '@/lib/server/primitives';
import { approveDevice } from '@/lib/server/devices';
export async function POST(request: Request) { return api(async () => {
  mutationGuard(request, false); const account = await authenticate(request, true);
  await rateLimit(`pair-approve:${account.id}`, 20, 600);
  const body = await readBody(request);
  return json(await approveDevice(database(), account.id, requireText(body.userCode,'userCode',20), requireText(body.name ?? 'Focus Studio','name',80)));
}); }
