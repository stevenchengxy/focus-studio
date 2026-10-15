export type InstallerPlatform = 'mac' | 'windows' | 'linux';

// Verified release assets. Never fall back to GitHub's source-code archives.
export const INSTALLERS = {
  mac: { label: 'macOS', format: 'DMG', suffix: '.dmg', mime: 'application/x-apple-diskimage', url: 'https://github.com/stevenchengxy/focus-studio/releases/download/v1.14.6-preview.1/Focus-Studio-1.14.6-universal-local.dmg' },
  windows: { label: 'Windows', format: 'EXE installer', suffix: '.exe', mime: 'application/vnd.microsoft.portable-executable', url: 'https://github.com/stevenchengxy/focus-studio/releases/download/v1.14.6-preview.1/Focus-Studio-Desktop-0.1.3-windows-x64.exe' },
  linux: { label: 'Linux', format: 'AppImage', suffix: '.AppImage', mime: 'application/octet-stream', url: 'https://github.com/stevenchengxy/focus-studio/releases/download/v1.14.6-preview.1/Focus-Studio-Desktop-0.1.3-linux-x86_64.AppImage' },
} as const;

export function installerFor(platform: string, configured?: string) {
  if (!Object.hasOwn(INSTALLERS, platform)) return null;
  const installer = INSTALLERS[platform as InstallerPlatform];
  let url = installer.url as string;
  if (configured) {
    try {
      const candidate = new URL(configured);
      // Download proxy accepts only our published GitHub assets, never arbitrary URLs.
      if (candidate.protocol === 'https:' && candidate.hostname === 'github.com' && !candidate.username && !candidate.password &&
          candidate.pathname.startsWith('/stevenchengxy/focus-studio/releases/download/') &&
          candidate.pathname.endsWith(installer.suffix)) { decodeURIComponent(candidate.pathname); url = candidate.href; }
    } catch { /* use the verified installer */ }
  }
  return { ...installer, url, filename: decodeURIComponent(new URL(url).pathname.split('/').at(-1)!) };
}

export const installerPath = (platform: InstallerPlatform) => `/api/download/${platform}`;

export async function installerResponse(request: Request, platform: string, configured?: string, fetcher: typeof fetch = fetch): Promise<Response> {
  const installer = installerFor(platform, configured);
  if (!installer) return new Response('Unknown platform', { status: 404 });
  const requestHeaders = new Headers({ Accept: 'application/octet-stream', 'User-Agent': 'Focus-Studio-Downloads' });
  const range = request.headers.get('range');
  const validRange = range && /^bytes=(?:\d+-\d*|-\d+)$/.test(range);
  if (validRange) requestHeaders.set('Range', range);
  const ifRange = request.headers.get('if-range');
  if (validRange && ifRange) requestHeaders.set('If-Range', ifRange);
  try {
    const response = await fetcher(installer.url, { method: request.method === 'HEAD' ? 'HEAD' : 'GET', headers: requestHeaders, redirect: 'follow' });
    if (response.status === 416) {
      await response.body?.cancel();
      const headers = new Headers({ 'Cache-Control': 'no-store', 'Accept-Ranges': 'bytes' });
      const contentRange = response.headers.get('content-range');
      if (contentRange && /^bytes \*\/\d+$/.test(contentRange)) headers.set('Content-Range', contentRange);
      const etag = response.headers.get('etag');
      if (etag) headers.set('ETag', etag);
      return new Response(null, { status: 416, headers });
    }
    const type = response.headers.get('content-type') || '';
    if ((response.status !== 200 && response.status !== 206) || /text\/|json|xml/i.test(type) || (request.method !== 'HEAD' && !response.body)) {
      await response.body?.cancel();
      throw new Error('Installer unavailable');
    }
    const headers = new Headers({
      'Content-Type': installer.mime,
      'Content-Disposition': `attachment; filename="${installer.filename.replace(/[^a-zA-Z0-9._-]/g, '_')}"`,
      'X-Content-Type-Options': 'nosniff',
      'Cache-Control': 'no-store',
      'Accept-Ranges': 'bytes',
    });
    for (const key of ['content-length', 'content-range', 'etag']) {
      const value = response.headers.get(key);
      if (value) headers.set(key, value);
    }
    // Stream the file: installers exceed the worker's available buffering memory.
    return new Response(request.method === 'HEAD' ? null : response.body, { status: response.status, headers });
  } catch {
    // An upstream error page must never be saved with an installer extension.
    return new Response('<!doctype html><meta charset="utf-8"><title>Download unavailable</title><h1>Please retry the download</h1><p>The installer server is temporarily unavailable.</p><p><a href="/">Return to Focus Studio</a></p>', { status: 503, headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' } });
  }
}
