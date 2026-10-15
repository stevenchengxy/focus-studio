import {listCommunity} from '@/lib/server/community-routes';
export const dynamic='force-dynamic';
export const GET=(request: Request)=>listCommunity(request,true);
