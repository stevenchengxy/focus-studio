import {detailCommunity,editCommunity,deleteCommunity} from '@/lib/server/community-routes';
export const dynamic='force-dynamic';
type Context={params:Promise<{id:string}>};
export const GET=async(request:Request,context:Context)=>detailCommunity(request,(await context.params).id);
export const PATCH=async(request:Request,context:Context)=>editCommunity(request,(await context.params).id);
export const DELETE=async(request:Request,context:Context)=>deleteCommunity(request,(await context.params).id);
