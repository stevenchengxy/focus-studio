'use strict';

// Runs only on disposable native CI desktops. Start with the public 0.1.3
// installers, then exercise the same installation function used by the app.
const assert = require('node:assert/strict');
const {execFileSync} = require('node:child_process');
const {createHash} = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {setTimeout: delay} = require('node:timers/promises');
const asar = require('@electron/asar');
const {installPackage} = require('../src/update-installer.cjs');
const {version} = require('../package.json');

const current = path.resolve(__dirname, '../dist');
const baseline = 'https://github.com/stevenchengxy/focus-studio/releases/download/v1.14.6-preview.1/';
const formats = {
  windows: ['windows-x64.exe', '85a2faf4f20832b38674191ff3ab570f73c2cb42a72236eb045d20c39a579471'],
  deb: ['linux-amd64.deb', 'f433ea5ea42a3054ab70aaf53d78b229625cdfa16f7e0a70f36665e330835cd5'],
  appimage: ['linux-x86_64.AppImage', '1052c703724de7fb946599a965a2373149e902f58afa02760114e9fc17b4f5e3'],
};
const candidate = kind => path.join(current, `Focus-Studio-Desktop-${version}-${formats[kind][0]}`);

async function digest(file) {
  const hash = createHash('sha256');
  for await (const chunk of fs.createReadStream(file)) hash.update(chunk);
  return hash.digest('hex');
}

async function previous(kind, directory) {
  const name = 'Focus-Studio-Desktop-0.1.3-' + formats[kind][0];
  const file = path.join(directory, name);
  execFileSync(process.platform === 'win32' ? 'curl.exe' : 'curl',
    ['--fail', '--silent', '--show-error', '--location', '--retry', '3', '--max-time', '180', '--output', file, baseline + name]);
  assert.equal(await digest(file), formats[kind][1], 'Published baseline checksum');
  return file;
}

async function update(kind, appImage) {
  const file = candidate(kind);
  const manifest = {byteCount: fs.statSync(file).size, sha256: await digest(file)};
  let quit = false, relaunch = false;
  await installPackage({pkg: {kind, file, manifest}, appImage,
    isIdle: () => true, quit: () => { quit = true; }, relaunch: () => { relaunch = true; }});
  assert.equal(quit, true);
  if (kind === 'deb') assert.equal(relaunch, true);
}

function installedVersion(directory) {
  const file = path.join(directory, 'resources', 'app.asar');
  asar.uncache(file);
  return JSON.parse(asar.extractFile(file, 'package.json')).version;
}

async function waitFor(check, description) {
  for (let attempt = 0; attempt < 90; attempt++) {
    try { if (await check()) return; } catch { /* The installer is replacing files. */ }
    await delay(1000);
  }
  throw new Error('Timed out waiting for ' + description);
}

async function windows(directory) {
  const original = path.join(directory, 'custom-install');
  const previousInstaller = await previous('windows', directory);
  execFileSync(previousInstaller, ['/S', '/allusers', '/D=' + original], {timeout: 120000});
  assert.equal(installedVersion(original), '0.1.3');
  await update('windows');
  await waitFor(() => installedVersion(original) === version, 'NSIS to upgrade the existing all-users installation');
  console.log('PASS: Windows updated the original custom installation to ' + version);
}

async function linux(directory) {
  const oldDeb = await previous('deb', directory);
  execFileSync('sudo', ['apt-get', '-y', '--no-remove', 'install', oldDeb], {stdio: 'inherit'});
  const installed = '/opt/Focus Studio Desktop';
  assert.equal(installedVersion(installed), '0.1.3');
  // A headless runner has no user to answer a PolicyKit dialog. Already
  // authorized, the helper below still uses the real pkexec + apt-get path.
  execFileSync('sudo', [process.execPath, __filename, 'install-deb'], {timeout: 120000, stdio: 'inherit'});
  assert.equal(installedVersion(installed), version);
  assert.equal(execFileSync('dpkg-query', ['-W', '-f=${Version}', 'focus-studio-desktop'], {encoding: 'utf8'}), version);
  console.log('PASS: Debian upgraded the installed package to ' + version);

  const image = await previous('appimage', directory);
  fs.chmodSync(image, 0o755);
  const expected = await digest(candidate('appimage'));
  execFileSync(process.execPath, [__filename, 'install-appimage', image], {
    env: {...process.env, APPIMAGE_EXTRACT_AND_RUN: '1'}, stdio: 'inherit',
  });
  // The detached handoff waits for its parent to exit, then removes the
  // previous executable only after the new process survives startup.
  await waitFor(async () => {
    if (fs.readdirSync(directory).some(name => name.startsWith('.focus-studio-'))) return false;
    return await digest(image) === expected;
  }, 'the new AppImage to survive startup at the original path');
  console.log('PASS: AppImage replaced the original image and survived its launch check');
}

async function main() {
  if (process.argv[2] === 'install-deb') return update('deb');
  if (process.argv[2] === 'install-appimage') return update('appimage', process.argv[3]);
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'focus-upgrade-'));
  if (process.platform === 'win32') return windows(directory);
  if (process.platform === 'linux') return linux(directory);
  throw new Error('This check requires a Windows or Linux runner.');
}

main().catch(error => { console.error(error); process.exitCode = 1; });
