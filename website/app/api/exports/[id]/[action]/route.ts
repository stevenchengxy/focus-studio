import { api, authenticate, database, json, mutationGuard } from '@/lib/server/runtime';
import { readBody, requireText } from '@/lib/server/primitives';
import { updateExport } from '@/lib/server/exports';
export async function POST(request: Request, context: { params: Promise<{id:string;action:string}> }) { return api(async () => {
  mutationGuard(request); const account = await authenticate(request); await readBody(request);
  const params = await context.params;
  return json(await updateExport(database(), account.id, requireText(params.id, 'exportId', 64), params.action));
}); }
