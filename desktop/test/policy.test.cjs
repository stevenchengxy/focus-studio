'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const p = require('../src/policy.cjs');
const uuid = 'd6c13c3f-344a-42ba-8e66-0d431d52e65c';
test('trust is exact HTTPS origin and Studio path, not hostname prefixes or userinfo', () => {
  assert.equal(p.trustedURL(`${p.SITE_ORIGIN}/studio?desktop=1`, true), true);
  for (const url of ['file:///tmp/studio', 'javascript:alert(1)', `${p.SITE_ORIGIN}.evil.test/studio`,
    `${p.SITE_ORIGIN.replace('https:', 'http:')}/studio`, `${p.SITE_ORIGIN}:444/studio`,
    `https://user@${new URL(p.SITE_ORIGIN).host}/studio`, `${p.SITE_ORIGIN}/account`]) assert.equal(p.trustedURL(url, true), false, url);
  assert.equal(p.externalURL(`${p.SITE_ORIGIN}/account?code=123456-ABCDEF`), true);
  for (const url of ['https://evil.test', 'ms-settings:privacy', `${p.SITE_ORIGIN}/api/anything`]) assert.equal(p.externalURL(url), false);
});
test('only the current top-level Studio frame can invoke privileged IPC', () => {
  const frame = {url: p.STUDIO_URL}; const wc = {isDestroyed: () => false, mainFrame: frame};
  assert.equal(p.trustedIPC({sender: wc, senderFrame: frame}, wc), true);
  assert.equal(p.trustedIPC({sender: wc, senderFrame: {url: p.STUDIO_URL}}, wc), false);
  assert.equal(p.trustedIPC({sender: {}, senderFrame: frame}, wc), false);
  frame.url = 'https://evil.test'; assert.equal(p.trustedIPC({sender: wc, senderFrame: frame}, wc), false);
});
test('account bridge forbids arbitrary network, tokens, billing and oversized payloads', () => {
  assert.deepEqual(p.requestSpec({path: '/api/account', method: 'GET'}), {path: '/api/account', method: 'GET'});
  assert.ok(p.requestSpec({path: '/api/exports/reserve', method: 'POST', body: {idempotencyKey: uuid, projectId: 'local-demo'}}));
  for (const action of ['commit', 'release', 'renew']) assert.ok(p.requestSpec({path: `/api/exports/${uuid}/${action}`, method: 'POST', body: {}}));
  for (const input of [
    {path: 'https://evil.test', method: 'GET'}, {path: '/api/account', method: 'GET', headers: {Authorization: 'stolen'}},
    {path: '/api/billing/checkout', method: 'POST', body: {}}, {path: `/api/exports/${uuid}/commit?evil=1`, method: 'POST', body: {}},
    {path: `/api/exports/${uuid}/commit`, method: 'POST', body: {force: true}},
    {path: '/api/exports/reserve', method: 'POST', body: {idempotencyKey: uuid, projectId: 'x'.repeat(201)}},
    {path: '/api/exports/reserve', method: 'POST', body: {idempotencyKey: '../', projectId: 'demo'}}
  ]) assert.throws(() => p.requestSpec(input));
});
test('device pairing only opens the exact first-party verification link with matching code', () => {
  const data = {deviceCode: 'a'.repeat(64), userCode: 'ABC123-DEF456', expiresIn: 600, interval: 5,
    verificationUriComplete: `${p.SITE_ORIGIN}/account?code=ABC123-DEF456`};
  assert.equal(p.validatePairing(data), data);
  for (const change of [{verificationUriComplete: 'https://evil.test/account'}, {verificationUriComplete: `${p.SITE_ORIGIN}/account?code=ABC123-DEF456&redirect=evil`},
    {userCode: 'WRONG'}, {deviceCode: 'short'}, {interval: 0}, {expiresIn: 1000000}]) assert.throws(() => p.validatePairing({...data, ...change}));
});
test('system audio is explicitly selected and only Windows may obtain loopback', () => {
  const sources = [{id: 'screen:1:0', name: 'Display'}];
  assert.equal(p.selectionFor(sources, {id: 'screen:OTHER', audio: true}, true, 'win32'), null);
  assert.deepEqual(p.selectionFor(sources, {id: sources[0].id, audio: true}, true, 'win32'), {video: sources[0], audio: 'loopback'});
  for (const platform of ['linux', 'darwin']) {
    assert.equal(p.capabilities(platform).systemAudio, 'unavailable');
    assert.deepEqual(p.selectionFor(sources, {id: sources[0].id, audio: true}, true, platform), {video: sources[0]});
  }
  assert.deepEqual(p.selectionFor(sources, {id: sources[0].id, audio: false}, true, 'win32'), {video: sources[0]});
  assert.deepEqual(p.selectionFor(sources, {id: sources[0].id, audio: true}, false, 'win32'), {video: sources[0]});
});
