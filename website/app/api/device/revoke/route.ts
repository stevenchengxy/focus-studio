import { api, database, json, mutationGuard } from '@/lib/server/runtime';
import { APIError, nowSeconds, readBody, sha256 } from '@/lib/server/primitives';
/** Idempotent self-revocation; the bearer credential is the only target selector. */
export async function POST(request:Request){return api(async()=>{
  mutationGuard(request,true);await readBody(request);
  const header=request.headers.get('authorization')??'';
  if(!/^Bearer fs_[a-f0-9]{64}$/.test(header))throw new APIError(401,'device_required','Connect your device before signing out.');
  await database().prepare('UPDATE device_tokens SET revoked_at=COALESCE(revoked_at,?) WHERE hash=?').bind(nowSeconds(),await sha256(header.slice(7))).run();
  return json({revoked:true});
});}
