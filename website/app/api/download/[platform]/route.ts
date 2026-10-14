import { settings } from '@/lib/server/runtime';
import { installerResponse } from '@/lib/installers';
import { releaseCatalog, releaseOptions, selectRelease } from '@/lib/releases';

export async function GET(request: Request, context: { params: Promise<{ platform: string }> }) {
  const { platform } = await context.params;
  const url = new URL(request.url);
  url.searchParams.set('platform', platform);
  const options = releaseOptions(url);
  if (!options) return new Response('Unknown platform or channel', { status: 400 });
  try {
    const latest = selectRelease(await releaseCatalog(), options.platform, options.channel, options.version, options.releaseTag, options.filename);
    if (latest) {
      if (!options.releaseTag || !options.filename) {
        const pinned = new URL(latest.pinnedURL);
        pinned.protocol = url.protocol;
        pinned.host = url.host;
        // A generic URL can resolve to a different release after publication.
        // Never append its bytes to an older partial download without identity.
        if (request.headers.has('range')) return new Response('Resume using the original versioned download link, or restart this download.', {
          status: 409, headers: { 'Cache-Control': 'no-store', 'Location': pinned.href },
        });
        return new Response(null, { status: 307, headers: { 'Location': pinned.href, 'Cache-Control': 'no-store' } });
      }
      return installerResponse(request, platform, latest.assetURL);
    }
    if (options.channel === 'stable' || options.version || options.releaseTag) return new Response('No matching installer published', { status: 404 });
  } catch {
    if (options.channel === 'stable' || options.version || options.releaseTag) return new Response('Installer catalog temporarily unavailable', { status: 503 });
  }
  // Preview-only fallback keeps a verified installer reachable during API outages.
  if (request.headers.has('range')) return new Response('Restart the download after the release catalog becomes available.', {
    status: 503, headers: { 'Cache-Control': 'no-store' },
  });
  const env = settings();
  const configured = platform === 'mac' ? env.MAC_DOWNLOAD_URL : platform === 'windows' ? env.WINDOWS_DOWNLOAD_URL : env.LINUX_DOWNLOAD_URL;
  return installerResponse(request, platform, configured);
}
export const HEAD = GET;
