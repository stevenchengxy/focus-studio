import { api, authenticate, database, json, mutationGuard, rateLimit } from '@/lib/server/runtime';
import { readBody, requireText } from '@/lib/server/primitives';
import { reserveExport } from '@/lib/server/exports';
export async function POST(request: Request) { return api(async () => {
  mutationGuard(request); const account = await authenticate(request);
  await rateLimit(`exports:${account.id}`, 60, 60);
  const body = await readBody(request);
  const key = requireText(body.idempotencyKey, 'idempotencyKey', 64);
  const project = requireText(body.projectId, 'projectId', 128);
  return json(await reserveExport(database(), account.id, key, project));
}); }
