'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const {AccountClient} = require('../src/account.cjs');
const {TokenVault} = require('../src/vault.cjs');
const {SITE_ORIGIN} = require('../src/policy.cjs');
const token = `fs_${'a'.repeat(64)}`;
function memoryVault(initial = null) { let value = initial; return {get: async () => value, set: async t => { value = t; }, clear: async () => { value = null; }}; }
const response = (body, status = 200) => new Response(JSON.stringify(body), {status, headers: {'content-type': 'application/json'}});
test('bearer is attached only by main process; redirects fail closed and 401 removes stale login', async () => {
  const vault = memoryVault(token); let changed = 0;
  const account = new AccountClient({vault, onChanged: () => changed++, fetchImpl: async (url, init) => {
    assert.equal(url, `${SITE_ORIGIN}/api/account`); assert.equal(init.headers.Authorization, `Bearer ${token}`);
    assert.equal(init.redirect, 'error'); assert.equal(init.headers.Origin, undefined); return response({authenticated: false}, 401);
  }});
  const result = await account.request({path: '/api/account', method: 'GET'});
  assert.equal(result.status, 401); assert.equal(await vault.get(), null); assert.equal(changed, 1);
  assert.equal((await account.request({path: '/api/account', method: 'GET'})).status, 401);
});
test('network failures preserve login and report uncertain server outcome', async () => {
  const vault = memoryVault(token);
  const account = new AccountClient({vault, fetchImpl: async () => { throw new Error('timeout'); }});
  const result = await account.request({path: '/api/exports/12345678-1234-1234-1234-123456789abc/commit', method: 'POST', body: {}});
  assert.equal(result.status, 503); assert.equal(await vault.get(), token);
});
test('pairing is single-flight, validates link and never exposes device secret/token to renderer', async () => {
  const vault = memoryVault(); let starts = 0; let opened = ''; let timer; let changed = 0;
  const account = new AccountClient({vault, openExternal: async url => { opened = url; }, onChanged: () => changed++,
    setTimer: fn => { timer = fn; return 1; }, clearTimer: () => {}, fetchImpl: async url => {
      if (url.endsWith('/start')) { starts++; return response({deviceCode: 'a'.repeat(64), userCode: 'ABC123-DEF456', expiresIn: 600, interval: 5,
        verificationUriComplete: `${SITE_ORIGIN}/account?code=ABC123-DEF456`}); }
      return response({accessToken: token, tokenType: 'Bearer', expiresIn: 1000});
    }});
  const [a, b] = await Promise.all([account.startSignIn(), account.startSignIn()]);
  assert.equal(starts, 1); assert.deepEqual(a, b); assert.deepEqual(Object.keys(a).sort(), ['expiresIn', 'userCode']);
  assert.equal(opened, `${SITE_ORIGIN}/account?code=ABC123-DEF456`);
  timer(); await new Promise(resolve => setImmediate(resolve));
  assert.equal(await vault.get(), token); assert.equal(changed, 1); assert.equal(account.pairing, null);
});
test('signout racing a token exchange cannot restore login', async () => {
  const vault = memoryVault(); let deliver;
  const account = new AccountClient({vault, openExternal: async () => {}, setTimer: () => 1, clearTimer: () => {}, fetchImpl: async url => {
    if (url.endsWith('/start')) return response({deviceCode: 'b'.repeat(64), userCode: 'ABC123-DEF456', expiresIn: 600, interval: 5,
      verificationUriComplete: `${SITE_ORIGIN}/account?code=ABC123-DEF456`});
    return new Promise(resolve => { deliver = resolve; });
  }});
  await account.startSignIn(); const pending = account.poll(account.epoch); await new Promise(resolve => setImmediate(resolve));
  await account.signOut(); deliver(response({accessToken: token})); await pending;
  assert.equal(await vault.get(), null);
});
test('vault never persists token on Linux basic_text and serializes read/signout races', async t => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'focus-vault-')); t.after(() => fs.rm(directory, {recursive: true, force: true}));
  const unavailable = new TokenVault({directory, platform: 'linux', safeStorage: {isEncryptionAvailable: () => true, getSelectedStorageBackend: () => 'basic_text', encryptString: () => assert.fail('No weak encryption')}});
  await unavailable.set(token); assert.equal(await unavailable.get(), token); assert.deepEqual(await fs.readdir(directory), []);
  const safeStorage = {isEncryptionAvailable: () => true, getSelectedStorageBackend: () => 'gnome_libsecret',
    encryptString: text => Buffer.from(`encrypted:${text}`), decryptString: bytes => bytes.toString().slice(10)};
  const vault = new TokenVault({directory, safeStorage, platform: 'linux'}); await vault.set(token);
  assert.equal((await fs.readFile(path.join(directory, 'account-token.enc'))).toString().startsWith('encrypted:'), true);
  const restored = new TokenVault({directory, safeStorage, platform: 'linux'});
  const read = restored.get(); const clear = restored.clear(); await Promise.all([read, clear]);
  assert.equal(await restored.get(), null); assert.deepEqual(await fs.readdir(directory), []);
});
