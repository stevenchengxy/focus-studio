import {reviewCommunity} from '@/lib/server/community-routes';
export const dynamic='force-dynamic';
export const GET=(request:Request)=>reviewCommunity(request);
