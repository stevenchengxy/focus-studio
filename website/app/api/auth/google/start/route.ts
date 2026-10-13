import { api, database, rateLimit, settings } from '@/lib/server/runtime';
import { startGoogle } from '@/lib/server/google-auth';
export async function GET(request:Request){return api(async()=>{
  await rateLimit(`oauth-start:${request.headers.get('cf-connecting-ip')??'unavailable'}`,12,600);
  const result=await startGoogle(database(),settings(),new URL(request.url).searchParams.get('returnTo'));
  return new Response(null,{status:303,headers:{Location:result.url,'Set-Cookie':result.cookie,'Cache-Control':'no-store','Referrer-Policy':'no-referrer'}});
});}
