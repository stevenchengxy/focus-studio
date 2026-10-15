import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { mkdtemp, readFile, readdir, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import ts from 'typescript';

// Exercise the real runtime, signed Google sessions, device functions and HTTP
// routes. Only Cloudflare bindings and the trusted Sites identity are fixtures.
const temp = await mkdtemp(join(tmpdir(), 'focus-device-community-'));
const moduleNames = ['primitives', 'google-auth', 'runtime', 'devices', 'community-client'];
async function transpile(sourceURL, filename) {
  const source = await readFile(sourceURL, 'utf8');
  let output = ts.transpileModule(source, {
    compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ES2022 },
  }).outputText;
  for (const name of moduleNames) {
    output = output.replaceAll(`'./${name}'`, `'./${name}.mjs'`)
      .replaceAll(`'@/lib/server/${name}'`, `'./${name}.mjs'`);
  }
  output = output.replaceAll("'../product-access'", "'./product-access.mjs'")
    .replaceAll("'cloudflare:workers'", "'./fixtures.mjs'")
    .replaceAll("'@/app/chatgpt-auth'", "'./fixtures.mjs'");
  await writeFile(join(temp, filename), output);
}
await transpile(new URL('../lib/product-access.ts', import.meta.url), 'product-access.mjs');
for (const name of moduleNames) {
  await transpile(new URL(`../lib/server/${name}.ts`, import.meta.url), `${name}.mjs`);
}
await writeFile(join(temp, 'fixtures.mjs'), `
export const env = new Proxy({}, {get(_target, key) {return globalThis.__deviceCommunityFixture.env[key];}});
export async function getChatGPTUser() {return globalThis.__deviceCommunityFixture.user;}
`);
const primitive = await import(pathToFileURL(join(temp, 'primitives.mjs')));
const google = await import(pathToFileURL(join(temp, 'google-auth.mjs')));
const runtime = await import(pathToFileURL(join(temp, 'runtime.mjs')));
const devices = await import(pathToFileURL(join(temp, 'devices.mjs')));
const client = await import(pathToFileURL(join(temp, 'community-client.mjs')));
const routePaths = {
  start: '../app/api/device/start/route.ts',
  approve: '../app/api/device/approve/route.ts',
  token: '../app/api/device/token/route.ts',
  activate: '../app/api/device/activate/route.ts',
};
const routes = {};
for (const [name, path] of Object.entries(routePaths)) {
  await transpile(new URL(path, import.meta.url), `${name}-route.mjs`);
  routes[name] = (await import(pathToFileURL(join(temp, `${name}-route.mjs`)))).POST;
}
const sqlDir = new URL('../drizzle/', import.meta.url);
const sql = (await Promise.all((await readdir(sqlDir)).filter(name => name.endsWith('.sql')).sort()
  .map(name => readFile(new URL(name, sqlDir), 'utf8')))).join('\n');
const openDatabases = [];
function database() {
  const raw = new DatabaseSync(':memory:');
  openDatabases.push(raw);
  raw.exec('PRAGMA foreign_keys=ON');
  raw.exec(sql);
  function prepare(query, args = []) {
    const run = () => ({ meta: { changes: Number(raw.prepare(query).run(...args).changes) } });
    return {
      bind(...values) { return prepare(query, values); },
      async first() { return raw.prepare(query).get(...args) ?? null; },
      async all() { return { results: raw.prepare(query).all(...args) }; },
      async run() { return run(); },
      _run: run,
    };
  }
  return {
    raw, prepare,
    async batch(statements) {
      raw.exec('BEGIN IMMEDIATE');
      try {
        const results = statements.map(statement => statement._run());
        raw.exec('COMMIT');
        return results;
      } catch (error) {
        raw.exec('ROLLBACK');
        throw error;
      }
    },
  };
}
const origin = 'https://studio.test';
const sitesUser = { userId: 'trusted-sites-owner', email: 'sites@example.invalid', fullName: 'Sites Creator', displayName: 'Sites Creator' };
const googleOwner = 'google:fixture-user';
const sessionSecret = 'device-confirmation-fixture-secret-at-least-32-characters';
const apiFailure = error => error instanceof primitive.APIError && error.status >= 400 && error.status < 500;
const invalidCommunityDevice = error => error instanceof primitive.APIError
  && error.status === 401 && error.code === 'community_device_required';
function fixture(user = sitesUser) {
  const db = database();
  const state = { db, user, env: { DB: db, SITE_ORIGIN: origin, SESSION_SECRET: sessionSecret } };
  globalThis.__deviceCommunityFixture = state;
  return state;
}
function addAccount(db, id = sitesUser.userId) {
  db.raw.prepare('INSERT INTO accounts(id,email,created_at) VALUES(?,?,?)')
    .run(id, `${id}@example.invalid`, 100);
}
async function signedGoogleSession(db) {
  addAccount(db, googleOwner);
  const secret = primitive.randomSecret();
  db.raw.prepare('INSERT INTO web_sessions(hash,account_id,expires_at) VALUES(?,?,?)')
    .run(await primitive.sha256(secret), googleOwner, primitive.nowSeconds() + 3600);
  return `${google.SESSION_COOKIE}=${await google.signCookie(secret, sessionSecret)}`;
}
function request(path, body = {}, headers = {}, browser = false) {
  return new Request(`${origin}${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...(browser ? { Origin: origin } : {}), ...headers },
    body: JSON.stringify(body),
  });
}
function bearerRequest(token, headers = {}) {
  return new Request(`${origin}/api/account`, { headers: { Authorization: `Bearer ${token}`, ...headers } });
}
function activation(db) {
  const row = db.raw.prepare('SELECT owner_id,confirmed_at,device_id FROM community_client_activations').get();
  return row ? { ...row } : null;
}
async function issueToken(db, purpose = 'community', now = 100, owner = sitesUser.userId) {
  if (!db.raw.prepare('SELECT id FROM accounts WHERE id=?').get(owner)) addAccount(db, owner);
  const grant = await devices.createDeviceGrant(db, origin, now, purpose);
  await devices.approveDevice(db, owner, grant.userCode, 'Fixture Mac', now + 1, purpose);
  return { grant, token: await devices.exchangeDeviceGrant(db, grant.deviceCode, now + 2) };
}
const originalFetch = globalThis.fetch;
test.before(() => {
  globalThis.fetch = async () => { throw new Error('External network is forbidden in device confirmation tests.'); };
});
test.after(async () => {
  globalThis.fetch = originalFetch;
  delete globalThis.__deviceCommunityFixture;
  for (const db of openDatabases) db.close();
  await rm(temp, { recursive: true, force: true });
});

test('existing account grants and tokens survive the purpose migration without gaining community confirmation', async () => {
  const raw = new DatabaseSync(':memory:');
  openDatabases.push(raw);
  raw.exec('PRAGMA foreign_keys=ON');
  const names = (await readdir(sqlDir)).filter(name => name.endsWith('.sql')).sort();
  const previous = names.filter(name => /^000[0-5]_/.test(name));
  const upgrade = names.filter(name => /^0006_/.test(name));
  assert.equal(previous.length, 6);
  assert.equal(upgrade.length, 1);
  for (const name of previous) raw.exec(await readFile(new URL(name, sqlDir), 'utf8'));
  raw.prepare('INSERT INTO accounts(id,email,created_at) VALUES(?,?,?)')
    .run('existing-owner', 'existing@example.invalid', 10);
  raw.prepare('INSERT INTO device_grants(hash,user_code,account_id,name,expires_at,created_at) VALUES(?,?,?,?,?,?)')
    .run('a'.repeat(64), 'ABCDEF654321', 'existing-owner', 'Existing Mac grant', 1000, 20);
  raw.prepare('INSERT INTO device_tokens(id,hash,account_id,name,expires_at,created_at,revoked_at) VALUES(?,?,?,?,?,?,?)')
    .run('existing-device', 'b'.repeat(64), 'existing-owner', 'Existing Mac token', 2000, 30, 40);
  const accountBefore = { ...raw.prepare('SELECT * FROM accounts').get() };
  const grantBefore = { ...raw.prepare('SELECT * FROM device_grants').get() };
  const tokenBefore = { ...raw.prepare('SELECT * FROM device_tokens').get() };
  raw.exec(await readFile(new URL(upgrade[0], sqlDir), 'utf8'));
  assert.deepEqual({ ...raw.prepare('SELECT * FROM accounts').get() }, accountBefore);
  assert.deepEqual({ ...raw.prepare('SELECT * FROM device_grants').get() }, { ...grantBefore, purpose: 'account' });
  assert.deepEqual({ ...raw.prepare('SELECT * FROM device_tokens').get() }, { ...tokenBefore, purpose: 'account' });
  assert.equal(raw.prepare('SELECT count(*) n FROM community_client_activations').get().n, 0);
  assert.equal(raw.prepare('PRAGMA foreign_key_check').all().length, 0);
});

test('legacy device calls and SQL rows default to account purpose', async () => {
  const { db } = fixture();
  addAccount(db);
  const now = primitive.nowSeconds();
  const grant = await devices.createDeviceGrant(db, origin, now);
  assert.equal(await devices.getDeviceGrantPurpose(db, grant.userCode, now + 1), 'account');
  assert.equal(db.raw.prepare('SELECT purpose FROM device_grants').get().purpose, 'account');
  await devices.approveDevice(db, sitesUser.userId, grant.userCode, 'Legacy Mac', now + 1);
  const token = await devices.exchangeDeviceGrant(db, grant.deviceCode, now + 2);
  assert.equal(token.purpose, 'account');
  assert.equal((await runtime.authenticate(bearerRequest(token.accessToken))).id, sitesUser.userId);
  const oldToken = `fs_${primitive.randomSecret()}`;
  db.raw.prepare('INSERT INTO device_tokens(id,hash,account_id,name,expires_at,created_at) VALUES(?,?,?,?,?,?)')
    .run('old-device', await primitive.sha256(oldToken), sitesUser.userId, 'Old install', now + 1000, now);
  assert.equal((await runtime.authenticate(bearerRequest(oldToken))).id, sitesUser.userId);
  db.raw.prepare('INSERT INTO device_grants(hash,user_code,name,expires_at,created_at) VALUES(?,?,?,?,?)')
    .run(await primitive.sha256(primitive.randomSecret()), 'ABCDEF123456', 'Old grant', now + 600, now);
  assert.equal(await devices.getDeviceGrantPurpose(db, 'abcdef-123456', now), 'account');
});

test('grant purpose lookup and approval require a live matching grant', async () => {
  const { db } = fixture();
  addAccount(db);
  const grant = await devices.createDeviceGrant(db, origin, 100, 'community');
  assert.equal(await devices.getDeviceGrantPurpose(db, grant.userCode.toLowerCase(), 101), 'community');
  await assert.rejects(devices.approveDevice(db, sitesUser.userId, grant.userCode, 'Wrong purpose', 102), apiFailure);
  assert.equal(db.raw.prepare('SELECT account_id FROM device_grants').get().account_id, null);
  await assert.rejects(devices.getDeviceGrantPurpose(db, grant.userCode, 700), apiFailure);
  await assert.rejects(devices.getDeviceGrantPurpose(db, 'not-a-code', 101), apiFailure);
  await devices.approveDevice(db, sitesUser.userId, grant.userCode, 'Community Mac', 103, 'community');
  await assert.rejects(devices.approveDevice(db, sitesUser.userId, grant.userCode, 'Again', 104, 'community'), apiFailure);
});

test('invalid purpose inputs cannot create grants or fall back to account pairing', async () => {
  const { db } = fixture();
  for (const purpose of [null, '', 'admin', 'COMMUNITY', false, {}, ['community']]) {
    const response = await routes.start(request('/api/device/start', { purpose }));
    assert.equal(response.status, 400);
    assert.equal((await response.json()).error.code, 'invalid_device_purpose');
    assert.equal(db.raw.prepare('SELECT count(*) n FROM device_grants').get().n, 0);
  }
});

test('community approval selects trusted ChatGPT identity despite a valid higher-priority Google cookie', async () => {
  const { db } = fixture();
  const cookie = await signedGoogleSession(db);
  assert.equal((await runtime.authenticate(new Request(`${origin}/api/account`, { headers: { Cookie: cookie } }), true)).id, googleOwner);
  const grant = await devices.createDeviceGrant(db, origin, primitive.nowSeconds(), 'community');
  const response = await routes.approve(request('/api/device/approve', {
    userCode: grant.userCode, name: 'Community Mac', purpose: 'account', accountId: googleOwner,
  }, { Cookie: cookie }, true));
  assert.equal(response.status, 200);
  const row = db.raw.prepare('SELECT account_id,purpose FROM device_grants').get();
  assert.equal(row.account_id, sitesUser.userId);
  assert.equal(row.purpose, 'community');
  assert.equal(db.raw.prepare('SELECT email FROM accounts WHERE id=?').get(sitesUser.userId).email, sitesUser.email);
  assert.equal(await client.hasCommunityClientActivation(db, sitesUser.userId), false);
  assert.equal(await client.hasCommunityClientActivation(db, googleOwner), false);
});

test('forged community body purpose cannot move an account grant away from normal Google authentication', async () => {
  const { db } = fixture();
  const cookie = await signedGoogleSession(db);
  const grant = await devices.createDeviceGrant(db, origin);
  const response = await routes.approve(request('/api/device/approve', {
    userCode: grant.userCode, name: 'Account Mac', purpose: 'community', accountId: sitesUser.userId,
  }, { Cookie: cookie }, true));
  assert.equal(response.status, 200);
  const row = db.raw.prepare('SELECT account_id,purpose FROM device_grants').get();
  assert.equal(row.account_id, googleOwner);
  assert.equal(row.purpose, 'account');
  const token = await devices.exchangeDeviceGrant(db, grant.deviceCode);
  assert.equal(token.purpose, 'account');
  assert.equal((await runtime.authenticate(bearerRequest(token.accessToken))).id, googleOwner);
});

test('Google-only sessions and forged identity fields cannot approve a community grant', async () => {
  const state = fixture(null);
  const cookie = await signedGoogleSession(state.db);
  const grant = await devices.createDeviceGrant(state.db, origin, primitive.nowSeconds(), 'community');
  const response = await routes.approve(request('/api/device/approve', {
    userCode: grant.userCode, name: 'Untrusted Mac', purpose: 'account', ownerId: sitesUser.userId,
    user: sitesUser, userId: sitesUser.userId, email: sitesUser.email,
  }, { Cookie: cookie, 'X-User-ID': sitesUser.userId }, true));
  assert.equal(response.status, 401);
  assert.equal((await response.json()).error.code, 'community_sign_in_required');
  assert.equal(state.db.raw.prepare('SELECT account_id FROM device_grants').get().account_id, null);
  assert.equal(state.db.raw.prepare('SELECT count(*) n FROM community_client_activations').get().n, 0);
  state.user = sitesUser;
  assert.equal((await routes.approve(request('/api/device/approve', { userCode: grant.userCode }, { Cookie: cookie }, true))).status, 200);
});

test('community bearer cannot authenticate ordinary account APIs or fall back to browser identities', async () => {
  const { db } = fixture();
  const cookie = await signedGoogleSession(db);
  const { token } = await issueToken(db, 'community', primitive.nowSeconds());
  assert.equal(token.purpose, 'community');
  await assert.rejects(runtime.authenticate(bearerRequest(token.accessToken)), apiFailure);
  await assert.rejects(runtime.authenticate(bearerRequest(token.accessToken, { Cookie: cookie })), apiFailure);
  await assert.rejects(runtime.authenticate(bearerRequest(token.accessToken), true), apiFailure);
  assert.equal(await client.hasCommunityClientActivation(db, sitesUser.userId), false);
});

test('activation rejects account tokens, invalid syntax, unknown tokens and non-native credentials', async () => {
  const { db } = fixture();
  const { token } = await issueToken(db, 'account');
  for (const authorization of [null, '', 'Basic test', `Bearer ${token.accessToken}`, `Bearer fs_${'0'.repeat(64)}`, 'Bearer fs_invalid']) {
    await assert.rejects(client.activateCommunityClient(db, authorization, 103), invalidCommunityDevice);
    assert.equal(activation(db), null);
  }
  const cookie = await signedGoogleSession(db);
  const response = await routes.activate(request('/api/device/activate', {
    ownerId: sitesUser.userId, downloaded: true, installed: true,
  }, { Cookie: cookie }, true));
  assert.equal(response.status, 401);
  assert.equal((await response.json()).error.code, 'community_device_required');
  assert.equal(activation(db), null);
});

test('expired and revoked community tokens cannot create confirmations', async () => {
  for (const condition of ['expired', 'revoked']) {
    const { db } = fixture();
    const { token } = await issueToken(db, 'community');
    if (condition === 'expired') db.raw.prepare('UPDATE device_tokens SET expires_at=103').run();
    else db.raw.prepare('UPDATE device_tokens SET revoked_at=103').run();
    await assert.rejects(client.activateCommunityClient(db, `Bearer ${token.accessToken}`, 103), invalidCommunityDevice);
    assert.equal(await client.hasCommunityClientActivation(db, sitesUser.userId), false);
    assert.equal(activation(db), null);
  }
});

test('activation HTTP route rejects expired and revoked community tokens with the public error contract', async () => {
  for (const condition of ['expired', 'revoked']) {
    const { db } = fixture();
    const now = primitive.nowSeconds();
    const { token } = await issueToken(db, 'community', now);
    if (condition === 'expired') db.raw.prepare('UPDATE device_tokens SET expires_at=?').run(now);
    else db.raw.prepare('UPDATE device_tokens SET revoked_at=?').run(now);
    const response = await routes.activate(request('/api/device/activate', {}, { Authorization: `Bearer ${token.accessToken}` }));
    assert.equal(response.status, 401);
    assert.equal((await response.json()).error.code, 'community_device_required');
    assert.equal(activation(db), null);
  }
});

test('confirmation is permanent and idempotent across delivery retries and replacement devices', async () => {
  const { db } = fixture();
  const first = await issueToken(db);
  await client.activateCommunityClient(db, `Bearer ${first.token.accessToken}`, 103);
  const saved = activation(db);
  assert.equal(saved.owner_id, sitesUser.userId);
  assert.equal(saved.confirmed_at, 103);
  assert.equal(saved.device_id, db.raw.prepare('SELECT id FROM device_tokens').get().id);
  await client.activateCommunityClient(db, `Bearer ${first.token.accessToken}`, 104);
  assert.deepEqual(activation(db), saved);
  const replacement = await issueToken(db, 'community', 110);
  await client.activateCommunityClient(db, `Bearer ${replacement.token.accessToken}`, 113);
  assert.deepEqual(activation(db), saved);
  db.raw.prepare('UPDATE device_tokens SET revoked_at=114,expires_at=114').run();
  db.raw.prepare('DELETE FROM device_grants').run();
  assert.equal(await client.hasCommunityClientActivation(db, sitesUser.userId), true);
  assert.equal(await client.hasCommunityClientActivation(db, 'unconfirmed-owner'), false);
  await assert.rejects(client.activateCommunityClient(db, `Bearer ${replacement.token.accessToken}`, 115), invalidCommunityDevice);
  assert.deepEqual(activation(db), saved);
  assert.equal(db.raw.prepare('SELECT count(*) n FROM community_client_activations').get().n, 1);
});

test('native start, browser approval, token exchange and native activation complete with one owner', async () => {
  const { db } = fixture();
  const cookie = await signedGoogleSession(db);
  let response = await routes.start(request('/api/device/start', { purpose: 'community' }));
  assert.equal(response.status, 200);
  const grant = await response.json();
  assert.equal(await devices.getDeviceGrantPurpose(db, grant.userCode), 'community');
  assert.equal(new URL(grant.verificationUriComplete).searchParams.get('code'), grant.userCode);
  response = await routes.token(request('/api/device/token', { deviceCode: grant.deviceCode }));
  assert.equal(response.status, 202);
  assert.equal((await response.json()).status, 'authorization_pending');
  response = await routes.approve(request('/api/device/approve', { userCode: grant.userCode, name: 'Installed Mac' }, { Cookie: cookie }, true));
  assert.equal(response.status, 200);
  assert.equal(await client.hasCommunityClientActivation(db, sitesUser.userId), false);
  response = await routes.token(request('/api/device/token', { deviceCode: grant.deviceCode }));
  assert.equal(response.status, 200);
  const token = await response.json();
  assert.equal(token.purpose, 'community');
  assert.equal(token.tokenType, 'Bearer');
  assert.match(token.accessToken, /^fs_[a-f0-9]{64}$/);
  const retry = await (await routes.token(request('/api/device/token', { deviceCode: grant.deviceCode }))).json();
  assert.equal(retry.accessToken, token.accessToken);
  assert.equal(await client.hasCommunityClientActivation(db, sitesUser.userId), false);
  response = await routes.activate(request('/api/device/activate', { ownerId: googleOwner }, { Authorization: `Bearer ${token.accessToken}` }));
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { confirmed: true });
  assert.equal(await client.hasCommunityClientActivation(db, sitesUser.userId), true);
  assert.equal(await client.hasCommunityClientActivation(db, googleOwner), false);
  const saved = activation(db);
  response = await routes.activate(request('/api/device/activate', {}, { Authorization: `Bearer ${token.accessToken}` }));
  assert.equal(response.status, 200);
  assert.deepEqual(activation(db), saved);
});

test('HTTP default account pairing remains usable and never grants community confirmation', async () => {
  const { db } = fixture();
  const cookie = await signedGoogleSession(db);
  const response = await routes.start(request('/api/device/start'));
  assert.equal(response.status, 200);
  const grant = await response.json();
  assert.equal(await devices.getDeviceGrantPurpose(db, grant.userCode), 'account');
  assert.equal((await routes.approve(request('/api/device/approve', { userCode: grant.userCode }, { Cookie: cookie }, true))).status, 200);
  const tokenResponse = await routes.token(request('/api/device/token', { deviceCode: grant.deviceCode }));
  assert.equal(tokenResponse.status, 200);
  const token = await tokenResponse.json();
  assert.equal(token.purpose, 'account');
  assert.equal((await runtime.authenticate(bearerRequest(token.accessToken))).id, googleOwner);
  const denied = await routes.activate(request('/api/device/activate', {}, { Authorization: `Bearer ${token.accessToken}` }));
  assert.equal(denied.status, 401);
  assert.equal((await denied.json()).error.code, 'community_device_required');
  assert.equal(activation(db), null);
});

test('browser pairing and activation reject a foreign Origin without mutating grants or confirmations', async () => {
  const { db } = fixture();
  const foreign = { Origin: 'https://attacker.test' };
  assert.equal((await routes.start(request('/api/device/start', { purpose: 'community' }, foreign))).status, 403);
  assert.equal(db.raw.prepare('SELECT count(*) n FROM device_grants').get().n, 0);
  const grant = await devices.createDeviceGrant(db, origin, primitive.nowSeconds(), 'community');
  assert.equal((await routes.approve(request('/api/device/approve', { userCode: grant.userCode }, foreign))).status, 403);
  assert.equal((await routes.approve(request('/api/device/approve', { userCode: grant.userCode }))).status, 403);
  assert.equal(db.raw.prepare('SELECT account_id FROM device_grants').get().account_id, null);
  assert.equal((await routes.token(request('/api/device/token', { deviceCode: grant.deviceCode }, foreign))).status, 403);
  const { token } = await issueToken(db, 'community', primitive.nowSeconds());
  assert.equal((await routes.activate(request('/api/device/activate', {}, { ...foreign, Authorization: `Bearer ${token.accessToken}` }))).status, 403);
  assert.equal(activation(db), null);
});
