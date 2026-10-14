import {APIError, nowSeconds} from './primitives';

export const COMMUNITY_MAX_BYTES = 100 * 1024 * 1024;
export const COMMUNITY_ACCOUNT_BYTES = 500 * 1024 * 1024;
export const COMMUNITY_ACCOUNT_POSTS = 20;
export type CommunityCategory = 'demo' | 'ai-video';
export type CommunityViewer = {id: string; name?: string};
export interface CommunityPost {
  id: string; owner_id: string; title: string; description: string; caption: string; product_url: string | null;
  category: CommunityCategory; author_name: string; status: 'draft' | 'published'; license: string | null;
  filename: string; mime_type: 'video/mp4' | 'video/webm'; size_bytes: number;
  media_state: 'pending' | 'uploading' | 'failed' | 'ready'; object_key: string | null;
  poster_key: string | null; poster_bytes: number | null; poster_token: string | null; poster_expires_at: number | null;
  upload_token: string | null; upload_expires_at: number | null; created_at: number; updated_at: number;
  uploaded_at: number | null; published_at: number | null; license_accepted_at: number | null; deleted_at: number | null;
  moderation_hold: number; moderation_reason: string | null; moderated_at: number | null; moderated_by: string | null;
}
export function communityID(id: string) {
  if (!/^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/i.test(id)) throw new APIError(404,'community_not_found','Clip not found.');
  return id;
}
function text(value: unknown, name: string, max: number, required = false) {
  if (typeof value !== 'string' || value.length > max || /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/.test(value)) throw new APIError(400,'community_invalid_metadata',`Invalid ${name}.`);
  const clean = value.trim();
  if (required && !clean) throw new APIError(400,'community_invalid_metadata',`Enter ${name}.`);
  return clean;
}
export function communityMetadata(body: Record<string, unknown>) {
  const title = text(body.title,'title',100,true);
  const description = text(body.description ?? '', 'description',2000);
  const caption = text(body.caption ?? '', 'caption',1000);
  const authorName = text(body.authorName, 'display name',64,true);
  // Email is not a public profile name, including the auth helper's fallback.
  if (/\S+@\S+\.\S+/.test(authorName)) throw new APIError(400,'community_public_name_required','Choose a public display name instead of an email address.');
  if (body.category !== 'demo' && body.category !== 'ai-video') throw new APIError(400,'community_invalid_category','Choose a clip category.');
  let productUrl: string | null = null;
  if (body.productUrl !== undefined && body.productUrl !== null && body.productUrl !== '') {
    if (typeof body.productUrl !== 'string' || body.productUrl.length > 2048) throw new APIError(400,'community_invalid_url','Enter an HTTPS product URL.');
    try {
      const url = new URL(body.productUrl);
      if (url.protocol !== 'https:' || url.username || url.password || !url.hostname.includes('.') || url.hostname === 'localhost' || url.hostname.endsWith('.local')) throw Error();
      productUrl = url.href;
    } catch { throw new APIError(400,'community_invalid_url','Enter an HTTPS product URL without embedded credentials.'); }
  }
  return {title,description,caption,authorName,productUrl,category:body.category as CommunityCategory};
}
export function communityFile(body: Record<string, unknown>) {
  const filename = text(body.filename,'filename',180,true);
  if (/[\\/\r\n]/.test(filename) || filename === '.' || filename === '..') throw new APIError(400,'community_invalid_filename','Choose a safe video filename.');
  const mimeType = body.mimeType;
  if ((mimeType !== 'video/mp4' && mimeType !== 'video/webm') || !filename.toLowerCase().endsWith(mimeType === 'video/mp4' ? '.mp4' : '.webm')) throw new APIError(415,'community_video_required','Upload an MP4 or WebM video.');
  const sizeBytes = body.sizeBytes;
  if (typeof sizeBytes !== 'number' || !Number.isSafeInteger(sizeBytes) || sizeBytes < 64 || sizeBytes > COMMUNITY_MAX_BYTES) throw new APIError(413,'community_file_too_large','Choose a video up to 100 MB.');
  return {filename,mimeType,sizeBytes};
}
export function communityItem(post: CommunityPost, viewerId?: string, moderator=false) {
  const base = `/api/community/${post.id}`;
  const uploaded = post.media_state === 'ready' && !!post.object_key;
  return {id:post.id,title:post.title,description:post.description,caption:post.caption,productUrl:post.product_url,
    category:post.category,authorName:post.author_name,status:post.status,mimeType:post.mime_type,sizeBytes:post.size_bytes,
    hasMedia:uploaded,uploaded,uploadState:post.owner_id === viewerId ? post.media_state : undefined,
    mediaUrl:uploaded ? `${base}/media` : null,downloadUrl:uploaded ? `${base}/media?download=1` : null,
    posterUrl:post.poster_key ? `${base}/poster` : null,
    license:post.license,licenseUrl:post.license === 'CC-BY-4.0' ? 'https://creativecommons.org/licenses/by/4.0/' : null,
    attribution:post.license ? `${post.title} — ${post.author_name} (CC BY 4.0)` : null,
    publishedAt:post.published_at,createdAt:post.created_at,updatedAt:post.updated_at,isOwner:post.owner_id === viewerId,
    moderationHold:!!post.moderation_hold,moderationReason:post.owner_id === viewerId || moderator ? post.moderation_reason : undefined};
}
export async function getCommunityPost(db: D1Database, id: string, viewerId?: string, ownerOnly = false) {
  const post = await db.prepare('SELECT * FROM community_posts WHERE id=? AND deleted_at IS NULL').bind(communityID(id)).first<CommunityPost>();
  if (!post || (post.owner_id !== viewerId && (ownerOnly || post.status !== 'published' || post.media_state !== 'ready' || post.moderation_hold))) throw new APIError(404,'community_not_found','Clip not found.');
  return post;
}
export async function createCommunityPost(db: D1Database, viewer: CommunityViewer, body: Record<string,unknown>, now = nowSeconds()) {
  const metadata = communityMetadata(body), file = communityFile(body), id = crypto.randomUUID();
  // A single conditional INSERT makes quota reservation atomic across tabs.
  const result = await db.prepare(`INSERT INTO community_posts(id,owner_id,title,description,caption,product_url,category,author_name,filename,mime_type,size_bytes,created_at,updated_at)
    SELECT ?,?,?,?,?,?,?,?,?,?,?,?,? WHERE
    (SELECT COUNT(*) FROM community_posts WHERE owner_id=? AND (deleted_at IS NULL OR object_key IS NOT NULL OR poster_key IS NOT NULL))<? AND
    (SELECT COALESCE(SUM(size_bytes),0) FROM community_posts WHERE owner_id=? AND (deleted_at IS NULL OR object_key IS NOT NULL OR poster_key IS NOT NULL))+?<=?`)
    .bind(id,viewer.id,metadata.title,metadata.description,metadata.caption,metadata.productUrl,metadata.category,metadata.authorName,file.filename,file.mimeType,file.sizeBytes,now,now,
      viewer.id,COMMUNITY_ACCOUNT_POSTS,viewer.id,file.sizeBytes,COMMUNITY_ACCOUNT_BYTES).run();
  if (result.meta.changes !== 1) throw new APIError(429,'community_quota_exceeded','Your library is full. Delete a clip before uploading another.');
  return getCommunityPost(db,id,viewer.id,true);
}
export async function editCommunityPost(db: D1Database, id: string, viewer: CommunityViewer, body: Record<string,unknown>, now = nowSeconds()) {
  const post = await getCommunityPost(db,id,viewer.id,true);
  const allowed = ['title','description','caption','productUrl','category','authorName'];
  if (Object.keys(body).some(key => !allowed.includes(key))) throw new APIError(400,'community_invalid_metadata','Only clip details can be edited.');
  const metadata = communityMetadata({title:post.title,description:post.description,caption:post.caption,productUrl:post.product_url,category:post.category,authorName:post.author_name,...body});
  await db.prepare(`UPDATE community_posts SET title=?,description=?,caption=?,product_url=?,category=?,author_name=?,updated_at=? WHERE id=? AND owner_id=? AND deleted_at IS NULL`)
    .bind(metadata.title,metadata.description,metadata.caption,metadata.productUrl,metadata.category,metadata.authorName,now,id,viewer.id).run();
  return getCommunityPost(db,id,viewer.id,true);
}
export async function publishCommunityPost(db: D1Database, id: string, viewer: CommunityViewer, body: Record<string,unknown>, now = nowSeconds()) {
  const post = await getCommunityPost(db,id,viewer.id,true);
  if (body.license !== 'CC-BY-4.0' || body.confirmRights !== true) throw new APIError(400,'community_license_required','Confirm that you can share this clip under CC BY 4.0.');
  if(post.moderation_hold)throw new APIError(409,'community_moderation_hold','This clip is hidden pending moderation review.');
  if (post.media_state !== 'ready' || !post.object_key) throw new APIError(409,'community_upload_required','Finish uploading the video first.');
  const result=await db.prepare(`UPDATE community_posts SET status='published',license='CC-BY-4.0',license_accepted_at=COALESCE(license_accepted_at,?),published_at=CASE WHEN status='published' THEN published_at ELSE ? END,updated_at=? WHERE id=? AND owner_id=? AND deleted_at IS NULL AND media_state='ready' AND moderation_hold=0`)
    .bind(now,now,now,id,viewer.id).run();
  if(result.meta.changes!==1){const latest=await getCommunityPost(db,id,viewer.id,true);if(latest.moderation_hold)throw new APIError(409,'community_moderation_hold','This clip is hidden pending moderation review.');throw new APIError(409,'community_post_changed','The clip changed. Please refresh.');}
  return getCommunityPost(db,id,viewer.id,true);
}
export async function unpublishCommunityPost(db: D1Database, id: string, viewer: CommunityViewer, now = nowSeconds()) {
  await getCommunityPost(db,id,viewer.id,true);
  await db.prepare(`UPDATE community_posts SET status='draft',updated_at=? WHERE id=? AND owner_id=? AND deleted_at IS NULL`).bind(now,id,viewer.id).run();
  return getCommunityPost(db,id,viewer.id,true);
}
export async function reportCommunityPost(db: D1Database, id: string, viewer: CommunityViewer, body: Record<string,unknown>, now = nowSeconds()) {
  const post = await getCommunityPost(db,id);
  if (post.owner_id === viewer.id) throw new APIError(400,'community_own_report','Unpublish or delete your own clip.');
  if (!['copyright','privacy','inappropriate','other'].includes(String(body.reason))) throw new APIError(400,'community_invalid_report','Choose a report reason.');
  const details = text(body.details ?? '', 'report details',1000);
  await db.prepare(`INSERT INTO community_reports(id,post_id,reporter_id,reason,details,created_at) VALUES(?,?,?,?,?,?) ON CONFLICT(post_id,reporter_id) DO UPDATE SET reason=excluded.reason,details=excluded.details,created_at=excluded.created_at`)
    .bind(crypto.randomUUID(),id,viewer.id,body.reason,details,now).run();
}
function cursor(value: string | null) {
  if (!value) return null;
  try {
    if (value.length > 200) throw Error();
    const pair = JSON.parse(atob(value.replaceAll('-','+').replaceAll('_','/')));
    if (!Array.isArray(pair) || pair.length !== 2 || !Number.isSafeInteger(pair[0]) || pair[0] < 0 || typeof pair[1] !== 'string') throw Error();
    return {time:pair[0] as number,id:communityID(pair[1])};
  } catch { throw new APIError(400,'community_invalid_cursor','Invalid page cursor.'); }
}
export async function listCommunityPosts(db: D1Database, url: URL, viewer?: CommunityViewer | null, mine = false) {
  const category = url.searchParams.get('category');
  if (category && category !== 'demo' && category !== 'ai-video') throw new APIError(400,'community_invalid_category','Unknown category.');
  const query = (url.searchParams.get('q') ?? '').trim();
  if(query.length>120)throw new APIError(400,'community_invalid_search','Search using up to 120 characters.');
  const limit = Number(url.searchParams.get('limit') ?? '24');
  if (!Number.isSafeInteger(limit) || limit < 1 || limit > 50) throw new APIError(400,'community_invalid_page','Choose a page size from 1 to 50.');
  if (mine && !viewer) throw new APIError(401,'community_sign_in_required','Sign in to manage your clips.');
  const page = cursor(url.searchParams.get('cursor'));
  const column = mine ? 'updated_at' : 'published_at';
  const conditions = ['deleted_at IS NULL']; const values: (string | number)[] = [];
  if (mine) { conditions.push('owner_id=?'); values.push(viewer!.id); }
  else conditions.push("status='published' AND media_state='ready' AND moderation_hold=0");
  if (category) { conditions.push('category=?'); values.push(category); }
  if(query) {
    // Wildcards are literal user text, not unbounded SQL search operators.
    const pattern=`%${query.replace(/[\\%_]/g,char=>`\\${char}`)}%`;
    conditions.push("(title LIKE ? ESCAPE '\\' OR description LIKE ? ESCAPE '\\' OR author_name LIKE ? ESCAPE '\\')");
    values.push(pattern,pattern,pattern);
  }
  if (page) { conditions.push(`(${column}<? OR (${column}=? AND id<?))`); values.push(page.time,page.time,page.id); }
  const result = await db.prepare(`SELECT * FROM community_posts WHERE ${conditions.join(' AND ')} ORDER BY ${column} DESC,id DESC LIMIT ?`).bind(...values,limit + 1).all<CommunityPost>();
  const rows = result.results.slice(0,limit), last = rows.at(-1);
  const nextCursor = result.results.length > limit && last ? btoa(JSON.stringify([mine ? last.updated_at : last.published_at,last.id])).replaceAll('+','-').replaceAll('/','_').replace(/=+$/,'') : null;
  return {items:rows.map(post=>communityItem(post,viewer?.id)),nextCursor,authenticated:!!viewer,...(viewer?.name ? {viewerName:viewer.name} : {})};
}

export async function moderationPost(db:D1Database,id:string) {
  // Review permission does not expose unrelated private drafts.
  const post=await db.prepare(`SELECT * FROM community_posts WHERE id=? AND deleted_at IS NULL AND (moderation_hold=1 OR EXISTS(SELECT 1 FROM community_reports WHERE post_id=community_posts.id))`).bind(communityID(id)).first<CommunityPost>();
  if(!post)throw new APIError(404,'community_not_found','Reported clip not found.');
  return post;
}
export async function moderateCommunityPost(db:D1Database,id:string,moderator:CommunityViewer,body:Record<string,unknown>,now=nowSeconds()) {
  if(body.action!=='hide'&&body.action!=='restore')throw new APIError(400,'community_invalid_moderation','Choose hide or restore.');
  const reason=text(body.reason??'','moderation reason',1000);
  // Moderators may act on public work or previously reported/held work only.
  const post=await db.prepare(`SELECT * FROM community_posts WHERE id=? AND deleted_at IS NULL AND ((status='published' AND media_state='ready') OR moderation_hold=1 OR EXISTS(SELECT 1 FROM community_reports WHERE post_id=community_posts.id))`).bind(communityID(id)).first<CommunityPost>();
  if(!post)throw new APIError(404,'community_not_found','Clip not found.');
  await db.prepare('UPDATE community_posts SET moderation_hold=?,moderation_reason=?,moderated_at=?,moderated_by=?,updated_at=? WHERE id=? AND deleted_at IS NULL')
    .bind(body.action==='hide'?1:0,reason||null,now,moderator.id,now,id).run();
  // Restore never changes the author's publication choice.
  const updated=await db.prepare('SELECT * FROM community_posts WHERE id=? AND deleted_at IS NULL').bind(id).first<CommunityPost>();
  if(!updated)throw new APIError(404,'community_not_found','Clip not found.');
  return updated;
}
export async function listCommunityReports(db:D1Database) {
  const rows=await db.prepare(`SELECT r.id AS report_id,r.reason AS report_reason,r.details AS report_details,r.created_at AS report_created_at,p.* FROM community_reports r JOIN community_posts p ON p.id=r.post_id WHERE p.deleted_at IS NULL ORDER BY r.created_at DESC,r.id DESC LIMIT 100`).all<CommunityPost&{report_id:string;report_reason:string;report_details:string;report_created_at:number}>();
  return {reports:rows.results.map(row=>({id:row.report_id,reason:row.report_reason,details:row.report_details,createdAt:row.report_created_at,item:communityItem(row,undefined,true)})),nextCursor:null};
}
