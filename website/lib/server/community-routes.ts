import {api,database} from './runtime';
import {APIError,readBody} from './primitives';
import {communityBucket,communityJSON,communityReadLimit,communityViewer,communityWriter,communityContributor,isCommunityModerator,requireCommunityModerator} from './community-runtime';
import {COMMUNITY_ACCOUNT_BYTES,COMMUNITY_ACCOUNT_POSTS,COMMUNITY_MAX_BYTES,communityItem,createCommunityPost,editCommunityPost,getCommunityPost,listCommunityPosts,publishCommunityPost,reportCommunityPost,unpublishCommunityPost,listCommunityModeration,communityModerationDetail,moderateCommunityPost,moderationPost} from './community';
import {communityMediaResponse,communityMediaResponseForPost,deleteCommunityPost,uploadCommunityPoster,uploadCommunityVideo} from './community-media';
import {saveCommunityProfile} from './community-profile';
import {hasCommunityClientActivation} from './community-client';

export const listCommunity=(request: Request,mine=false)=>api(async()=>{
  const viewer=await communityViewer();
  await communityReadLimit(request);
  return communityJSON(await listCommunityPosts(database(),new URL(request.url),viewer,mine));
});
export const communityMe=()=>api(async()=>{
  const viewer=await communityViewer();
  const clientConfirmed=!!viewer && await hasCommunityClientActivation(database(),viewer.id);
  return communityJSON({authenticated:!!viewer,clientConfirmed,canPublish:clientConfirmed,...(viewer?{viewerId:viewer.id}:{}),displayName:viewer?.displayName??null,isModerator:isCommunityModerator(viewer),...(viewer?.name?{viewerName:viewer.name}:{}),maxUploadBytes:COMMUNITY_MAX_BYTES,maxLibraryBytes:COMMUNITY_ACCOUNT_BYTES,maxLibraryPosts:COMMUNITY_ACCOUNT_POSTS});
});
export const readCommunityProfile=()=>api(async()=>{
  const viewer=await communityViewer();
  if(!viewer)throw new APIError(401,'community_sign_in_required','Sign in to manage your public name.');
  return communityJSON({displayName:viewer.displayName??null});
});
export const updateCommunityProfile=(request:Request)=>api(async()=>{
  const viewer=await communityWriter(request,'profile',20);
  return communityJSON(await saveCommunityProfile(database(),viewer.id,await readBody(request,2048)));
});
export const createCommunity=(request: Request)=>api(async()=>{
  const viewer=await communityContributor(request,'create',10);
  communityBucket(); // Do not reserve a draft when media storage is unconfigured.
  const post=await createCommunityPost(database(),viewer,await readBody(request,16384));
  return communityJSON({item:communityItem(post,viewer.id),uploadUrl:`/api/community/${post.id}/media`},201);
});
export const detailCommunity=(request: Request,id: string)=>api(async()=>{
  const viewer=await communityViewer();
  await communityReadLimit(request);
  return communityJSON({item:communityItem(await getCommunityPost(database(),id,viewer?.id),viewer?.id),authenticated:!!viewer});
});
export const editCommunity=(request: Request,id: string)=>api(async()=>{
  const viewer=await communityContributor(request,'edit');
  return communityJSON({item:communityItem(await editCommunityPost(database(),id,viewer,await readBody(request,16384)),viewer.id)});
});
export const deleteCommunity=(request: Request,id: string)=>api(async()=>{
  const viewer=await communityWriter(request,'delete');
  await deleteCommunityPost(database(),communityBucket(),id,viewer);
  return communityJSON({deleted:true});
});
export const publishCommunity=(request: Request,id: string)=>api(async()=>{
  const viewer=await communityContributor(request,'publish',30);
  return communityJSON({item:communityItem(await publishCommunityPost(database(),id,viewer,await readBody(request,1024)),viewer.id)});
});
export const unpublishCommunity=(request: Request,id: string)=>api(async()=>{
  const viewer=await communityWriter(request,'unpublish');
  return communityJSON({item:communityItem(await unpublishCommunityPost(database(),id,viewer),viewer.id)});
});
export const reportCommunity=(request: Request,id: string)=>api(async()=>{
  const viewer=await communityWriter(request,'report',10);
  await reportCommunityPost(database(),id,viewer,await readBody(request,8192));
  return communityJSON({reported:true});
});
export const reviewCommunity=(request:Request)=>api(async()=>{
  requireCommunityModerator(await communityViewer());
  await communityReadLimit(request);
  return communityJSON(await listCommunityModeration(database(),new URL(request.url)));
});
export const reviewCommunityItem=(request:Request,id:string)=>api(async()=>{
  requireCommunityModerator(await communityViewer());
  await communityReadLimit(request);
  return communityJSON(await communityModerationDetail(database(),id));
});
export const moderateCommunity=(request:Request,id:string)=>api(async()=>{
  const viewer=requireCommunityModerator(await communityWriter(request,'moderate',120));
  const post=await moderateCommunityPost(database(),id,viewer,await readBody(request,8192));
  return communityJSON({item:communityItem(post,viewer.id,true)});
});
export const uploadCommunity=(request: Request,id: string,poster=false)=>api(async()=>{
  const viewer=await communityContributor(request,poster?'poster':'upload',20),bucket=communityBucket();
  const post=poster?await uploadCommunityPoster(database(),bucket,id,viewer,request):await uploadCommunityVideo(database(),bucket,id,viewer,request);
  return communityJSON({item:communityItem(post,viewer.id)});
});
export const readCommunityMedia=(request: Request,id: string,poster=false)=>api(async()=>{
  // Browsers send Sites identity headers for same-site media requests too.
  // No query token, client owner ID, or predictable storage URL can grant access.
  if(request.method!=='GET'&&request.method!=='HEAD')throw new APIError(405,'method_not_allowed','Use GET or HEAD.');
  const viewer=await communityViewer();
  try{return await communityMediaResponse(database(),communityBucket(),id,viewer?.id,request,poster);}
  catch(error){
    if(!(error instanceof APIError)||error.status!==404||!isCommunityModerator(viewer))throw error;
    const reported=await moderationPost(database(),id);
    return communityMediaResponseForPost(communityBucket(),reported,request,poster);
  }
});
