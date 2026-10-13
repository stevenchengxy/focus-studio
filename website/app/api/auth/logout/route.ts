import { api, database, mutationGuard, settings, siteOrigin } from '@/lib/server/runtime';
import { revokeWebSession } from '@/lib/server/google-auth';
export async function POST(request:Request){return api(async()=>{
  mutationGuard(request,false);const cookie=await revokeWebSession(database(),settings(),request);
  return Response.json({url:`${siteOrigin(request)}/signout-with-chatgpt?return_to=%2Faccount`},{headers:{'Set-Cookie':cookie,'Cache-Control':'no-store'}});
});}
