import {access} from 'node:fs/promises';
import {createRequire} from 'node:module';
import http from 'node:http';
import path from 'node:path';
import {fileURLToPath, pathToFileURL} from 'node:url';

// Optionally point at another local copy containing the same completed build.
const siteRoot = path.resolve(process.argv[2] || fileURLToPath(new URL('../', import.meta.url)));
const config = path.join(siteRoot, 'dist/server/wrangler.json');
await access(config).catch(() => { throw new Error('Build the website and apply its local D1 migrations before running this check.'); });
await import(pathToFileURL(path.join(siteRoot, 'scripts/sites-env.mjs')).href);
const require = createRequire(path.join(siteRoot, 'package.json'));
const {unstable_DevEnv} = require('wrangler');
const runtime = new unstable_DevEnv();
let proxyData;
let resolveLoaded;
const loaded = new Promise(resolve => { resolveLoaded = resolve; });
runtime.on('reloadComplete', event => {
  proxyData = event.proxyData;
  resolveLoaded();
});

const originalFetch = globalThis.fetch;
const originalOrigin = process.env.COMMUNITY_TEST_ORIGIN;
let worker;
let startupTimeout;
try {
  worker = await runtime.startWorker({
    config, sendMetrics: false,
    dev: {
      remote: false, watch: false, liveReload: false, inspector: false,
      persist: path.join(siteRoot, '.wrangler/state'), logLevel: 'error',
      server: {hostname: '127.0.0.1', port: 0},
    },
  });
  await Promise.race([
    Promise.all([worker.ready, loaded]),
    new Promise((_, reject) => {
      startupTimeout = setTimeout(() => reject(new Error('The local built Worker did not become ready within 30 seconds.')), 30000);
    }),
  ]);
  clearTimeout(startupTimeout);
  const publicURL = await worker.url;
  const directURL = new URL('http://127.0.0.1');
  Object.assign(directURL, proxyData.userWorkerUrl);
  for (const url of [publicURL, directURL]) {
    if (url.protocol !== 'http:' || !['127.0.0.1', 'localhost'].includes(url.hostname)) {
      throw new Error('This check only supports a local HTTP Worker.');
    }
  }
  process.env.COMMUNITY_TEST_ORIGIN = publicURL.origin;
  globalThis.fetch = (input, init = {}) => {
    const originalURL = new URL(typeof input === 'string' || input instanceof URL ? input : input.url);
    if (originalURL.origin !== publicURL.origin) throw new Error('Only requests to this local test Worker are allowed.');
    const destination = new URL(originalURL);
    Object.assign(destination, proxyData.userWorkerUrl);
    const headers = new Headers(init.headers);
    // Preserve Wrangler's local worker authentication without exposing it in
    // logs or files. Application identity and authorization checks still run.
    for (const [key, value] of Object.entries(proxyData.headers)) headers.set(key, value);
    headers.set('MF-Original-URL', originalURL.href);
    const body = init.body === undefined || init.body === null ? undefined : Buffer.from(init.body);
    if (body) headers.set('Content-Length', String(body.byteLength));
    // Independent sockets also avoid reusing a connection closed after an
    // early upload rejection. The complete response is read before returning.
    return new Promise((resolve, reject) => {
      const request = http.request(destination, {
        method: init.method || 'GET', headers: Object.fromEntries(headers),
        agent: false, signal: init.signal,
      }, response => {
        const chunks = [];
        response.on('data', chunk => chunks.push(chunk));
        response.on('error', reject);
        response.on('end', () => {
          const responseHeaders = new Headers();
          for (let index = 0; index < response.rawHeaders.length; index += 2) {
            responseHeaders.append(response.rawHeaders[index], response.rawHeaders[index + 1]);
          }
          const status = response.statusCode || 500;
          resolve(new Response([204, 205, 304].includes(status) ? null : Buffer.concat(chunks), {status, headers: responseHeaders}));
        });
      });
      request.setTimeout(30000, () => request.destroy(new Error('The direct Worker request timed out.')));
      request.on('error', reject);
      request.end(body);
    });
  };
  console.log('Testing the built Worker directly over loopback HTTP; bypassing Wrangler ProxyWorker, with no retries.');
  await import('./verify-community-local.mjs');
} finally {
  clearTimeout(startupTimeout);
  globalThis.fetch = originalFetch;
  if (originalOrigin === undefined) delete process.env.COMMUNITY_TEST_ORIGIN;
  else process.env.COMMUNITY_TEST_ORIGIN = originalOrigin;
  if (worker) await worker.dispose();
  else await runtime.teardown();
}
