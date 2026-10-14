import { settings } from '@/lib/server/runtime';
import { installerResponse } from '@/lib/installers';

export async function GET(request: Request, context: { params: Promise<{ platform: string }> }) {
  const { platform } = await context.params;
  const env = settings();
  const configured = platform === 'mac' ? env.MAC_DOWNLOAD_URL : platform === 'windows' ? env.WINDOWS_DOWNLOAD_URL : env.LINUX_DOWNLOAD_URL;
  return installerResponse(request, platform, configured);
}
export const HEAD = GET;
