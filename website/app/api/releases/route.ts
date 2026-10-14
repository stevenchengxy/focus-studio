import { releaseCatalog, releaseOptions, selectRelease } from '@/lib/releases';

export async function GET(request: Request) {
  const options = releaseOptions(new URL(request.url));
  if (!options) return Response.json({ error: 'Invalid platform or update channel' }, { status: 400 });
  try {
    const release = selectRelease(await releaseCatalog(), options.platform, options.channel, options.version, options.releaseTag, options.filename);
    if (!release) return Response.json({ error: 'No installer published for this channel' }, { status: 404 });
    return Response.json(release.info, { headers: { 'Cache-Control': 'public, max-age=300', 'X-Content-Type-Options': 'nosniff' } });
  } catch {
    return Response.json({ error: 'Update service temporarily unavailable. Please retry later.' }, { status: 503, headers: { 'Cache-Control': 'no-store' } });
  }
}
