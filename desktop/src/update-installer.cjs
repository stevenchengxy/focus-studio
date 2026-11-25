'use strict';

const fs = require('node:fs');
const fsp = require('node:fs/promises');
const path = require('node:path');
const crypto = require('node:crypto');
const {Readable, Transform} = require('node:stream');
const {pipeline} = require('node:stream/promises');
const {spawn} = require('node:child_process');
const {once} = require('node:events');
const {responseJSON} = require('./updates.cjs');

const PUBLIC_KEY = 'bHePExwYkgIPn6mY9UBKg5w9b2TKuTzTD3PiAsYiC4c=';
const spki = Buffer.from('302a300506032b6570032100', 'hex');
const updateKey = crypto.createPublicKey({key: Buffer.concat([spki, Buffer.from(PUBLIC_KEY, 'base64')]), format: 'der', type: 'spki'});
const ASSETS = {windows: 'windows-x64.exe', appimage: 'linux-x86_64.AppImage', deb: 'linux-amd64.deb'};
const MAX_SIZE = 512 * 1024 * 1024;

function verifyManifest(data, release, kind, key = updateKey) {
  const tag = new URL(release.release_url).pathname.split('/').pop();
  const assetName = `Focus-Studio-Desktop-${release.version}-${ASSETS[kind]}`;
  if (!Object.hasOwn(ASSETS, kind) || !data || data.tag !== tag || data.version !== release.version ||
    data.platform !== release.platform || data.channel !== release.channel || data.assetName !== assetName ||
    !Number.isSafeInteger(data.byteCount) || data.byteCount < 1 || data.byteCount > MAX_SIZE ||
    !/^[0-9a-f]{64}$/.test(data.sha256) || typeof data.signature !== 'string' ||
    !/^[A-Za-z0-9+/]{86}==$/.test(data.signature)) throw new Error('Invalid update manifest.');
  const message = ['Focus Studio desktop update v1', tag, data.platform, data.version, data.channel, assetName, String(data.byteCount), data.sha256, ''].join('\n');
  if (!crypto.verify(null, Buffer.from(message, 'ascii'), key, Buffer.from(data.signature, 'base64'))) {
    throw new Error('Update signature verification failed.');
  }
  return data;
}

async function fetchAsset(url, fetcher, signal) {
  for (let hop = 0; hop < 5; hop++) {
    const response = await fetcher(url, {signal, redirect: 'manual', credentials: 'omit'});
    if (response.status === 200) return response;
    await response.body?.cancel();
    if (![301, 302, 303, 307, 308].includes(response.status) || !response.headers.get('location')) break;
    url = new URL(response.headers.get('location'), url);
    if (url.protocol !== 'https:' || url.username || url.password || url.port || !['github.com', 'release-assets.githubusercontent.com', 'objects.githubusercontent.com'].includes(url.hostname)) break;
  }
  throw new Error('The verified update package is unavailable.');
}

async function verifyFile(file, manifest) {
  const stat = await fsp.lstat(file);
  if (!stat.isFile() || stat.size !== manifest.byteCount) throw new Error('Incomplete update download.');
  const hash = crypto.createHash('sha256');
  for await (const chunk of fs.createReadStream(file)) hash.update(chunk);
  if (hash.digest('hex') !== manifest.sha256) throw new Error('Update checksum verification failed.');
}

async function downloadPackage({release, kind, directory, signal, progress, fetcher = fetch}) {
  const tag = new URL(release.release_url).pathname.split('/').pop();
  const name = `Focus-Studio-Desktop-${release.version}-${ASSETS[kind]}`;
  const url = `https://github.com/stevenchengxy/focus-studio/releases/download/${encodeURIComponent(tag)}/${encodeURIComponent(name)}`;
  const manifest = verifyManifest(await responseJSON(await fetchAsset(url + '.update.json', fetcher, signal)), release, kind);
  const cache = path.join(directory, 'update-packages', manifest.sha256);
  await fsp.mkdir(cache, {recursive: true, mode: 0o700});
  const file = path.join(cache, name);
  try {
    await verifyFile(file, manifest);
    return {file, manifest, kind};
  } catch (error) {
    if (error.code !== 'ENOENT') await fsp.unlink(file);
  }
  const temporary = path.join(cache, crypto.randomUUID() + '.part');
  try {
    const response = await fetchAsset(url, fetcher, signal);
    let size = 0;
    const hash = crypto.createHash('sha256');
    const inspect = new Transform({transform(chunk, _encoding, done) {
      size += chunk.length;
      if (size > manifest.byteCount) return done(new Error('Update size exceeds the signed manifest.'));
      hash.update(chunk); progress(size / manifest.byteCount); done(null, chunk);
    }});
    await pipeline(Readable.fromWeb(response.body), inspect, fs.createWriteStream(temporary, {flags: 'wx', mode: 0o600}), {signal});
    if (size !== manifest.byteCount || hash.digest('hex') !== manifest.sha256) throw new Error('Update checksum verification failed.');
    await fsp.rename(temporary, file);
    return {file, manifest, kind};
  } finally {
    progress(-1);
    await fsp.unlink(temporary).catch(() => {});
  }
}

// Arguments are positional. The executable path is never interpolated into
// shell code. Keep a hard link to the old image until the new process survives
// its initial startup. APPIMAGE stays at its original location on both paths.
const APPIMAGE_HANDOFF = `
parent=$1
target=$2
staged=$3
backup=$4
for i in $(seq 1 120); do
  if ! kill -0 "$parent" 2>/dev/null; then break; fi
  sleep 1
done
if kill -0 "$parent" 2>/dev/null; then rm -f -- "$staged" "$backup"; exit 1; fi
if ! mv -f -- "$staged" "$target"; then rm -f -- "$backup" "$staged"; "$target" & exit 1; fi
"$target" &
new_pid=$!
sleep 4
if kill -0 "$new_pid" 2>/dev/null; then rm -f -- "$backup"; else mv -f -- "$backup" "$target" && "$target" & fi
`;

async function spawnDetached(command, args, options = {}) {
  const child = spawn(command, args, {stdio: 'ignore', detached: true, ...options});
  await once(child, 'spawn');
  child.unref();
}

async function installPackage({pkg, isIdle, quit, relaunch, appImage = process.env.APPIMAGE, parent = process.pid, launch = spawnDetached}) {
  await verifyFile(pkg.file, pkg.manifest);
  const assertReady = () => { if (!isIdle()) throw new Error('Finish active work before restarting.'); };
  assertReady();
  if (pkg.kind === 'windows') {
    // NSIS detects the existing install scope and directory from the registry.
    await launch(pkg.file, ['--updated', '/S', '--force-run'], {windowsHide: false});
    quit();
    return;
  }
  if (pkg.kind === 'deb') {
    // The distribution's PolicyKit prompt owns administrator authorization.
    const child = spawn('/usr/bin/pkexec', ['/usr/bin/apt-get', '-y', '--no-remove', 'install', pkg.file], {stdio: 'ignore'});
    const [code] = await once(child, 'exit');
    if (code !== 0) throw new Error('The system package manager did not install the update.');
    assertReady(); relaunch(); quit();
    return;
  }
  if (pkg.kind !== 'appimage' || !appImage || !path.isAbsolute(appImage)) throw new Error('Open the installed AppImage to update.');
  const current = await fsp.lstat(appImage);
  if (!current.isFile() || !(current.mode & 0o111)) throw new Error('Open the installed AppImage to update.');
  const prefix = path.join(path.dirname(appImage), '.focus-studio-' + crypto.randomUUID());
  const staged = prefix + '.next', backup = prefix + '.previous';
  try {
    await fsp.copyFile(pkg.file, staged, fs.constants.COPYFILE_EXCL);
    await verifyFile(staged, pkg.manifest);
    await fsp.chmod(staged, current.mode & 0o777);
    await fsp.link(appImage, backup);
    assertReady();
    await launch('/bin/sh', ['-c', APPIMAGE_HANDOFF, 'focus-update', String(parent), appImage, staged, backup]);
  } catch (error) {
    await Promise.all([staged, backup].map(file => fsp.unlink(file).catch(() => {})));
    throw error;
  }
  quit();
}

module.exports = {PUBLIC_KEY, verifyManifest, verifyFile, downloadPackage, installPackage, fetchAsset, APPIMAGE_HANDOFF};
