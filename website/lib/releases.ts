export type ReleasePlatform = 'mac' | 'windows' | 'linux';
export type ReleaseChannel = 'stable' | 'preview';
const ORIGIN = 'https://focus-studio.stevenchengxy19.chatgpt.site';
const REPO = 'https://github.com/stevenchengxy/focus-studio';
const CATALOG = 'https://raw.githubusercontent.com/stevenchengxy/focus-studio/release-feed/releases.json';
const API = 'https://api.github.com/repos/stevenchengxy/focus-studio/releases?per_page=100';

type Asset = { name: string; browser_download_url: string; state: string; size: number };
type GithubRelease = { draft: boolean; prerelease: boolean; name: string; published_at: string; html_url: string; assets: Asset[] };
export type ReleaseInfo = {
  platform: ReleasePlatform; version: string; channel: ReleaseChannel; title: string;
  published_at: string; download_url: string; release_url: string; minimum_os: string | null;
};
export function compareVersions(a: string, b: string): number {
  const left = a.split('.').map(Number), right = b.split('.').map(Number);
  for (let i = 0; i < 3; i++) { if (left[i] !== right[i]) return left[i] - right[i]; }
  return 0;
}
export function selectRelease(data: unknown, platform: ReleasePlatform, channel: ReleaseChannel, version?: string, releaseTag?: string, filename?: string) {
  if (!Array.isArray(data)) throw new Error('Invalid release catalog');
  const pattern = platform === 'mac' ? /^Focus-Studio-(\d+\.\d+\.\d+)-universal-(?:notarized|developer-id|local)\.dmg$/
    : platform === 'windows' ? /^Focus-Studio-Desktop-(\d+\.\d+\.\d+)-windows-x64\.exe$/
    : /^Focus-Studio-Desktop-(\d+\.\d+\.\d+)-linux-x86_64\.AppImage$/;
  const candidates: { info: ReleaseInfo; assetURL: string; pinnedURL: string }[] = [];
  for (const release of data as GithubRelease[]) {
    if (!release || typeof release !== 'object') continue;
    if (release.draft !== false || typeof release.prerelease !== 'boolean' ||
        (channel === 'stable' && release.prerelease) || !Array.isArray(release.assets) ||
        (typeof release.html_url !== 'string' || !release.html_url.startsWith(REPO + '/releases/tag/')) || !Number.isFinite(Date.parse(release.published_at))) continue;
    for (const asset of release.assets) {
      if (!asset || typeof asset.name !== 'string') continue;
      const match = pattern.exec(asset.name);
      if (!match || asset.state !== 'uploaded' || !(asset.size > 0) || (version && match[1] !== version)) continue;
      let url: URL;
      try { url = new URL(asset.browser_download_url); } catch { continue; }
      if (url.origin !== 'https://github.com' || url.username || url.password || url.search || url.hash ||
          !url.pathname.startsWith('/stevenchengxy/focus-studio/releases/download/') ||
          url.pathname.split('/').at(-1) !== asset.name) continue;
      const tag = url.pathname.split('/').at(-2)!;
      if ((releaseTag && tag !== releaseTag) || (filename && asset.name !== filename)) continue;
      const identity = new URLSearchParams({ channel, version: match[1], release: tag, asset: asset.name });
      candidates.push({ assetURL: url.href, pinnedURL: `${ORIGIN}/api/download/${platform}?${identity}`, info: {
        platform, version: match[1], channel: release.prerelease ? 'preview' : 'stable',
        title: String(release.name || 'Focus Studio').slice(0, 200), published_at: release.published_at,
        download_url: `${ORIGIN}/api/download/${platform}?channel=${channel}&version=${match[1]}`,
        release_url: release.html_url, minimum_os: platform === 'mac' ? '15.0' : null,
      } });
    }
  }
  candidates.sort((a, b) => compareVersions(b.info.version, a.info.version) ||
    (Number(a.info.channel === 'preview') - Number(b.info.channel === 'preview')) ||
    Date.parse(b.info.published_at) - Date.parse(a.info.published_at));
  return candidates[0] ?? null;
}

let cached: { expires: number; data: unknown } | undefined;
export async function releaseCatalog(fetcher: typeof fetch = fetch): Promise<unknown> {
  if (cached && cached.expires > Date.now()) return cached.data;
  // This public feed is maintained after verified publication. Unlike the REST
  // API, its CDN does not share GitHub's anonymous API quota with other Workers.
  // Only parsed JSON crosses request contexts; never share in-flight fetch IO.
  let status: number | undefined;
  let remaining: string | null = null;
  let source = 'release-feed';
  const request = (url: string) => fetcher(url, {
    headers: { Accept: 'application/json', 'User-Agent': 'Focus-Studio-Updates' },
    signal: AbortSignal.timeout(10000),
    cf: { cacheTtl: 300, cacheEverything: true, cacheTtlByStatus: { '200-299': 300, '400-599': 0 } },
  } as RequestInit);
  try {
    let response = await request(CATALOG);
    // Compatibility for the first deployment before the release-feed branch
    // exists. Network/format failures do not silently select a stale catalog.
    if (response.status === 404) {
      await response.body?.cancel();
      source = 'github-api-bootstrap';
      console.warn('Focus Studio release feed not published; checking GitHub API');
      response = await request(API);
    }
    status = response.status;
    remaining = response.headers.get('x-ratelimit-remaining');
    if (!response.ok) {
      await response.body?.cancel();
      throw new Error('Release service HTTP ' + status);
    }
    const reader = response.body?.getReader();
    if (!reader) throw new Error('Empty release catalog');
    const decoder = new TextDecoder();
    let text = '', bytes = 0;
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        bytes += value.byteLength;
        if (bytes > 4_000_000) {
          await reader.cancel();
          throw new Error('Release catalog too large');
        }
        text += decoder.decode(value, { stream: true });
      }
      text += decoder.decode();
    } finally { reader.releaseLock(); }
    const data: unknown = JSON.parse(text);
    if (!Array.isArray(data)) throw new Error('Invalid release catalog');
    cached = { expires: Date.now() + 300000, data };
    return data;
  } catch (error) {
    // Public endpoints only; never log request headers, bodies or credentials.
    console.error('Focus Studio release catalog unavailable', {
      source, status, remaining,
      error: error instanceof Error ? error.name : typeof error,
      message: error instanceof Error ? error.message.slice(0, 200) : 'Unknown fetch error',
    });
    throw error;
  }
}

export function releaseOptions(url: URL) {
  const platform = url.searchParams.get('platform') || 'mac';
  const channel = url.searchParams.get('channel') || 'preview';
  const version = url.searchParams.get('version') || undefined;
  const releaseTag = url.searchParams.get('release') || undefined;
  const filename = url.searchParams.get('asset') || undefined;
  if (!['mac', 'windows', 'linux'].includes(platform) || !['stable', 'preview'].includes(channel) ||
      (version && !/^\d+\.\d+\.\d+$/.test(version)) ||
      (!!releaseTag !== !!filename) || (releaseTag && !/^v\d+\.\d+\.\d+(?:-preview\.\d+)?$/.test(releaseTag)) ||
      (filename && !/^[a-zA-Z0-9._-]{1,180}$/.test(filename))) return null;
  return { platform: platform as ReleasePlatform, channel: channel as ReleaseChannel, version, releaseTag, filename };
}
