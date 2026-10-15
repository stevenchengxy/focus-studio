import {listCommunity,createCommunity} from '@/lib/server/community-routes';
export const dynamic='force-dynamic';
export const GET=(request: Request)=>listCommunity(request);
export const POST=(request: Request)=>createCommunity(request);
