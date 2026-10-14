import {moderateCommunity} from '@/lib/server/community-routes';
export const dynamic='force-dynamic';
type Context={params:Promise<{id:string}>};
export const POST=async(request:Request,context:Context)=>moderateCommunity(request,(await context.params).id);
