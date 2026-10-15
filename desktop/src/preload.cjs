'use strict';
const {contextBridge, ipcRenderer} = require('electron');
// Never expose ipcRenderer, Electron objects, arbitrary channels or tokens.
contextBridge.exposeInMainWorld('focusDesktop', {
  version: 1,
  getCapabilities: () => ipcRenderer.invoke('focus:capabilities'),
  request: (input) => ipcRenderer.invoke('focus:request', input),
  startSignIn: () => ipcRenderer.invoke('focus:sign-in'),
  signOut: () => ipcRenderer.invoke('focus:sign-out'),
  communityStatus: () => ipcRenderer.invoke('focus:community-status'),
  startCommunityConnection: () => ipcRenderer.invoke('focus:community-start'),
  cancelCommunityConnection: () => ipcRenderer.invoke('focus:community-cancel'),
  retryCommunityConfirmation: () => ipcRenderer.invoke('focus:community-retry'),
  disconnectCommunity: () => ipcRenderer.invoke('focus:community-disconnect'),
  onCommunityChanged: fn => {
    if (typeof fn !== 'function') throw new TypeError('Expected a callback.');
    const listener = () => fn();
    ipcRenderer.on('focus:community-changed', listener);
    return () => ipcRenderer.removeListener('focus:community-changed', listener);
  },
  setActivity: input => ipcRenderer.invoke('focus:activity', input),
  onAccountChanged: (fn) => {
    if (typeof fn !== 'function') throw new TypeError('Expected a callback.');
    const listener = () => fn();
    ipcRenderer.on('focus:account-changed', listener);
    return () => ipcRenderer.removeListener('focus:account-changed', listener);
  }
});
