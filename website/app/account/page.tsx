import { chatGPTSignInPath, chatGPTSignOutPath } from '@/app/chatgpt-auth';
import AccountPanel from './panel';
export const dynamic = 'force-dynamic';
export const metadata = { title: 'Your account · Focus Studio' };
export default async function AccountPage({ searchParams }: { searchParams: Promise<Record<string,string|string[]|undefined>> }) {
  const query = await searchParams;
  const code = typeof query.code === 'string' && /^[a-fA-F0-9-]{12,13}$/.test(query.code) ? query.code : '';
  const returnTo = `/account${code ? `?code=${encodeURIComponent(code)}` : ''}`;
  return <AccountPanel code={code} signInUrl={chatGPTSignInPath(returnTo)} signOutUrl={chatGPTSignOutPath('/account')} />;
}
