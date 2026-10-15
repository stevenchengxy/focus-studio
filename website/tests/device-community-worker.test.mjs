import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import { Miniflare } from 'miniflare';
import ts from 'typescript';

// Run the production GET/activate/revoke routes, runtime and SQL in workerd/D1.
// Only the trusted Sites identity is a fixture; no deployed accounts or storage.
test('community device identity HTTP contract in real workerd and D1', async t => {
  const modules = [{ type: 'ESModule', path: 'worker.mjs', contents: `
    import {GET as community} from './community-route.mjs';
    import {POST as activate} from './activate-route.mjs';
    import {POST as revoke} from './revoke-route.mjs';
    import {api,authenticate,json} from './runtime.mjs';
    export default {async fetch(request) {
      const path = new URL(request.url).pathname;
      if (path === '/api/device/community' && request.method === 'GET') return community(request);
      if (path === '/api/device/activate' && request.method === 'POST') return activate(request);
      if (path === '/api/device/revoke' && request.method === 'POST') return revoke(request);
      if (path === '/fixture/browser-account') return api(async()=>json(await authenticate(request,true)));
      return new Response('Not found',{status:404});
    }};
  ` }, { type: 'ESModule', path: 'chatgpt-auth.mjs', contents: `
    export async function getChatGPTUser() {return {userId:'owner-b',email:'b@example.invalid'};}
  ` }];
  const serverModules = ['primitives', 'google-auth', 'runtime', 'community-client'];
  const sources = [
    ...serverModules.map(name => [new URL(`../lib/server/${name}.ts`, import.meta.url), `${name}.mjs`]),
    [new URL('../lib/product-access.ts', import.meta.url), 'product-access.mjs'],
    ...['community', 'activate', 'revoke'].map(name => [new URL(`../app/api/device/${name}/route.ts`, import.meta.url), `${name}-route.mjs`]),
  ];
  for (const [source, path] of sources) {
    let contents = ts.transpileModule(await readFile(source, 'utf8'), {
      compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ES2022 },
    }).outputText;
    for (const dependency of serverModules) {
      contents = contents.replaceAll(`'./${dependency}'`, `'./${dependency}.mjs'`)
        .replaceAll(`'@/lib/server/${dependency}'`, `'./${dependency}.mjs'`);
    }
    contents = contents.replaceAll("'../product-access'", "'./product-access.mjs'")
      .replaceAll("'@/app/chatgpt-auth'", "'./chatgpt-auth.mjs'");
    modules.push({ type: 'ESModule', path, contents });
  }
  const origin = 'https://fixture.test';
  const sessionSecret = 'community-device-http-fixture-secret-at-least-32-characters';
  const mf = new Miniflare({ modules, compatibilityDate: '2026-05-15', d1Databases: ['DB'],
    bindings: { SITE_ORIGIN: origin, SESSION_SECRET: sessionSecret } });
  try {
    const db = await mf.getD1Database('DB');
    const sqlDir = new URL('../drizzle/', import.meta.url);
    for (const name of (await readdir(sqlDir)).filter(name => name.endsWith('.sql')).sort()) {
      const sql = await readFile(new URL(name, sqlDir), 'utf8');
      for (const statement of sql.split('--> statement-breakpoint').map(value => value.trim()).filter(Boolean)) {
        await db.prepare(statement).run();
      }
    }
    const now = Math.floor(Date.now() / 1000);
    const hash = async value => Buffer.from(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value))).toString('hex');
    for (const [id, email] of [['owner-a', 'a@example.invalid'], ['owner-b', 'b@example.invalid']]) {
      await db.prepare('INSERT INTO accounts(id,email,created_at) VALUES(?,?,?)').bind(id, email, now).run();
    }
    async function token(id, owner = 'owner-a', purpose = 'community', expiresAt = now + 3600, revokedAt = null) {
      const value = `fs_${await hash(`community-device-test:${id}`)}`;
      await db.prepare('INSERT INTO device_tokens(id,hash,account_id,name,purpose,expires_at,created_at,revoked_at) VALUES(?,?,?,?,?,?,?,?)')
        .bind(id, await hash(value), owner, 'Fixture device', purpose, expiresAt, now, revokedAt).run();
      return value;
    }
    const communityToken = await token('community-a');
    const otherToken = await token('community-b', 'owner-b');
    const accountToken = await token('account-a', 'owner-a', 'account');
    const expiredToken = await token('expired-a', 'owner-a', 'community', now);
    const revokedToken = await token('revoked-a', 'owner-a', 'community', now + 3600, now);
    const cookieSecret = await hash('community-cookie-fixture');
    await db.prepare('INSERT INTO web_sessions(hash,account_id,expires_at) VALUES(?,?,?)')
      .bind(await hash(cookieSecret), 'owner-b', now + 3600).run();
    const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(sessionSecret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
    const signature = Buffer.from(await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(cookieSecret))).toString('base64url');
    const cookie = `__Host-fs-session=${cookieSecret}.${signature}`;
    const get = (authorization, headers = {}, query = '') => mf.dispatchFetch(`${origin}/api/device/community${query}`, {
      headers: { ...(authorization !== null ? { Authorization: authorization } : {}), ...headers },
    });
    const post = (path, value, body = {}) => mf.dispatchFetch(origin + path, {
      method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${value}` }, body: JSON.stringify(body),
    });
    async function result(response, status = 200) {
      assert.equal(response.status, status);
      assert.equal(response.headers.get('Cache-Control'), 'no-store');
      assert.equal(response.headers.get('X-Content-Type-Options'), 'nosniff');
      const text = await response.text();
      for (const secret of [communityToken, otherToken, accountToken, expiredToken, revokedToken, cookieSecret, await hash(communityToken)]) {
        assert.equal(text.includes(secret), false, 'Response must not expose a credential or its hash');
      }
      return JSON.parse(text);
    }
    async function denied(authorization, headers = {}) {
      const data = await result(await get(authorization, headers), 401);
      assert.deepEqual(Object.keys(data), ['error']);
      assert.equal(data.error.code, 'community_device_required');
      assert.equal(typeof data.error.message, 'string');
    }

    await t.test('live unconfirmed bearer returns only its own identity and exact token expiry', async () => {
      const before = await db.prepare('SELECT * FROM device_tokens WHERE id=?').bind('community-a').first();
      assert.deepEqual(await result(await get(`Bearer ${communityToken}`)), {
        purpose: 'community', account: { id: 'owner-a', email: 'a@example.invalid', displayName: null },
        clientConfirmed: false, expiresAt: now + 3600,
      });
      assert.deepEqual(await db.prepare('SELECT * FROM device_tokens WHERE id=?').bind('community-a').first(), before);
      assert.equal((await db.prepare('SELECT count(*) n FROM community_client_activations').first()).n, 0);
    });

    await t.test('confirmation and saved display name appear on the next uncached read', async () => {
      assert.deepEqual(await result(await post('/api/device/activate', communityToken)), { confirmed: true });
      await db.prepare('INSERT INTO community_profiles(owner_id,display_name,created_at,updated_at) VALUES(?,?,?,?)')
        .bind('owner-a', 'Community creator', now, now).run();
      assert.deepEqual(await result(await get(`Bearer ${communityToken}`)), {
        purpose: 'community', account: { id: 'owner-a', email: 'a@example.invalid', displayName: 'Community creator' },
        clientConfirmed: true, expiresAt: now + 3600,
      });
    });

    await t.test('valid browser cookie and Sites identity do not authenticate this endpoint', async () => {
      const browser = await mf.dispatchFetch(`${origin}/fixture/browser-account`, { headers: { Cookie: cookie } });
      assert.equal(browser.status, 200);
      assert.equal((await browser.json()).id, 'owner-b');
      await denied(null, { Cookie: cookie });
      await denied(null, { 'oai-authenticated-user-id': 'owner-a', 'oai-authenticated-user-email': 'a@example.invalid' });
      await denied(`Bearer ${accountToken}`, { Cookie: cookie });
    });

    await t.test('strict bearer syntax, unknown tokens, expired and revoked credentials fail closed', async () => {
      for (const authorization of [null, '', 'Basic credential', 'Bearer fs_invalid',
        `bearer ${communityToken}`, `Bearer ${communityToken.toUpperCase()}`, `Bearer  ${communityToken}`,
        `Bearer fs_${'0'.repeat(63)}`, `Bearer fs_${'0'.repeat(65)}`, `Bearer fs_${'0'.repeat(64)}`,
        `Bearer ${communityToken}, Bearer ${otherToken}`, `Bearer ${expiredToken}`, `Bearer ${revokedToken}`]) {
        await denied(authorization, { Cookie: cookie });
      }
      assert.equal((await db.prepare('SELECT count(*) n FROM community_client_activations').first()).n, 1);
    });

    await t.test('token owner controls account, profile and confirmation despite forged selectors', async () => {
      assert.deepEqual(await result(await get(`Bearer ${otherToken}`, {
        Cookie: cookie, 'X-Owner-ID': 'owner-a', 'oai-authenticated-user-id': 'owner-a',
      }, '?ownerId=owner-a&accountId=owner-a&purpose=account&clientConfirmed=true')), {
        purpose: 'community', account: { id: 'owner-b', email: 'b@example.invalid', displayName: null },
        clientConfirmed: false, expiresAt: now + 3600,
      });
      const own = await result(await get(`Bearer ${communityToken}`, { Cookie: cookie }));
      assert.equal(own.account.id, 'owner-a');
      assert.equal(own.clientConfirmed, true);
      assert.equal((await db.prepare('SELECT count(*) n FROM community_client_activations').first()).n, 1);
    });

    await t.test('revocation denies old token while permanent confirmation survives for a replacement', async () => {
      assert.deepEqual(await result(await post('/api/device/revoke', communityToken)), { revoked: true });
      await denied(`Bearer ${communityToken}`, { Cookie: cookie });
      const replacement = await token('community-a-replacement', 'owner-a', 'community', now + 7200);
      assert.deepEqual(await result(await get(`Bearer ${replacement}`)), {
        purpose: 'community', account: { id: 'owner-a', email: 'a@example.invalid', displayName: 'Community creator' },
        clientConfirmed: true, expiresAt: now + 7200,
      });
      await db.prepare('UPDATE device_tokens SET expires_at=? WHERE id=?').bind(now, 'community-a-replacement').run();
      await denied(`Bearer ${replacement}`);
      assert.equal((await db.prepare('SELECT count(*) n FROM community_client_activations').first()).n, 1);
    });
  } finally { await mf.dispose(); }
});
