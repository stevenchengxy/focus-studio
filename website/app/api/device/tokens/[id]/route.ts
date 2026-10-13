import { api, authenticate, database, json, mutationGuard } from '@/lib/server/runtime';
import { nowSeconds, APIError } from '@/lib/server/primitives';
export async function DELETE(request: Request, context: {params:Promise<{id:string}>}) { return api(async () => {
  mutationGuard(request, false); const account = await authenticate(request, true);
  const {id} = await context.params;
  const row = await database().prepare('UPDATE device_tokens SET revoked_at=? WHERE id=? AND account_id=? RETURNING id').bind(nowSeconds(), id, account.id).first();
  if (!row) throw new APIError(404, 'not_found', 'Device not found.');
  return json({revoked:true});
}); }
