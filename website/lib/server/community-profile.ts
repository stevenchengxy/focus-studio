import {APIError,nowSeconds} from './primitives';

export function communityDisplayName(value:unknown) {
  if(typeof value!=='string')throw new APIError(400,'community_invalid_profile','Enter a public name from 1 to 64 characters.');
  const name=value.trim();
  if(!name||name.length>64||/[\u0000-\u001f\u007f]/.test(name))throw new APIError(400,'community_invalid_profile','Enter a public name from 1 to 64 characters.');
  if(/[^\s@]+@[^\s@]+/.test(name))throw new APIError(400,'community_public_name_required','Choose a public display name instead of an email address.');
  return name;
}

export async function getCommunityProfile(db:D1Database,ownerId:string) {
  const profile=await db.prepare('SELECT display_name FROM community_profiles WHERE owner_id=?').bind(ownerId).first<{display_name:string}>();
  return {displayName:profile?.display_name??null};
}

export async function saveCommunityProfile(db:D1Database,ownerId:string,body:Record<string,unknown>,now=nowSeconds()) {
  if(Object.keys(body).some(key=>key!=='displayName'))throw new APIError(400,'community_invalid_profile','Only the public display name can be changed.');
  const displayName=communityDisplayName(body.displayName);
  // D1 batch executes as one transaction: a failed sync cannot leave profile
  // and existing attribution names inconsistent. Content/order/status stay put.
  await db.batch([
    db.prepare(`INSERT INTO community_profiles(owner_id,display_name,created_at,updated_at) VALUES(?,?,?,?) ON CONFLICT(owner_id) DO UPDATE SET display_name=excluded.display_name,updated_at=excluded.updated_at`)
      .bind(ownerId,displayName,now,now),
    db.prepare('UPDATE community_posts SET author_name=(SELECT display_name FROM community_profiles WHERE owner_id=?) WHERE owner_id=?').bind(ownerId,ownerId),
  ]);
  return getCommunityProfile(db,ownerId);
}
