import {env} from 'cloudflare:workers';
import {getChatGPTUser} from '@/app/chatgpt-auth';
import {APIError} from './primitives';
import {mutationGuard, rateLimit} from './runtime';
import type {CommunityViewer} from './community';

// Sites identity is authoritative here; API tokens and billing identities do
// not grant access to community drafts or another user's uploads.
export async function communityViewer(): Promise<CommunityViewer|null> {
  const user=await getChatGPTUser();
  if(!user)return null;
  const name=user.fullName?.trim();
  return {id:user.userId,...(name && name.length<=64 && !/\S+@\S+\.\S+/.test(name) ? {name} : {})};
}
export async function communityWriter(request: Request,action: string,limit=60) {
  mutationGuard(request,false);
  const viewer=await communityViewer();
  if(!viewer)throw new APIError(401,'community_sign_in_required','Sign in to manage your clips.');
  await rateLimit(`community:${action}:${viewer.id}`,limit,3600);
  return viewer;
}
export function isCommunityModerator(viewer:CommunityViewer|null|undefined) {
  const configured=(env as unknown as {COMMUNITY_MODERATOR_IDS?:string}).COMMUNITY_MODERATOR_IDS;
  if(!viewer||typeof configured!=='string'||configured.length>8192)return false;
  return configured.split(/[\s,]+/).filter(id=>/^[a-zA-Z0-9_:.-]{1,128}$/.test(id)).includes(viewer.id);
}
export function requireCommunityModerator(viewer:CommunityViewer|null) {
  if(!viewer)throw new APIError(401,'community_sign_in_required','Sign in to review reports.');
  if(!isCommunityModerator(viewer))throw new APIError(403,'community_moderator_required','Moderator access is required.');
  return viewer;
}
export function communityBucket(): R2Bucket {
  const bucket=(env as unknown as {BUCKET?:R2Bucket}).BUCKET;
  if(!bucket)throw new APIError(503,'community_storage_unavailable','Media storage is temporarily unavailable.');
  return bucket;
}
export function communityJSON(value: unknown,status=200) {
  // Keep metadata as plain text even if an embedding consumer puts JSON into
  // an HTML script element. Public DTOs deliberately omit email and owner ID.
  const body=JSON.stringify(value).replace(/[<>&\u2028\u2029]/g,char=>`\\u${char.charCodeAt(0).toString(16).padStart(4,'0')}`);
  return new Response(body,{status,headers:{'Content-Type':'application/json; charset=utf-8','Cache-Control':'private, no-store','X-Content-Type-Options':'nosniff'}});
}
export async function communityReadLimit(request: Request) {
  const address=request.headers.get('cf-connecting-ip');
  // This header is set by the hosting edge. Local previews have no public IP.
  if(address)await rateLimit(`community:browse:${address}`,240,60);
}
