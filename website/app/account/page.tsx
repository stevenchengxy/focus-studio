import { chatGPTSignInPath, chatGPTSignOutPath } from '@/app/chatgpt-auth';
import AccountPanel from './panel';
export const dynamic = 'force-dynamic';
export const metadata = { title: 'Your account · Focus Studio' };
export default async function AccountPage({ searchParams }: { searchParams: Promise<Record<string,string|string[]|undefined>> }) {
  const query = await searchParams;
  const code = typeof query.code === 'string' && /^[a-fA-F0-9-]{12,13}$/.test(query.code) ? query.code : '';
  const communityConnection = query.purpose === 'community';
  const params = new URLSearchParams();
  if (code) params.set('code', code);
  if (communityConnection) params.set('purpose', 'community');
  const returnTo = `/account${params.size ? `?${params}` : ''}`;
  return <AccountPanel code={code} communityConnection={communityConnection} signInUrl={chatGPTSignInPath(returnTo)} signOutUrl={chatGPTSignOutPath('/account')} />;
}
