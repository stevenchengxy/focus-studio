'use strict';
const {app, BrowserWindow, desktopCapturer, dialog, ipcMain, Menu, protocol, safeStorage, session, shell} = require('electron');
const fs = require('node:fs/promises');
const path = require('node:path');
const {SITE_ORIGIN, STUDIO_URL, trustedURL, externalURL, trustedIPC, capabilities} = require('./policy.cjs');
const {AccountClient} = require('./account.cjs');
const {TokenVault} = require('./vault.cjs');
const {CommunityClient, CommunityVault} = require('./community.cjs');
const {CaptureController} = require('./capture.cjs');
const {UpdateController} = require('./updates.cjs');

const SHELL_ORIGIN = 'focus-desktop://shell';
const safePreferences = {nodeIntegration: false, nodeIntegrationInWorker: false, nodeIntegrationInSubFrames: false,
  contextIsolation: true, sandbox: true, webSecurity: true, allowRunningInsecureContent: false,
  webviewTag: false, navigateOnDragDrop: false, spellcheck: false};

function registerScheme() {
  protocol.registerSchemesAsPrivileged([{scheme: 'focus-desktop', privileges: {standard: true, secure: true, supportFetchAPI: true}}]);
}

async function createDesktop({show = true, checkUpdates = true} = {}) {
  const remoteSession = session.fromPartition('persist:focus-studio-v1');
  const localSession = session.fromPartition('focus-studio-shell');
  const files = {'/chooser.html': 'text/html', '/chooser.js': 'text/javascript', '/shell.css': 'text/css', '/unavailable.html': 'text/html'};
  const serveLocal = async request => {
    const url = new URL(request.url);
    if (url.host !== 'shell' || !files[url.pathname]) return new Response('Not found', {status: 404});
    return new Response(await fs.readFile(path.join(__dirname, url.pathname.slice(1))), {headers: {'content-type': files[url.pathname]}});
  };
  await localSession.protocol.handle('focus-desktop', serveLocal);
  await remoteSession.protocol.handle('focus-desktop', serveLocal);
  localSession.setPermissionCheckHandler(() => false);
  localSession.setPermissionRequestHandler((_wc, _permission, callback) => callback(false));
  localSession.setDevicePermissionHandler(() => false);

  let mainWindow = new BrowserWindow({width: 1440, height: 940, minWidth: 840, minHeight: 620,
    show: false, backgroundColor: '#111218', title: 'Focus Studio Desktop',
    webPreferences: {...safePreferences, session: remoteSession, preload: path.join(__dirname, 'preload.cjs')}});
  let chooser = null;
  let pendingChoice = null;
  let microphoneGranted = false;
  let microphonePrompt = false;
  let pairingPrompt = false;
  // An older web editor may not report activity. Treat unknown activity as busy
  // so an update dialog can never interrupt a recording from that editor.
  let activity = null;
  const contents = () => mainWindow?.webContents;
  const vault = new TokenVault({directory: app.getPath('userData'), safeStorage});
  const onAccountChanged = () => { if (contents() && !contents().isDestroyed()) contents().send('focus:account-changed'); };
  const account = new AccountClient({vault, openExternal: url => shell.openExternal(url), onChanged: onAccountChanged});
  const communityVault = new CommunityVault({directory: app.getPath('userData'), safeStorage});
  const community = new CommunityClient({vault: communityVault, isPackaged: () => app.isPackaged,
    openExternal: url => shell.openExternal(url),
    onChanged: () => { if (contents() && !contents().isDestroyed()) contents().send('focus:community-changed'); }});
  const requireTrusted = event => { if (!trustedIPC(event, contents())) throw new Error('This action is only available in Studio.'); };
  ipcMain.handle('focus:capabilities', event => { requireTrusted(event); return {...capabilities(process.platform), version: app.getVersion(), secureTokenStorage: vault.durable()}; });
  ipcMain.handle('focus:request', (event, input) => { requireTrusted(event); return account.request(input); });
  ipcMain.handle('focus:sign-in', async event => {
    requireTrusted(event);
    if (pairingPrompt) throw new Error('A connection request is already open.');
    if (account.pairing) return account.startSignIn();
    pairingPrompt = true;
    try {
      const answer = await dialog.showMessageBox(mainWindow, {type: 'question', title: 'Connect your account',
        message: 'Continue in your browser', detail: 'Sign in, then approve the matching device code. Your account token stays in this desktop app.' +
          (vault.durable() ? '' : '\nNo secure system keyring is available. Your login will last only until you close the app.'),
        buttons: ['Continue', 'Cancel'], defaultId: 0, cancelId: 1, noLink: true});
      requireTrusted(event);
      if (answer.response !== 0) throw new Error('Connection cancelled.');
      return await account.startSignIn();
    } finally { pairingPrompt = false; }
  });
  ipcMain.handle('focus:sign-out', event => { requireTrusted(event); return account.signOut(); });
  // Only these fixed actions reach the community credential. The general account
  // request bridge always uses AccountClient and cannot select the community vault.
  for (const [channel, action] of Object.entries({
    'focus:community-status': () => community.status(),
    'focus:community-start': () => community.start(),
    'focus:community-cancel': () => community.cancel(),
    'focus:community-retry': () => community.retry(),
    'focus:community-disconnect': () => community.disconnect()
  })) ipcMain.handle(channel, event => { requireTrusted(event); return action(); });
  ipcMain.handle('focus:activity', (event, value) => {
    requireTrusted(event);
    if (!value || typeof value.recording !== 'boolean' || typeof value.exporting !== 'boolean' ||
        Object.keys(value).some(key => !['recording', 'exporting'].includes(key))) throw new Error('Invalid editor activity.');
    activity = {recording: value.recording, exporting: value.exporting};
    void updates.flush();
  });

  function chooserSender(event) {
    return chooser && !chooser.isDestroyed() && event.sender === chooser.webContents &&
      event.senderFrame === chooser.webContents.mainFrame && event.senderFrame.url === `${SHELL_ORIGIN}/chooser.html`;
  }
  ipcMain.handle('focus:chooser-read', event => {
    if (!chooserSender(event) || !pendingChoice) throw new Error('Capture request ended.');
    return {sources: pendingChoice.sources.map(source => ({id: source.id, name: source.name,
      kind: source.id.startsWith('screen:') ? 'screen' : 'window', thumbnail: source.thumbnail.toDataURL()})),
      audioRequested: pendingChoice.audioRequested, systemAudio: process.platform === 'win32'};
  });
  ipcMain.handle('focus:chooser-select', (event, value) => {
    if (!chooserSender(event) || !pendingChoice) throw new Error('Capture request ended.');
    if (!value || !pendingChoice.sources.some(source => source.id === value.id) || typeof value.audio !== 'boolean') throw new Error('Choose an available source.');
    pendingChoice.finish({id: value.id, audio: value.audio});
  });
  ipcMain.handle('focus:chooser-cancel', event => { if (chooserSender(event)) pendingChoice?.finish(null); });
  function choose(sources, audioRequested) {
    return new Promise(resolve => {
      chooser = new BrowserWindow({width: 900, height: 700, minWidth: 620, minHeight: 500,
        parent: mainWindow, modal: true, show: false, title: 'Choose what to record', backgroundColor: '#111218',
        webPreferences: {...safePreferences, session: localSession, preload: path.join(__dirname, 'chooser-preload.cjs')}});
      const thisChooser = chooser;
      let timer;
      const finish = value => {
        if (pendingChoice?.window !== thisChooser) return;
        pendingChoice = null; clearTimeout(timer); chooser = null;
        if (!thisChooser.isDestroyed()) thisChooser.destroy();
        resolve(value);
      };
      pendingChoice = {sources, audioRequested, finish, window: thisChooser};
      timer = setTimeout(() => finish(null), 120000);
      thisChooser.on('closed', () => finish(null));
      thisChooser.webContents.setWindowOpenHandler(() => ({action: 'deny'}));
      thisChooser.webContents.on('will-navigate', event => event.preventDefault());
      thisChooser.once('ready-to-show', () => thisChooser.show());
      thisChooser.loadURL(`${SHELL_ORIGIN}/chooser.html`).catch(() => finish(null));
    });
  }
  const capture = new CaptureController({getContents: contents, getSources: () => desktopCapturer.getSources({
    types: ['screen', 'window'], thumbnailSize: {width: 320, height: 200}, fetchWindowIcons: false}), choose});
  const updates = new UpdateController({directory: app.getPath('userData'), version: app.getVersion(),
    isIdle: () => Boolean(mainWindow && !mainWindow.isDestroyed() && mainWindow.isVisible() && mainWindow.isFocused() &&
      !capture.busy && !chooser && !microphonePrompt && !pairingPrompt && !community.active() &&
      (contents().getURL() === `${SHELL_ORIGIN}/unavailable.html` || (activity && !activity.recording && !activity.exporting))),
    openExternal: url => shell.openExternal(url),
    present: async notice => {
      if (notice.kind === 'available') {
        const result = await dialog.showMessageBox(mainWindow, {type: 'info', title: 'Focus Studio update',
          message: `Focus Studio Desktop ${notice.release.version} is available`,
          detail: `${notice.release.title}\nInstalled: ${app.getVersion()} · ${notice.release.channel === 'preview' ? 'Preview' : 'Stable'} release\nDownload the installer, then close Focus Studio before installing. Your saved media stays on this computer.`,
          buttons: ['Download update', 'Later'], defaultId: 0, cancelId: 1, noLink: true});
        return result.response === 0 ? 'download' : 'later';
      }
      await dialog.showMessageBox(mainWindow, {type: 'info', title: 'Focus Studio updates', message: notice.message, buttons: ['OK']});
      return 'dismiss';
    },
    onChanged: settings => {
      const menu = Menu.getApplicationMenu();
      const automatic = menu?.getMenuItemById('updates-automatic'); if (automatic) automatic.checked = settings.automatic;
      const stable = menu?.getMenuItemById('updates-stable'); if (stable) stable.checked = settings.channel === 'stable';
      const preview = menu?.getMenuItemById('updates-preview'); if (preview) preview.checked = settings.channel === 'preview';
    }});
  await updates.load();
  remoteSession.setDisplayMediaRequestHandler((request, callback) => { void capture.handle(request, callback); });
  remoteSession.setPermissionCheckHandler((wc, permission, origin, details) => {
    if (wc !== contents() || !trustedURL(origin) || details.isMainFrame !== true ||
      !trustedURL(details.requestingUrl ?? wc.getURL(), true)) return false;
    return permission === 'display-capture' || (permission === 'media' && details.mediaType === 'audio' && microphoneGranted);
  });
  remoteSession.setPermissionRequestHandler(async (wc, permission, callback, details) => {
    if (wc !== contents() || details.isMainFrame !== true || !trustedURL(details.requestingUrl ?? wc.getURL(), true)) { callback(false); return; }
    if (permission === 'display-capture') { callback(true); return; } // CaptureController still requires user selection.
    if (permission !== 'media' || !details.mediaTypes?.length || details.mediaTypes.some(type => type !== 'audio')) { callback(false); return; }
    if (microphoneGranted) { callback(true); return; }
    if (microphonePrompt) { callback(false); return; }
    microphonePrompt = true;
    try {
      const result = await dialog.showMessageBox(mainWindow, {type: 'question', title: 'Microphone permission',
        message: 'Allow Focus Studio to record your microphone?', detail: 'This permission lasts until you close the app. The editor shows when recording is active.',
        buttons: ['Allow microphone', 'Do not allow'], defaultId: 1, cancelId: 1, noLink: true});
      microphoneGranted = result.response === 0 && wc === contents() && trustedURL(wc.getURL(), true);
      callback(microphoneGranted);
    } catch { callback(false); } finally { microphonePrompt = false; }
  });
  remoteSession.setDevicePermissionHandler(() => false);

  function openAllowedExternal(url) { if (externalURL(url)) void shell.openExternal(url).catch(() => {}); }
  const wc = mainWindow.webContents;
  wc.setWindowOpenHandler(({url}) => { openAllowedExternal(url); return {action: 'deny'}; });
  wc.on('will-navigate', (event, url) => {
    if (!trustedURL(url, true)) { event.preventDefault(); openAllowedExternal(url); }
  });
  wc.on('will-frame-navigate', event => {
    if (!event.isMainFrame || !trustedURL(event.url, true)) event.preventDefault();
  });
  wc.on('will-redirect', (event, url) => { if (!trustedURL(url, true)) event.preventDefault(); });
  wc.on('will-attach-webview', event => event.preventDefault());
  wc.on('did-start-navigation', (_event, _url, isInPlace, isMainFrame) => {
    if (isMainFrame && !isInPlace) { activity = null; pendingChoice?.finish(null); }
  });
  remoteSession.on('will-download', (event, item, sender) => {
    const url = item.getURL();
    const ownBlob = typeof url === 'string' && url.startsWith(`blob:${SITE_ORIGIN}/`);
    if (sender !== wc || !trustedURL(wc.getURL(), true) || (!ownBlob && !trustedURL(url))) { event.preventDefault(); return; }
    // Chromium's normal Save As prompt remains mandatory; remote code supplies no path.
    item.setSaveDialogOptions({title: 'Save your Focus Studio export', defaultPath: path.basename(item.getFilename())});
  });

  Menu.setApplicationMenu(Menu.buildFromTemplate([
    {label: 'File', submenu: [
      {label: 'Reconnect to Studio', click: () => mainWindow?.loadURL(STUDIO_URL)},
      {label: 'Account in browser', click: () => openAllowedExternal(`${SITE_ORIGIN}/account`)},
      {type: 'separator'}, {role: 'quit'}]},
    {label: 'Edit', submenu: [{role: 'undo'}, {role: 'redo'}, {type: 'separator'}, {role: 'cut'}, {role: 'copy'}, {role: 'paste'}, {role: 'selectAll'}]},
    {label: 'View', submenu: [{role: 'reload'}, {role: 'resetZoom'}, {role: 'zoomIn'}, {role: 'zoomOut'}, {role: 'togglefullscreen'}]},
    {label: 'Help', submenu: [
      {label: 'Check for Updates…', enabled: Boolean(updates.platform), click: () => { void updates.check({manual: true}); }},
      {id: 'updates-automatic', label: 'Automatically check for updates', type: 'checkbox', checked: updates.settings.automatic,
        enabled: Boolean(updates.platform), click: item => updates.setAutomatic(item.checked)},
      {label: 'Update channel', enabled: Boolean(updates.platform), submenu: [
        {id: 'updates-preview', label: 'Stable and preview', type: 'radio', checked: updates.settings.channel === 'preview', click: () => updates.setChannel('preview')},
        {id: 'updates-stable', label: 'Stable only', type: 'radio', checked: updates.settings.channel === 'stable', click: () => updates.setChannel('stable')}]},
      {type: 'separator'},
      {label: 'About this desktop preview', click: () => dialog.showMessageBox(mainWindow, {
      type: 'info', message: `Focus Studio Desktop ${app.getVersion()}`, detail: 'Screen and window recording, browser-based demo editing, and account export access.\nWindows: optional full-system audio. Linux: microphone only.\nInternet required. Native macOS features and MCP are not included in this preview.'})}]}
  ]));
  mainWindow.once('ready-to-show', () => { if (show) mainWindow?.show(); });
  mainWindow.on('focus', () => { void updates.flush(); });
  mainWindow.on('closed', () => { pendingChoice?.finish(null); account.dispose(); community.dispose(); updates.dispose(); mainWindow = null; });
  void community.restore();
  await mainWindow.loadURL(STUDIO_URL).catch(async () => {
    if (mainWindow && !mainWindow.isDestroyed()) await mainWindow.loadURL(`${SHELL_ORIGIN}/unavailable.html`);
  });
  if (checkUpdates) updates.start();
  return {window: mainWindow, account, capture, vault, updates, community};
}

if (require.main === module) {
  registerScheme();
  app.enableSandbox();
  if (!app.requestSingleInstanceLock()) app.quit();
  else {
    app.on('second-instance', () => { const window = BrowserWindow.getAllWindows()[0]; if (window) { if (window.isMinimized()) window.restore(); window.focus(); } });
    app.whenReady().then(() => createDesktop()).catch(() => { dialog.showErrorBox('Focus Studio could not start', 'Please restart the app. Your saved recordings have not been removed.'); app.quit(); });
    app.on('window-all-closed', () => app.quit());
  }
}
module.exports = {createDesktop, registerScheme, safePreferences};
