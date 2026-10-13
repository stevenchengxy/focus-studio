import { billingConfigured, json, settings } from '@/lib/server/runtime';
import { googleConfigured } from '@/lib/server/google-auth';
import { safePublicUrl } from '@/lib/server/primitives';
export async function GET() {
  const e = settings();
  return json({ billingConfigured: billingConfigured(), googleConfigured: googleConfigured(e), macDownloadUrl: safePublicUrl(e.MAC_DOWNLOAD_URL), windowsDownloadUrl: safePublicUrl(e.WINDOWS_DOWNLOAD_URL), linuxDownloadUrl: safePublicUrl(e.LINUX_DOWNLOAD_URL), demoVideoUrl: safePublicUrl(e.DEMO_VIDEO_URL) ?? '/media/focus-studio-demo.mp4', demoPosterUrl: safePublicUrl(e.DEMO_POSTER_URL) ?? '/media/focus-studio-demo.jpg' });
}
