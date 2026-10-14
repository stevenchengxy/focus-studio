'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const {UpdateController, parseVersion, compareVersions, officialDownload, validateRelease, responseJSON, DAY, RETRY} = require('../src/updates.cjs');
const {SITE_ORIGIN} = require('../src/policy.cjs');

function release(overrides = {}) {
  return {platform: 'windows', version: '0.1.1', channel: 'preview', title: 'Focus Studio Desktop 0.1.1',
    published_at: '2026-10-14T12:00:00Z', download_url: `${SITE_ORIGIN}/api/download/windows?channel=preview&version=0.1.1`,
    release_url: 'https://github.com/stevenchengxy/focus-studio/releases/tag/desktop-v0.1.1', minimum_os: null, ...overrides};
}
const response = (data, status = 200) => new Response(JSON.stringify(data), {status, headers: {'content-type': 'application/json'}});
const tick = () => new Promise(resolve => setImmediate(resolve));
async function controller(t, overrides = {}) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'focus-updates-'));
  const notices = [], opened = [], calls = []; let now = 1_000_000; let idle = true;
  const value = new UpdateController({directory, platform: 'win32', version: '0.1.0', now: () => now,
    isIdle: () => idle, present: async notice => { notices.push(notice); return 'later'; },
    openExternal: async url => { opened.push(url); }, fetcher: async (...args) => { calls.push(args); return response(release()); }, ...overrides});
  t.after(async () => { value.dispose(); await value.writes.catch(() => {}); await fs.rm(directory, {recursive: true, force: true}); });
  return {value, directory, notices, opened, calls, advance: ms => { now += ms; }, setIdle: flag => { idle = flag; }};
}

test('SemVer compares numeric and prerelease versions without offering a downgrade', () => {
  const versions = ['0.1.0', '0.1.1-alpha', '0.1.1-alpha.2', '0.1.1-alpha.10', '0.1.1-beta', '0.1.1-rc.1', '0.1.1', '0.2.0', '0.10.0', '1.0.0'];
  for (let i = 1; i < versions.length; i++) { assert.equal(compareVersions(versions[i], versions[i - 1]), 1); assert.equal(compareVersions(versions[i - 1], versions[i]), -1); }
  assert.equal(compareVersions('0.1.1+build.10', '0.1.1+build.9'), 0);
  for (const bad of ['v0.1.1', '0.01.1', '0.1', '1.2.3-01', '1.2.3\n', '1.2.99999999999999999999', null]) assert.equal(parseVersion(bad), null);
});

test('release metadata accepts stable in preview, rejects channel/platform mismatches and unsafe links', () => {
  const valid = release(); assert.equal(validateRelease(valid, 'windows', 'preview').version, '0.1.1');
  assert.equal(validateRelease(release({channel: 'stable'}), 'windows', 'preview').channel, 'stable');
  assert.throws(() => validateRelease(valid, 'windows', 'stable'));
  assert.throws(() => validateRelease(valid, 'linux', 'preview'));
  for (const bad of [valid.download_url.replace('https:', 'http:'), valid.download_url.replace('focus-studio.', 'evil-focus-studio.'),
    valid.download_url + '&redirect=https://evil.test', valid.download_url + '&version=0.1.1', valid.download_url + '#evil',
    valid.download_url.replace('/windows', '/linux'), valid.download_url.replace('version=0.1.1', 'version=0.0.1'),
    valid.download_url.replace('channel=preview', 'channel=stable'), valid.download_url.replace('https://', 'https://user@')]) {
    assert.equal(officialDownload(bad, 'windows', 'preview', '0.1.1'), false, bad);
    assert.throws(() => validateRelease(release({download_url: bad}), 'windows', 'preview'));
  }
  for (const bad of ['https://github.com.evil.test/stevenchengxy/focus-studio/releases/tag/1', 'https://github.com/other/repo/releases/tag/1',
    valid.release_url + '?next=https://evil.test', valid.release_url + '/another', 'javascript:alert(1)']) assert.throws(() => validateRelease(release({release_url: bad}), 'windows', 'preview'));
});

test('network checks are daily, public and redirect-free; automatic checks never download', async t => {
  const f = await controller(t); await f.value.check();
  assert.equal(f.calls.length, 1); assert.equal(f.calls[0][0], `${SITE_ORIGIN}/api/releases?platform=windows&channel=preview`);
  assert.deepEqual(f.calls[0][1].headers, {accept: 'application/json'}); assert.equal(f.calls[0][1].redirect, 'error');
  assert.equal(f.notices.length, 1); assert.equal(f.opened.length, 0);
  await f.value.check(); f.advance(DAY - 1); await f.value.check(); assert.equal(f.calls.length, 1);
  f.advance(1); await f.value.check(); assert.equal(f.calls.length, 2); assert.equal(f.notices.length, 1);
});

test('recording/exporting defers prompts until idle; only an explicit download opens the validated installer', async t => {
  let presentCount = 0;
  const f = await controller(t, {present: async () => { presentCount++; return 'download'; }});
  f.setIdle(false); await f.value.check(); assert.equal(presentCount, 0); assert.equal(f.opened.length, 0);
  await f.value.flush(); assert.equal(presentCount, 0);
  f.setIdle(true); await f.value.flush(); assert.equal(presentCount, 1); assert.deepEqual(f.opened, [release().download_url]);
  assert.equal(f.value.settings.notifiedVersion, '0.1.1');
});

test('simultaneous automatic/manual requests share one check and manual checks remain available for a previously dismissed release', async t => {
  let resolve; let calls = 0;
  const f = await controller(t, {fetcher: async () => { calls++; return new Promise(r => { resolve = r; }); }});
  const first = f.value.check(); const second = f.value.check({manual: true}); await tick(); resolve(response(release()));
  await Promise.all([first, second]); assert.equal(calls, 1); assert.equal(f.notices[0].manual, true);
  f.advance(10000); const third = f.value.check({manual: true}); await tick(); resolve(response(release())); await third;
  assert.equal(calls, 2); assert.equal(f.notices.length, 2);
  await f.value.check({manual: true}); assert.equal(calls, 2); assert.match(f.notices.at(-1).message, /wait a few seconds/);
});

test('errors are quiet for automatic checks and retry hourly; manual errors are actionable without leaking network data', async t => {
  let calls = 0;
  const f = await controller(t, {fetcher: () => { calls++; throw new Error('secret server details'); }});
  await f.value.check(); assert.equal(f.notices.length, 0); assert.equal(f.value.inFlight, null);
  f.advance(RETRY - 1); await f.value.check(); assert.equal(calls, 1);
  f.advance(1); await f.value.check(); assert.equal(calls, 2);
  f.advance(10000); await f.value.check({manual: true}); assert.equal(calls, 3); assert.match(f.notices[0].message, /Check your connection/);
  assert.equal(f.notices[0].message.includes('secret'), false);
});

test('404 and equal/older versions do not offer an installer', async t => {
  for (const [body, status] of [[{}, 404], [release({version: '0.1.0', download_url: release().download_url.replace('0.1.1', '0.1.0')}), 200],
    [release({version: '0.0.9', download_url: release().download_url.replace('0.1.1', '0.0.9')}), 200]]) {
    const f = await controller(t, {fetcher: async () => response(body, status)}); await f.value.check({manual: true});
    assert.equal(f.notices[0].kind, 'message'); assert.equal(f.opened.length, 0);
  }
});

test('settings survive restart; disabling automatic checks cancels a deferred automatic prompt', async t => {
  const f = await controller(t); f.setIdle(false); await f.value.check(); assert.ok(f.value.pending);
  f.value.setAutomatic(false); f.value.setChannel('stable'); await f.value.writes;
  const saved = JSON.parse(await fs.readFile(path.join(f.directory, 'updates.json'), 'utf8'));
  assert.equal(saved.automatic, false); assert.equal(saved.channel, 'stable'); assert.equal(f.value.pending, null);
  const restored = new UpdateController({directory: f.directory, platform: 'linux', version: '0.1.0', fetcher: () => assert.fail('automatic disabled')});
  await restored.load(); assert.equal(restored.platform, 'linux'); assert.equal(restored.settings.automatic, false); assert.equal(restored.settings.channel, 'stable');
  await restored.check(); restored.dispose();
  assert.equal((await fs.stat(path.join(f.directory, 'updates.json'))).mode & 0o777, 0o600);
  await fs.writeFile(path.join(f.directory, 'updates.json'), '{"channel":"other","automatic":"false","lastCheckedAt":"bad","token":"secret"}');
  const invalid = new UpdateController({directory: f.directory, platform: 'linux', version: '0.1.0'}); await invalid.load();
  assert.equal(invalid.settings.channel, 'preview'); assert.equal(invalid.settings.automatic, true); assert.equal(invalid.settings.token, undefined);
  invalid.dispose();
});

test('changing channel or closing the app during a request suppresses stale results', async t => {
  for (const action of ['channel', 'change-back', 'automatic-off', 'dispose']) {
    let deliver;
    const f = await controller(t, {fetcher: async () => new Promise(resolve => { deliver = resolve; })});
    const pending = f.value.check({manual: action !== 'automatic-off'}); await tick();
    if (action === 'channel') f.value.setChannel('stable');
    else if (action === 'change-back') { f.value.setChannel('stable'); f.value.setChannel('preview'); }
    else if (action === 'automatic-off') f.value.setAutomatic(false);
    else f.value.dispose();
    deliver(response(release())); await pending; assert.equal(f.notices.length, 0); assert.equal(f.opened.length, 0);
  }
});

test('closing an update dialog after disposal never opens a browser; response body size is bounded', async t => {
  let answer;
  const f = await controller(t, {present: async () => new Promise(resolve => { answer = resolve; })});
  const checking = f.value.check();
  while (!answer) await tick();
  f.value.dispose(); answer('download'); await checking; assert.equal(f.opened.length, 0);
  await assert.rejects(responseJSON(response({oversize: 'x'.repeat(32768)})), /too large/);
  await assert.rejects(responseJSON(new Response('not json')));
});
