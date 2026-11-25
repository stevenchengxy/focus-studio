'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const crypto = require('node:crypto');
const os = require('node:os');
const path = require('node:path');
const {execFile} = require('node:child_process');
const {promisify} = require('node:util');
const {PUBLIC_KEY, verifyManifest, verifyFile, fetchAsset, installPackage, APPIMAGE_HANDOFF} = require('../src/update-installer.cjs');

const release = {version: '0.1.4', platform: 'windows', channel: 'preview',
  release_url: 'https://github.com/stevenchengxy/focus-studio/releases/tag/v1.14.12-preview.1'};
const digest = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
async function fixture(t) {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'focus-update-package-'));
  t.after(() => fs.rm(dir, {recursive: true, force: true}));
  return dir;
}

test('desktop and macOS pin the same Ed25519 release key and bind each asset to its channel, tag, platform and exact bytes', async () => {
  const plist = await fs.readFile(path.join(__dirname, '../../Resources/Info.plist'), 'utf8');
  assert.equal(plist.match(/<key>FocusStudioUpdatePublicKey<\/key>\s*<string>([^<]+)<\/string>/)[1], PUBLIC_KEY);
  const {publicKey, privateKey} = crypto.generateKeyPairSync('ed25519');
  const m = {tag: 'v1.14.12-preview.1', platform: 'windows', version: '0.1.4', channel: 'preview',
    assetName: 'Focus-Studio-Desktop-0.1.4-windows-x64.exe', byteCount: 4, sha256: digest('demo')};
  m.signature = crypto.sign(null, Buffer.from(['Focus Studio desktop update v1', m.tag, m.platform, m.version,
    m.channel, m.assetName, '4', m.sha256, ''].join('\n')), privateKey).toString('base64');
  assert.equal(verifyManifest(m, release, 'windows', publicKey), m);
  for (const bad of [{tag: 'v1.14.13'}, {channel: 'stable'}, {platform: 'linux'}, {byteCount: 5},
    {sha256: digest('evil')}, {assetName: '../update.exe'}, {version: '0.1.5'}]) {
    assert.throws(() => verifyManifest({...m, ...bad}, release, 'windows', publicKey));
  }
  assert.throws(() => verifyManifest(m, release, 'windows'));
});

test('refuses redirects outside GitHub release storage', async () => {
  await assert.rejects(fetchAsset(new URL(release.release_url), async () =>
    new Response(null, {status: 302, headers: {location: 'https://example.com/file.exe'}})), /unavailable/);
});

test('rechecks the downloaded file and busy state before any operating system installer starts', async t => {
  const file = path.join(await fixture(t), 'candidate');
  await fs.writeFile(file, 'demo');
  const manifest = {sha256: digest('demo'), byteCount: 4};
  await verifyFile(file, manifest);
  const options = {pkg: {file, manifest, kind: 'windows'}, isIdle: () => false, quit: () => assert.fail('must stay open')};
  await assert.rejects(installPackage(options), /active work/);
  await fs.writeFile(file, 'oops');
  await assert.rejects(installPackage(options), /checksum/);
  await fs.writeFile(file, 'longer');
  await assert.rejects(installPackage(options), /Incomplete/);
});

test('Windows hands off to NSIS in the existing install scope before quitting', async t => {
  const file = path.join(await fixture(t), 'test installer.exe');
  await fs.writeFile(file, 'demo');
  const events = [];
  await installPackage({
    pkg: {file, manifest: {sha256: digest('demo'), byteCount: 4}, kind: 'windows'},
    isIdle: () => true,
    launch: async (command, args) => { events.push([command, args]); },
    quit: () => events.push('quit'),
  });
  assert.deepEqual(events, [[file, ['--updated', '/S', '--force-run']], 'quit']);
});

test('AppImage startup failure restores the previous executable at its original path', {skip: process.platform === 'win32'}, async t => {
  const dir = await fixture(t);
  const target = path.join(dir, 'Focus Studio.AppImage'), next = path.join(dir, 'new image'), previous = path.join(dir, 'old image');
  await fs.writeFile(target, '#!/bin/sh\nexit 0\n', {mode: 0o700});
  await fs.link(target, previous);
  await fs.writeFile(next, '#!/bin/sh\nexit 1\n', {mode: 0o700});
  await promisify(execFile)('/bin/sh', ['-c', APPIMAGE_HANDOFF, 'focus-update-test', '2147483647', target, next, previous]);
  assert.equal(await fs.readFile(target, 'utf8'), '#!/bin/sh\nexit 0\n');
  await assert.rejects(fs.stat(previous), {code: 'ENOENT'});
});
