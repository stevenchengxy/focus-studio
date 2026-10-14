'use strict';
// Exercise the actual hosted editor in sandboxed Chromium with only a synthetic
// canvas movie. No screen/microphone access, user account or provider is used.
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const fsSync = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {app, session, BrowserWindow} = require('electron');
const esbuild = require('../../website/node_modules/esbuild');
const website = path.resolve(__dirname, '../../website');
const directory = fsSync.mkdtempSync(path.join(os.tmpdir(), 'focus-free-studio-'));
app.setPath('userData', path.join(directory, 'profile'));
app.enableSandbox();
app.on("window-all-closed", () => {});
const origin = 'https://free-studio.test';
const watchdog = setTimeout(() => { console.error('Free Studio smoke timed out.'); app.exit(1); }, 45000);
const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(check) { for (let i = 0; i < 200; i++) { if (await check()) return; await wait(50); } throw new Error('UI condition timed out.'); }
app.whenReady().then(async () => {
  const bundle = path.join(directory, 'studio.js');
  const entry = `
import React from 'react';
import { createRoot } from 'react-dom/client';
import { DesktopGate } from '${website}/app/studio/desktop-gate';
import { savePendingExport } from '${website}/app/studio/local-export-store';
window.accountRequests = 0;
if (new URL(location.href).searchParams.has('desktop')) window.focusDesktop = {
  version:1, getCapabilities:async()=>({platform:'win32',systemAudio:'loopback',microphone:true}),
  request:async()=>{window.accountRequests++;throw new Error('Exports must not call account APIs');},
  setActivity:async()=>{}, onAccountChanged:()=>()=>{},
};
window.makeMovie = async () => {
  const canvas = document.createElement('canvas');canvas.width=320;canvas.height=180;
  const ctx=canvas.getContext('2d');const stream=canvas.captureStream(30);
  const recorder=new MediaRecorder(stream,{mimeType:'video/webm;codecs=vp8'});const chunks=[];
  const done=new Promise(resolve=>{recorder.onstop=()=>resolve(new Blob(chunks,{type:recorder.mimeType}));});
  recorder.ondataavailable=event=>{if(event.data.size)chunks.push(event.data);};recorder.start();
  for(let i=0;i<28;i++){ctx.fillStyle=i%2?'#7857ff':'#89c4db';ctx.fillRect(0,0,320,180);ctx.fillStyle='white';ctx.fillRect(i*8,60,30,30);await new Promise(resolve=>setTimeout(resolve,34));}
  recorder.stop();const blob=await done;stream.getTracks().forEach(t=>t.stop());return blob;
};
window.loadTestMovie = async () => {
  const blob=await window.makeMovie();
  // WebM live streams need a finite duration. Test the same import path using a
  // metadata fixture; the actual HTMLVideoElement still decodes the real movie.
  const video=document.querySelector('video');Object.defineProperty(video,'duration',{configurable:true,get:()=>0.8});
  const file=new File([blob],'offline-demo.webm',{type:blob.type});const dt=new DataTransfer();dt.items.add(file);
  const input=document.querySelector('input[type=file][accept="video/*"]');input.files=dt.files;input.dispatchEvent(new Event('change',{bubbles:true}));
};
window.seedLegacyRender = async () => savePendingExport({blob:await window.makeMovie(),exportId:crypto.randomUUID(),name:'legacy-export.webm',accountId:'different-old-account',reservationKey:crypto.randomUUID(),confirmed:false});
createRoot(document.getElementById('root')).render(<DesktopGate />);
`;
  const stub = path.join(directory, 'visual-stubs.jsx');
  await fs.writeFile(stub, `import React from '${website}/node_modules/react';export const Brand=()=> <a href="/">Focus Studio</a>;export const ThemeToggle=()=>null;`);
  await esbuild.build({stdin:{contents:entry,resolveDir:website,loader:'tsx'},outfile:bundle,bundle:true,jsx:'automatic',platform:'browser',format:'iife',define:{'process.env.NODE_ENV':'"production"'},alias:{'@/components/marketing/focus-home':stub,'@/components/theme/theme-toggle':stub},nodePaths:[path.join(website,'node_modules')],logLevel:'silent'});
  const bundleBytes = await fs.readFile(bundle);let networkAPICalls = 0;
  session.defaultSession.protocol.handle('https', request => {
    const url = new URL(request.url);assert.equal(url.origin, origin);
    if (url.pathname.startsWith('/api/')) { networkAPICalls++; return new Response('Network disabled', {status:503}); }
    if (url.pathname === '/studio.js') return new Response(bundleBytes, {headers:{'Content-Type':'text/javascript'}});
    return new Response('<!doctype html><html><body><div id="root"></div><script src="/studio.js"></script></body></html>',{headers:{'Content-Type':'text/html'}});
  });
  let permissions = 0;
  session.defaultSession.setPermissionRequestHandler((_wc, _permission, callback) => { permissions++; callback(false); });
  const window = new BrowserWindow({show:false,width:1200,height:900,webPreferences:{sandbox:true,contextIsolation:true,nodeIntegration:false,backgroundThrottling:false}});
  const wc=window.webContents;
  const ui=script=>wc.executeJavaScript(script, true);
  await window.loadURL(`${origin}/studio`);
  await until(()=>ui(`!!document.querySelector('.desktop-download-gate nav')`));
  assert.equal(await ui(`document.querySelectorAll('input[type=file],video,canvas').length`),0);
  assert.equal(await ui(`document.querySelectorAll('.desktop-download-gate nav a').length`),3);
  console.log('PASS: ordinary browsers receive downloads, without a recorder or media input.');
  await window.loadURL(`${origin}/studio?desktop=1`);
  await until(()=>ui(`!!document.querySelector('input[type=file][accept="video/*"]')`));
  assert.equal(await ui(`document.body.textContent.includes('Free local exports. No account required.')`),true);
  assert.equal(await ui(`document.body.textContent.includes('Connect account')`),false);
  await ui(`window.loadTestMovie()`);
  await until(()=>ui(`[...document.querySelectorAll('button')].some(b=>b.textContent.includes('Export video')&&!b.disabled)`));
  let downloads = 0;
  session.defaultSession.on('will-download', (_event, item) => {
    downloads++;item.setSavePath(path.join(directory, `render-${downloads}.webm`));
  });
  for(let i=1;i<=2;i++) {
    await ui(`[...document.querySelectorAll('button')].find(b=>b.textContent.includes('Export video')).click()`);
    await until(()=>ui(`!!document.querySelector('a.studio-download-again') && !document.querySelector('.studio-export-overlay')`));
    await until(async()=>downloads>=i && fsSync.existsSync(path.join(directory,`render-${i}.webm`)));
    assert.ok((await fs.stat(path.join(directory,`render-${i}.webm`))).size>0);
  }
  assert.equal(await ui('window.accountRequests'),0);assert.equal(networkAPICalls,0);
  console.log('PASS: two real synthetic video exports without sign-in, quota or account/export requests.');
  await ui(`window.seedLegacyRender()`);
  // New window exercises durable journal recovery without an account, including a
  // saved render associated with a different historical paid-era account.
  window.destroy();
  const recoveredWindow=new BrowserWindow({show:false,width:1200,height:900,webPreferences:{sandbox:true,contextIsolation:true,nodeIntegration:false,backgroundThrottling:false}});
  await recoveredWindow.loadURL(`${origin}/studio?desktop=1`);
  const recoveredUI=script=>recoveredWindow.webContents.executeJavaScript(script,true);
  await until(()=>recoveredUI(`[...document.querySelectorAll('button')].some(b=>b.textContent.includes('Save rendered video'))`));
  await recoveredUI(`[...document.querySelectorAll('button')].find(b=>b.textContent.includes('Save rendered video')).click()`);
  await until(async()=>downloads===3&&fsSync.existsSync(path.join(directory,'render-3.webm')));
  assert.equal(await recoveredUI('window.accountRequests'),0);assert.equal(networkAPICalls,0);assert.equal(permissions,0);
  console.log('PASS: old saved render recovered locally; no screen, microphone or account permission requests.');
  recoveredWindow.destroy();clearTimeout(watchdog);app.exit(0);
}).catch(error=>{clearTimeout(watchdog);console.error(error);app.exit(1);});
