import { database, settings, siteOrigin } from '@/lib/server/runtime';
import { finishGoogle, cookieHeader, OAUTH_COOKIE } from '@/lib/server/google-auth';
export async function GET(request:Request){
  try{const result=await finishGoogle(database(),settings(),request);const headers=new Headers({Location:result.location,'Cache-Control':'no-store','Referrer-Policy':'no-referrer'});for(const cookie of result.cookies)headers.append('Set-Cookie',cookie);return new Response(null,{status:303,headers});}
  catch{return new Response(null,{status:303,headers:{Location:`${siteOrigin(request)}/account?auth=retry`,'Set-Cookie':cookieHeader(OAUTH_COOKIE,'',0),'Cache-Control':'no-store','Referrer-Policy':'no-referrer'}});}
}
