'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const {CommunityClient, CommunityVault, validateCommunityGrant} = require('../src/community.cjs');
const {SITE_ORIGIN, requestSpec} = require('../src/policy.cjs');
const token = `fs_${'a'.repeat(64)}`;
const deviceCode = 'b'.repeat(64);
const now = 1800000000000;
const credential = () => ({purpose: 'community', accessToken: token, expiresAt: now + 3600000});
const grant = () => ({purpose: 'community', deviceCode, userCode: 'ABC123-DEF456', expiresIn: 600, interval: 5,
  verificationUriComplete: `${SITE_ORIGIN}/account?code=ABC123-DEF456&purpose=community`});
const tokenResponse = () => ({purpose: 'community', accessToken: token, tokenType: 'Bearer', expiresIn: 3600});
const response = (body, status = 200) => new Response(JSON.stringify(body), {status, headers: {'content-type': 'application/json'}});
const tick = () => new Promise(resolve => setImmediate(resolve));
function deferred() { let resolve; const promise = new Promise(r => { resolve = r; }); return {promise, resolve}; }
function memoryVault(initial = null) { let value = initial; return {get: async () => value, set: async next => { value = next; }, clear: async () => { value = null; }}; }
function setup({initial = null, fetchImpl, ...options} = {}) {
  const calls = [], opened = [], changes = [];
  const vault = options.vault ?? memoryVault(initial);
  const client = new CommunityClient({vault, isPackaged: () => true, now: () => now,
    setTimer: () => 1, clearTimer: () => {}, openExternal: async url => { opened.push(url); },
    onChanged: value => changes.push(value), fetchImpl: async (url, init) => {
      calls.push({url, init});
      if (fetchImpl) return fetchImpl(url, init);
      if (url.endsWith('/start')) return response(grant());
      if (url.endsWith('/token')) return response(tokenResponse());
      if (url.endsWith('/activate')) return response({confirmed: true});
      return response({revoked: true});
    }, ...options});
  return {client, vault, calls, opened, changes};
}

test('community grant accepts only its exact purpose and official HTTPS approval URL', () => {
  assert.equal(validateCommunityGrant(grant()).userCode, 'ABC123-DEF456');
  const invalid = [undefined, {...grant(), purpose: undefined}, {...grant(), purpose: 'account'},
    ...['https://evil.test/account?code=ABC123-DEF456&purpose=community',
      `${SITE_ORIGIN.replace('https:', 'http:')}/account?code=ABC123-DEF456&purpose=community`,
      `${SITE_ORIGIN}/account?code=ABC123-DEF456`, `${SITE_ORIGIN}/account?code=ABC123-DEF456&purpose=account`,
      `${SITE_ORIGIN}/account?code=ABC123-DEF456&purpose=community&purpose=account`,
      `${SITE_ORIGIN}/account?code=ABC123-DEF456&purpose=community#token`,
      `${SITE_ORIGIN}/account?code=ABC123-DEF456&purpose=community&redirect=evil`,
      `${SITE_ORIGIN}/studio?code=ABC123-DEF456&purpose=community`].map(verificationUriComplete => ({...grant(), verificationUriComplete}))];
  for (const value of invalid) assert.throws(() => validateCommunityGrant(value));
});

test('browser approval then token then trusted activation is required; public states never contain secrets', async () => {
  const {client, vault, calls, opened, changes} = setup();
  const state = await client.start();
  assert.deepEqual(state, {state: 'awaitingApproval', userCode: 'ABC123-DEF456', expiresIn: 600});
  assert.deepEqual(JSON.parse(calls[0].init.body), {purpose: 'community'});
  assert.equal(await vault.get(), null); assert.deepEqual(opened, [grant().verificationUriComplete]);
  await client.poll(client.epoch);
  assert.equal((await client.status()).state, 'confirmed'); assert.deepEqual(await vault.get(), credential());
  const activation = calls.find(call => call.url.endsWith('/activate'));
  assert.equal(activation.init.headers.Authorization, `Bearer ${token}`); assert.equal(activation.init.body, '{}');
  assert.equal(activation.init.redirect, 'error');
  assert.ok(changes.some(state => state.state === 'confirming'));
  assert.ok(!JSON.stringify(changes).includes(token) && !JSON.stringify(changes).includes(deviceCode));
  assert.ok(!JSON.stringify(changes).includes('verificationUri'));
  assert.ok(calls.every(call => new URL(call.url).origin === SITE_ORIGIN));
});

test('start is single-flight and repeated clicks return the current state', async () => {
  const pending = deferred(); let requests = 0;
  const {client} = setup({fetchImpl: async () => { requests++; return pending.promise; }});
  const first = client.start(); await tick();
  assert.deepEqual(await client.start(), {state: 'connecting'}); assert.equal(requests, 1);
  pending.resolve(response(grant())); await first;
  assert.equal((await client.start()).state, 'awaitingApproval'); assert.equal(requests, 1);
});

test('no absent, false, string or non-200 activation receipt counts as confirmed', async () => {
  for (const [body, status] of [[{}, 200], [{confirmed: false}, 200], [{confirmed: 'true'}, 200], [{confirmed: true}, 202], [{confirmed: true}, 503]]) {
    const {client, vault} = setup({initial: credential(), fetchImpl: async () => response(body, status)});
    const result = await client.retry();
    assert.equal(result.state, 'error'); assert.equal(result.requiresReconnect, false); assert.ok(await vault.get());
  }
});

test('old account or missing-purpose token exchanges are rejected before storage or activation', async () => {
  for (const purpose of [undefined, 'account']) {
    const {client, vault, calls} = setup({fetchImpl: async url => response(url.endsWith('/start') ? grant() : {...tokenResponse(), purpose})});
    await client.start(); await client.poll(client.epoch);
    assert.equal((await client.status()).state, 'error'); assert.equal(await vault.get(), null);
    assert.ok(!calls.some(call => call.url.endsWith('/activate')));
  }
});

test('expired or account-purpose saved credentials cannot activate', async () => {
  for (const value of [{...credential(), purpose: 'account'}, {...credential(), expiresAt: now}, token]) {
    const {client, calls} = setup({initial: value});
    assert.equal((await client.retry()).requiresReconnect, true); assert.equal(calls.length, 0);
  }
});

test('restart rechecks the server; 401 and 403 require reconnect and forget the scoped token', async () => {
  const saved = setup({initial: credential()}); await saved.client.restore();
  assert.equal((await saved.client.status()).state, 'confirmed'); assert.equal(saved.calls.length, 1);
  for (const status of [401, 403, 410]) {
    const {client, vault} = setup({initial: credential(), fetchImpl: async () => response({error: {message: token}}, status)});
    const state = await client.restore(); assert.equal(state.state, 'error'); assert.equal(state.requiresReconnect, true);
    assert.equal(await vault.get(), null); assert.ok(!JSON.stringify(state).includes(token));
  }
});

test('unpackaged main-process gate rejects start/retry and ignores renderer-shaped overrides', async () => {
  const {client, calls, opened} = setup({initial: credential(), isPackaged: () => false});
  await client.restore();
  assert.equal((await client.start({isPackaged: true})).state, 'error');
  assert.equal((await client.retry({isPackaged: true})).state, 'error');
  assert.equal(calls.length, 0); assert.equal(opened.length, 0);
  const defaultDenied = new CommunityClient({vault: memoryVault(), fetchImpl: () => assert.fail('Unpackaged request')});
  assert.equal((await defaultDenied.start()).state, 'error');
});

test('cancelling an outstanding grant prevents later browser opening', async () => {
  const pending = deferred(); const {client, opened} = setup({fetchImpl: () => pending.promise});
  const starting = client.start(); await tick(); await client.cancel(); pending.resolve(response(grant())); await starting;
  assert.deepEqual(await client.status(), {state: 'idle'}); assert.equal(opened.length, 0);
});

test('late token after cancellation is not saved or activated and is revoked', async () => {
  const pending = deferred();
  const {client, vault, calls} = setup({fetchImpl: url => url.endsWith('/token') ? pending.promise : Promise.resolve(response(url.endsWith('/start') ? grant() : {revoked: true}))});
  await client.start(); const polling = client.poll(client.epoch); await tick();
  await client.cancel(); pending.resolve(response(tokenResponse())); await polling; await tick();
  assert.equal(await vault.get(), null); assert.deepEqual(await client.status(), {state: 'idle'});
  assert.ok(!calls.some(call => call.url.endsWith('/activate'))); assert.ok(calls.some(call => call.url.endsWith('/revoke')));
});

test('cancellation during secure storage cannot restore credentials or confirm', async () => {
  const writing = deferred(); const vault = memoryVault(); const set = vault.set;
  vault.set = async value => { await writing.promise; await set(value); };
  const {client, calls} = setup({vault}); await client.start();
  const polling = client.poll(client.epoch); await tick(); const cancelling = client.cancel();
  writing.resolve(); await Promise.all([polling, cancelling]);
  assert.equal(await vault.get(), null); assert.equal((await client.status()).state, 'idle');
  assert.ok(!calls.some(call => call.url.endsWith('/activate')));
});

test('late activation success after disconnect cannot restore confirmed state', async () => {
  const pending = deferred(); const {client, vault} = setup({initial: credential(), fetchImpl: url => url.endsWith('/activate') ? pending.promise : Promise.resolve(response({revoked: true}))});
  const activation = client.retry(); await tick(); await client.disconnect(); pending.resolve(response({confirmed: true})); await activation;
  assert.equal(await vault.get(), null); assert.deepEqual(await client.status(), {state: 'idle'});
});

test('pending grants poll only until expiry; browser failure and malformed results are errors', async () => {
  let clock = now; let scheduled = 0;
  const {client, calls} = setup({now: () => clock, setTimer: () => { scheduled++; return 1; },
    fetchImpl: async url => response(url.endsWith('/start') ? grant() : {status: 'authorization_pending'}, url.endsWith('/start') ? 200 : 202)});
  await client.start(); await client.poll(client.epoch); assert.equal((await client.status()).state, 'awaitingApproval'); assert.equal(scheduled, 2);
  clock += 601000; await client.poll(client.epoch); assert.equal((await client.status()).requiresReconnect, true); assert.equal(calls.length, 2);
  const browser = setup({openExternal: async () => { throw new Error('No browser'); }});
  assert.equal((await browser.client.start()).state, 'error');
  const malformed = setup({fetchImpl: async () => response({...grant(), purpose: 'account'})});
  assert.equal((await malformed.client.start()).state, 'error'); assert.equal(malformed.opened.length, 0);
});

test('community transport cannot route a community token through account or export APIs', async () => {
  for (const endpoint of ['/api/device/activate', '/api/device/token', '/api/device/start']) {
    assert.throws(() => requestSpec({path: endpoint, method: 'POST', body: {}}));
  }
  const {client, calls} = setup({initial: credential()}); await client.restore(); await client.disconnect();
  assert.ok(calls.every(call => ['/api/device/activate', '/api/device/revoke'].includes(new URL(call.url).pathname)));
});

test('community vault uses its own encrypted purpose envelope and leaves legacy account file untouched', async t => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'focus-community-vault-')); t.after(() => fs.rm(directory, {recursive: true, force: true}));
  const legacyPath = path.join(directory, 'account-token.enc'); await fs.writeFile(legacyPath, 'legacy-account');
  const crypt = buffer => Buffer.from(buffer).map(byte => byte ^ 0x6d);
  const safeStorage = {isEncryptionAvailable: () => true, encryptString: text => crypt(Buffer.from(text)), decryptString: buffer => crypt(buffer).toString()};
  const vault = new CommunityVault({directory, safeStorage, platform: 'win32', now: () => now});
  assert.equal(await vault.get(), null); await vault.set(credential());
  const encrypted = await fs.readFile(path.join(directory, 'community-token.enc'));
  assert.ok(!encrypted.toString().includes(token));
  const restored = new CommunityVault({directory, safeStorage, platform: 'win32', now: () => now});
  assert.deepEqual(await restored.get(), credential()); await restored.clear();
  assert.equal(await fs.readFile(legacyPath, 'utf8'), 'legacy-account');
  await fs.writeFile(path.join(directory, 'community-token.enc'), safeStorage.encryptString(JSON.stringify({...credential(), purpose: 'account'})));
  assert.equal(await new CommunityVault({directory, safeStorage, platform: 'win32', now: () => now}).get(), null);
});

test('Linux basic_text keeps community credential in memory without plaintext persistence', async t => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'focus-community-memory-')); t.after(() => fs.rm(directory, {recursive: true, force: true}));
  const vault = new CommunityVault({directory, platform: 'linux', now: () => now, safeStorage: {
    isEncryptionAvailable: () => true, getSelectedStorageBackend: () => 'basic_text', encryptString: () => assert.fail('Weak keyring must not persist') }});
  await vault.set(credential()); assert.deepEqual(await vault.get(), credential()); assert.deepEqual(await fs.readdir(directory), []);
});

test('preload exposes only fixed community actions and a removable notification callback', async () => {
  let bridge; const calls = [], listeners = new Map();
  const ipcRenderer = {invoke: async (...args) => { calls.push(args); return {state: 'idle'}; },
    on: (channel, fn) => listeners.set(channel, fn), removeListener: (channel, fn) => { assert.equal(listeners.get(channel), fn); listeners.delete(channel); }};
  vm.runInNewContext(await fs.readFile(path.join(__dirname, '../src/preload.cjs'), 'utf8'), {require: name => {
    assert.equal(name, 'electron'); return {contextBridge: {exposeInMainWorld: (_name, value) => { bridge = value; }}, ipcRenderer};
  }});
  for (const method of ['communityStatus', 'startCommunityConnection', 'cancelCommunityConnection', 'retryCommunityConfirmation', 'disconnectCommunity']) {
    const result = await bridge[method]({token, isPackaged: true}); assert.equal(result.state, 'idle');
  }
  assert.ok(calls.every(args => args.length === 1));
  let notifications = 0; const unsubscribe = bridge.onCommunityChanged(() => notifications++);
  listeners.get('focus:community-changed')({}, {accessToken: token}); assert.equal(notifications, 1);
  unsubscribe(); assert.equal(listeners.size, 0); assert.throws(() => bridge.onCommunityChanged('bad'));
  assert.equal(bridge.token, undefined); assert.equal(bridge.communityVault, undefined);
});
