import {moderateCommunity,reviewCommunityItem} from '@/lib/server/community-routes';
export const dynamic='force-dynamic';
type Context={params:Promise<{id:string}>};
export const POST=async(request:Request,context:Context)=>moderateCommunity(request,(await context.params).id);
export const GET=async(request:Request,context:Context)=>reviewCommunityItem(request,(await context.params).id);
