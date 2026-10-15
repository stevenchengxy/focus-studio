import { billingConfigured, json, settings } from '@/lib/server/runtime';
import { googleConfigured } from '@/lib/server/google-auth';
import { installerPath } from '@/lib/installers';
import { safePublicUrl } from '@/lib/server/primitives';
export async function GET() {
  const e = settings();
  return json({ billingConfigured: billingConfigured(), googleConfigured: googleConfigured(e), macDownloadUrl: installerPath('mac'), windowsDownloadUrl: installerPath('windows'), linuxDownloadUrl: installerPath('linux'), demoVideoUrl: safePublicUrl(e.DEMO_VIDEO_URL) ?? '/media/focus-studio-demo.mp4', demoPosterUrl: safePublicUrl(e.DEMO_POSTER_URL) ?? '/media/focus-studio-demo.jpg' });
}
