import {readCommunityProfile,updateCommunityProfile} from '@/lib/server/community-routes';
export const dynamic='force-dynamic';
export const GET=()=>readCommunityProfile();
export const PATCH=(request:Request)=>updateCommunityProfile(request);
