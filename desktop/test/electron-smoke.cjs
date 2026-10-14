'use strict';
// Starts the real sandboxed Electron app, intercepting its one HTTPS host with a
// local fixture. This tests the bridge and chooser without recording the desktop,
// accessing a real account, or weakening the packaged application.
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const fsSync = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {app, session, BrowserWindow, nativeImage} = require('electron');
const {createDesktop, registerScheme} = require('../src/main.cjs');
const {SITE_ORIGIN, STUDIO_URL} = require('../src/policy.cjs');
registerScheme();
app.enableSandbox();
const directory = fsSync.mkdtempSync(path.join(os.tmpdir(), 'focus-electron-smoke-'));
app.setPath('userData', directory);
app.setPath('sessionData', directory);
const watchdog = setTimeout(() => { console.error('Electron smoke timed out.'); app.exit(1); }, 30000);
app.whenReady().then(async () => {
  const remoteSession = session.fromPartition('persist:focus-studio-v1');
  let permissionHandler;
  const originalSetPermission = remoteSession.setPermissionRequestHandler.bind(remoteSession);
  remoteSession.setPermissionRequestHandler = handler => { permissionHandler = handler; originalSetPermission(handler); };
  remoteSession.protocol.handle('https', request => {
    assert.equal(new URL(request.url).origin, SITE_ORIGIN);
    return new Response('<!doctype html><html><head><meta http-equiv="Content-Security-Policy" content="default-src \'none\'; script-src \'self\'; frame-src \'none\'"></head><body><h1>Focus Studio smoke fixture</h1></body></html>', {headers: {'content-type': 'text/html'}});
  });
  const desktop = await createDesktop({show: false, checkUpdates: false});
  console.log('Smoke: main window loaded.');
  const wc = desktop.window.webContents;
  const preferences = wc.getLastWebPreferences();
  assert.equal(preferences.sandbox, true); assert.equal(preferences.contextIsolation, true); assert.equal(preferences.nodeIntegration, false);
  const bridge = await wc.executeJavaScript(`(async () => ({node:typeof require,process:typeof process,version:window.focusDesktop.version,caps:await window.focusDesktop.getCapabilities()}))()`);
  assert.equal(bridge.node, 'undefined'); assert.equal(bridge.process, 'undefined'); assert.equal(bridge.version, 1);
  assert.equal(bridge.caps.platform, process.platform);
  assert.equal(await wc.executeJavaScript(`window.focusDesktop.setActivity({recording:false,exporting:false}).then(()=>true)`), true);
  assert.equal(await wc.executeJavaScript(`window.focusDesktop.setActivity({recording:'false',exporting:false}).then(()=>false,()=>true)`), true);
  assert.equal(await wc.executeJavaScript(`window.focusDesktop.setActivity({recording:false,exporting:false,path:'/tmp'}).then(()=>false,()=>true)`), true);
  const badRequest = await wc.executeJavaScript(`window.focusDesktop.request({path:'https://evil.test',method:'GET'}).then(()=>false,()=>true)`);
  assert.equal(badRequest, true);
  const anonymous = await wc.executeJavaScript(`window.focusDesktop.request({path:'/api/account',method:'GET'})`);
  assert.equal(anonymous.status, 401); assert.equal(anonymous.body.authenticated, false);
  // Invoke the installed camera permission policy without asking the OS for a
  // camera device. CI and local tests never need real microphone/camera access.
  const cameraAllowed = await new Promise(resolve => permissionHandler(wc, 'media', resolve,
    {isMainFrame: true, requestingUrl: STUDIO_URL, mediaTypes: ['video']}));
  assert.equal(cameraAllowed, false);
  console.log('Smoke: bridge and permission checks passed.');
  await wc.executeJavaScript(`location.href='https://evil.test/'`);
  await new Promise(resolve => setTimeout(resolve, 50)); assert.equal(wc.getURL(), STUDIO_URL);
  // Exercise the actual trusted local chooser and its separate preload.
  const choosing = desktop.capture.choose([{id: 'screen:smoke', name: '<script>Window title</script>', thumbnail: nativeImage.createEmpty()}], true);
  const chooser = BrowserWindow.getAllWindows().find(window => window !== desktop.window);
  if (chooser.webContents.isLoading()) await new Promise(resolve => chooser.webContents.once('did-finish-load', resolve));
  const sourceData = await chooser.webContents.executeJavaScript('window.captureChooser.read()');
  assert.equal(sourceData.sources[0].name, '<script>Window title</script>');
  assert.equal(await chooser.webContents.executeJavaScript('typeof window.focusDesktop'), 'undefined');
  void chooser.webContents.executeJavaScript(`window.captureChooser.select('screen:smoke',false)`).catch(() => {});
  assert.deepEqual(await choosing, {id: 'screen:smoke', audio: false});
  console.log('Smoke: trusted chooser passed.');
  await wc.loadURL('focus-desktop://shell/unavailable.html');
  assert.equal(await wc.executeJavaScript(`window.focusDesktop.getCapabilities().then(()=>false,()=>true)`), true);
  assert.equal(await wc.executeJavaScript(`window.focusDesktop.setActivity({recording:false,exporting:false}).then(()=>false,()=>true)`), true);
  desktop.window.destroy(); clearTimeout(watchdog);
  console.log('PASS: real Electron sandbox, account bridge, origin rejection, camera denial, chooser isolation, and offline privilege rejection.');
  app.exit(0);
}).catch(error => { clearTimeout(watchdog); console.error(error); app.exit(1); });
// The OS temporary directory is intentionally left for its normal cleanup;
// Chromium may flush profile metadata after Electron emits its quit event.
