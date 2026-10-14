import {unpublishCommunity} from '@/lib/server/community-routes';
export const dynamic='force-dynamic';
type Context={params:Promise<{id:string}>};
export const POST=async(request:Request,context:Context)=>unpublishCommunity(request,(await context.params).id);
