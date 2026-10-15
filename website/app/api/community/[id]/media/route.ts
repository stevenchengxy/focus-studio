import {readCommunityMedia,uploadCommunity} from '@/lib/server/community-routes';
export const dynamic='force-dynamic';
type Context={params:Promise<{id:string}>};
export const GET=async(request:Request,context:Context)=>readCommunityMedia(request,(await context.params).id,false);
export const HEAD=GET;
export const PUT=async(request:Request,context:Context)=>uploadCommunity(request,(await context.params).id,false);
