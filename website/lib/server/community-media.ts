import {APIError, nowSeconds} from './primitives';
import {communityID, getCommunityPost, type CommunityViewer, type CommunityPost} from './community';

function hasVideoSignature(prefix: Uint8Array, mime: string, expected: number) {
  if (mime === 'video/mp4') {
    if (prefix.length < 12 || new TextDecoder().decode(prefix.subarray(4,8)) !== 'ftyp') return false;
    const boxSize = new DataView(prefix.buffer,prefix.byteOffset,4).getUint32(0);
    return boxSize >= 12 && boxSize <= expected;
  }
  return prefix.length >= 16 && prefix[0] === 0x1a && prefix[1] === 0x45 && prefix[2] === 0xdf && prefix[3] === 0xa3
    && new TextDecoder().decode(prefix).includes('webm');
}
/** Streams bounded video bytes. Only a small header is buffered for sniffing. */
export function verifiedVideoStream(body: ReadableStream<Uint8Array>, mime: string, expected: number) {
  let total = 0, checked = false, held: Uint8Array[] = [], headerBytes = 0;
  const header = new Uint8Array(Math.min(4096,expected));
  return body.pipeThrough(new TransformStream<Uint8Array,Uint8Array>({
    transform(chunk,controller) {
      total += chunk.byteLength;
      if (total > expected) throw new APIError(413,'community_size_mismatch','The uploaded video is larger than declared.');
      if (checked) { controller.enqueue(chunk); return; }
      held.push(chunk);
      const length = Math.min(chunk.byteLength,header.length - headerBytes);
      header.set(chunk.subarray(0,length),headerBytes);headerBytes += length;
      if (headerBytes === header.length) {
        if (!hasVideoSignature(header,mime,expected)) throw new APIError(415,'community_invalid_video','The file does not match its video format.');
        checked = true; for (const bytes of held) controller.enqueue(bytes); held = [];
      }
    },
    flush() {
      if (total !== expected || !checked) throw new APIError(400,'community_size_mismatch','The upload was incomplete. Please retry.');
    },
  }));
}
function headerSize(request: Request, expected: number) {
  const raw = request.headers.get('content-length');
  if (raw && (!/^\d+$/.test(raw) || Number(raw) !== expected)) throw new APIError(400,'community_size_mismatch','The upload size does not match the selected file.');
}
export async function uploadCommunityVideo(db: D1Database,bucket: R2Bucket,id: string,viewer: CommunityViewer,request: Request,
  fixedStream: (size: number)=>{readable: ReadableStream<Uint8Array>; writable: WritableStream<Uint8Array>} = size=>new FixedLengthStream(size), now = nowSeconds()) {
  const post = await getCommunityPost(db,id,viewer.id,true);
  if (post.status !== 'draft' || post.media_state === 'ready') throw new APIError(409,'community_upload_locked','Create a new draft to upload another video.');
  if (request.headers.get('content-type')?.split(';')[0].toLowerCase() !== post.mime_type || request.headers.has('content-encoding')) throw new APIError(415,'community_video_required','Upload the selected MP4 or WebM without encoding.');
  if (!request.body) throw new APIError(400,'community_upload_required','Select a video to upload.');
  headerSize(request,post.size_bytes);
  const token=crypto.randomUUID(), key=`community/${id}/${token}.${post.mime_type === 'video/mp4' ? 'mp4' : 'webm'}`;
  const locked = await db.prepare(`UPDATE community_posts SET media_state='uploading',upload_token=?,upload_expires_at=?,updated_at=? WHERE id=? AND owner_id=? AND status='draft' AND deleted_at IS NULL AND (media_state IN ('pending','failed') OR (media_state='uploading' AND upload_expires_at<=?))`)
    .bind(token,now+900,now,id,viewer.id,now).run();
  if (locked.meta.changes !== 1) throw new APIError(409,'community_upload_in_progress','This clip is already uploading.');
  const abort = new AbortController();
  const cancel = () => abort.abort();
  request.signal.addEventListener('abort',cancel,{once:true});
  if(request.signal.aborted)cancel();
  let pending: Promise<unknown>[] = [];
  try {
    const bounded = verifiedVideoStream(request.body,post.mime_type,post.size_bytes), fixed = fixedStream(post.size_bytes);
    const pump = bounded.pipeTo(fixed.writable,{signal:abort.signal});
    pending=[pump];
    const stored = bucket.put(key,fixed.readable,{httpMetadata:{contentType:post.mime_type},customMetadata:{postId:id}});
    pending.push(stored);
    const [,object]=await Promise.all(pending);
    if(!object)throw new APIError(503,'community_storage_unavailable','The upload could not be saved. Please retry.');
    abort.signal.throwIfAborted();
    const committed = await db.prepare(`UPDATE community_posts SET object_key=?,media_state='ready',uploaded_at=?,updated_at=?,upload_token=NULL,upload_expires_at=NULL WHERE id=? AND owner_id=? AND upload_token=? AND status='draft' AND deleted_at IS NULL`)
      .bind(key,now,now,id,viewer.id,token).run();
    if (committed.meta.changes !== 1) throw new APIError(409,'community_upload_cancelled','The draft changed or was deleted during upload.');
    return getCommunityPost(db,id,viewer.id,true);
  } catch (error) {
    abort.abort();
    // R2 may finish asynchronously. Settle writes before deleting the attempt.
    await Promise.allSettled(pending);
    await bucket.delete(key).catch(()=>{});
    await db.prepare(`UPDATE community_posts SET media_state='failed',upload_token=NULL,upload_expires_at=NULL WHERE id=? AND owner_id=? AND upload_token=?`).bind(id,viewer.id,token).run();
    throw error;
  } finally {request.signal.removeEventListener('abort',cancel);}
}
async function boundedBinary(request: Request,max: number) {
  const length=request.headers.get('content-length');
  if (length && (!/^\d+$/.test(length) || Number(length)>max)) throw new APIError(413,'community_poster_too_large','Use a JPEG thumbnail up to 512 KB.');
  const reader=request.body?.getReader();if(!reader)throw new APIError(400,'community_poster_required','Select a JPEG thumbnail.');
  const parts: Uint8Array[]=[];let size=0;
  try { while(true){const {done,value}=await reader.read();if(done)break;size+=value.byteLength;
    if(size>max){await reader.cancel();throw new APIError(413,'community_poster_too_large','Use a JPEG thumbnail up to 512 KB.');}parts.push(value);}
  } finally {reader.releaseLock();}
  const bytes=new Uint8Array(size);let offset=0;for(const part of parts){bytes.set(part,offset);offset+=part.byteLength;}return bytes;
}
export async function uploadCommunityPoster(db: D1Database,bucket: R2Bucket,id: string,viewer: CommunityViewer,request: Request,now=nowSeconds()) {
  const post=await getCommunityPost(db,id,viewer.id,true);
  if(post.status!=='draft')throw new APIError(409,'community_upload_locked','Unpublish this clip before changing its thumbnail.');
  if(request.headers.get('content-type')?.split(';')[0].toLowerCase()!=='image/jpeg'||request.headers.has('content-encoding'))throw new APIError(415,'community_jpeg_required','Use a JPEG thumbnail.');
  const token=crypto.randomUUID(),key=`community/${id}/poster-${token}.jpg`;
  const lock=await db.prepare(`UPDATE community_posts SET poster_token=?,poster_expires_at=? WHERE id=? AND owner_id=? AND status='draft' AND deleted_at IS NULL AND (poster_token IS NULL OR poster_expires_at<=?) RETURNING poster_key`).bind(token,now+120,id,viewer.id,now).first<{poster_key:string|null}>();
  if(!lock)throw new APIError(409,'community_upload_in_progress','The thumbnail is already uploading.');
  try {
    const bytes=await boundedBinary(request,512*1024);
    if(bytes.length<4||bytes[0]!==0xff||bytes[1]!==0xd8||bytes[2]!==0xff||bytes.at(-2)!==0xff||bytes.at(-1)!==0xd9)throw new APIError(415,'community_jpeg_required','The thumbnail is not a JPEG image.');
    request.signal.throwIfAborted();
    await bucket.put(key,bytes,{httpMetadata:{contentType:'image/jpeg'},customMetadata:{postId:id}});
    request.signal.throwIfAborted();
    const commit=await db.prepare(`UPDATE community_posts SET poster_key=?,poster_bytes=?,poster_token=NULL,poster_expires_at=NULL,updated_at=? WHERE id=? AND owner_id=? AND poster_token=? AND status='draft' AND deleted_at IS NULL`).bind(key,bytes.length,now,id,viewer.id,token).run();
    if(commit.meta.changes!==1)throw new APIError(409,'community_upload_cancelled','The draft changed during thumbnail upload.');
    // Another replacement may finish between our initial read and this lock.
    // Delete the predecessor captured atomically with acquisition, not that stale read.
    if(lock.poster_key)await bucket.delete(lock.poster_key).catch(()=>{});
    return getCommunityPost(db,id,viewer.id,true);
  } catch(error){
    await bucket.delete(key).catch(()=>{});
    await db.prepare('UPDATE community_posts SET poster_token=NULL,poster_expires_at=NULL WHERE id=? AND owner_id=? AND poster_token=?').bind(id,viewer.id,token).run();throw error;
  }
}
export async function deleteCommunityPost(db: D1Database,bucket: R2Bucket,id: string,viewer: CommunityViewer,now=nowSeconds()) {
  // Repeated deletes after a storage failure can finish cleanup, but other
  // users never learn whether a private or deleted record exists.
  const post=await db.prepare("UPDATE community_posts SET status='draft',deleted_at=?,updated_at=? WHERE id=? AND owner_id=? RETURNING *").bind(now,now,communityID(id),viewer.id).first<CommunityPost>();
  if(!post)return;
  const keys=[post.object_key,post.poster_key].filter((key):key is string=>!!key);
  if(keys.length)await bucket.delete(keys);
  await db.prepare('DELETE FROM community_posts WHERE id=? AND owner_id=? AND deleted_at IS NOT NULL').bind(id,viewer.id).run();
}
export function mediaRange(value: string | null,size: number) {
  if(!value)return null;
  const match=/^bytes=(\d*)-(\d*)$/.exec(value);
  if(!match||(!match[1]&&!match[2]))throw new APIError(416,'community_invalid_range','Invalid byte range.');
  if(match.slice(1).some(part=>part!==''&&!Number.isSafeInteger(Number(part))))throw new APIError(416,'community_invalid_range','Invalid byte range.');
  const start=match[1]?Number(match[1]):Math.max(0,size-Number(match[2]));
  const end=match[1]?(match[2]?Math.min(size-1,Number(match[2])):size-1):size-1;
  if(!Number.isSafeInteger(start)||!Number.isSafeInteger(end)||start<0||start>=size||end<start||(!match[1]&&Number(match[2])<=0))throw new APIError(416,'community_invalid_range','Invalid byte range.');
  return {offset:start,length:end-start+1};
}
export async function communityMediaResponse(db: D1Database,bucket: R2Bucket,id: string,viewerId: string|undefined,request: Request,poster=false) {
  const post=await getCommunityPost(db,id,viewerId);
  const key=poster?post.poster_key:post.media_state==='ready'?post.object_key:null;
  if(!key)throw new APIError(404,'community_media_not_found','Media not found.');
  const head=await bucket.head(key);
  if(!head||head.size!==(poster?post.poster_bytes:post.size_bytes))throw new APIError(503,'community_media_unavailable','This media is temporarily unavailable.');
  const headers=new Headers({'Content-Type':poster?'image/jpeg':post.mime_type,'Accept-Ranges':'bytes','Cache-Control':'private, no-store','X-Content-Type-Options':'nosniff','Cross-Origin-Resource-Policy':'same-origin','ETag':head.httpEtag});
  const download=new URL(request.url).searchParams.get('download')==='1';
  const name=(poster?`focus-${id}.jpg`:post.filename).replace(/[^a-zA-Z0-9._-]/g,'_');
  headers.set('Content-Disposition',`${download?'attachment':'inline'}; filename="${name}"`);
  let range:ReturnType<typeof mediaRange>;
  try{range=mediaRange(request.headers.has('if-range')&&request.headers.get('if-range')!==head.httpEtag?null:request.headers.get('range'),head.size);}
  catch(error){if(error instanceof APIError&&error.status===416){headers.set('Content-Range',`bytes */${head.size}`);headers.delete('Content-Disposition');return new Response(null,{status:416,headers});}throw error;}
  headers.set('Content-Length',String(range?.length??head.size));
  if(range)headers.set('Content-Range',`bytes ${range.offset}-${range.offset+range.length-1}/${head.size}`);
  const status=range?206:200;
  if(request.method==='HEAD')return new Response(null,{status,headers});
  const object=await bucket.get(key,range?{range}:undefined);
  if(!object)throw new APIError(503,'community_media_unavailable','This media is temporarily unavailable.');
  return new Response(object.body,{status,headers});
}
