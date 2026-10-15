import { getChatGPTUser } from '@/app/chatgpt-auth';
import { api, authenticate, database, json, mutationGuard, rateLimit, upsertChatGPTAccount } from '@/lib/server/runtime';
import { APIError, readBody, requireText } from '@/lib/server/primitives';
import { approveDevice, getDeviceGrantPurpose } from '@/lib/server/devices';
export async function POST(request: Request) { return api(async () => {
  mutationGuard(request, false);
  await rateLimit(`pair-approve-attempt:${request.headers.get('cf-connecting-ip') ?? 'unavailable'}`, 40, 600);
  const body = await readBody(request);
  const code = requireText(body.userCode, 'userCode', 20);
  const purpose = await getDeviceGrantPurpose(database(), code);
  let account;
  if (purpose === 'community') {
    const user = await getChatGPTUser();
    if (!user) throw new APIError(401, 'community_sign_in_required', 'Sign in with ChatGPT to confirm your community device.');
    account = await upsertChatGPTAccount(user);
  } else {
    account = await authenticate(request, true);
  }
  await rateLimit(`pair-approve:${account.id}`, 20, 600);
  return json(await approveDevice(database(), account.id, code, requireText(body.name ?? 'Focus Studio', 'name', 80), undefined, purpose));
}); }
