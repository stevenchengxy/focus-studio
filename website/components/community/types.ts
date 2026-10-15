export type CommunityItem = {
  id: string; title: string; description: string; caption?: string; productUrl: string | null;
  category: 'demo' | 'ai-video'; authorName: string; status: 'draft' | 'published';
  mimeType: string; sizeBytes: number; mediaUrl: string | null; downloadUrl: string | null;
  posterUrl?: string | null; license: string | null; publishedAt: number | null;
  createdAt: number; updatedAt: number; isOwner: boolean; hasMedia?: boolean; uploaded?: boolean; moderationHold?: boolean; moderationReason?: string;
};
export type CommunityIdentity = { authenticated: boolean; viewerName?: string; displayName?: string|null; canPublish: boolean; clientConfirmed: boolean };
export const signInPath = (returnTo: string) => `/signin-with-chatgpt?return_to=${encodeURIComponent(returnTo)}`;
export class CommunityError extends Error { constructor(public code: string, message: string) { super(message); } }
export async function communityRequest<T>(path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(path, { cache: 'no-store', ...init });
  const data = await response.json() as T & {error?:{code?:string;message?:string}};
  if (!response.ok) throw new CommunityError(data.error?.code || 'request_failed', data.error?.message || 'Please try again.');
  return data as T;
}
export function errorCopy(error: unknown, t: (en:string,zh:string)=>string) {
  const code = error instanceof CommunityError ? error.code : '';
  if (code === 'community_client_required') return t('Open the installed Focus Studio app and connect this ChatGPT account before uploading or publishing.', '请先打开安装好的 Focus Studio，在“社区发布”中连接当前 ChatGPT 账户，再上传或发布。');
  if (/auth|sign_in|identity/.test(code)) return t('Sign in with ChatGPT to continue.', '请先使用 ChatGPT 登录。');
  if (/moderator_required/.test(code)) return t('This page is for community moderators.', '此页面仅供社区管理员访问。');
  if (/moderation|hold/.test(code)) return t('This video is under review and cannot be published.', '此视频正在审核，暂时无法发布。');
  if (/invalid_profile/.test(code)) return t('Choose a creator name between 1 and 64 characters.', '请输入 1–64 个字符的创作者昵称。');
  if (/public_name/.test(code)) return t('Choose a public creator name instead of an email address.', '请使用公开的创作者名称，不要填写邮箱。');
  if (/url/.test(code)) return t('Enter an HTTPS product link.', '请填写以 https:// 开头的产品链接。');
  if (/metadata/.test(code)) return t('Check the title and creator name. Titles can contain up to 100 characters.', '请检查标题与创作者名称，标题最多 100 个字符。');
  if (/quota|limit|many/.test(code)) return t('Your upload limit has been reached. Remove an old draft or try again later.', '已达到上传额度，请删除旧草稿或稍后重试。');
  if (/large/.test(code)) return t('Choose a video smaller than 100 MB.', '请选择小于 100 MB 的视频。');
  if (/media|type|video|file/.test(code)) return t('Use a valid MP4 or WebM video.', '请选择有效的 MP4 或 WebM 视频。');
  if (/rights|license/.test(code)) return t('Confirm that you can share this video under the reuse license.', '请确认你有权按照所示许可分享此视频。');
  if (/not_found/.test(code)) return t('This work is unavailable or is no longer shared.', '该作品不可用或已取消发布。');
  if (error instanceof CommunityError && t('en','zh') === 'en') return error.message;
  return t('We could not complete that action. Your local video is unchanged. Please try again.', '操作未完成，本地视频不受影响，请重试。');
}
