'use strict';
const {contextBridge, ipcRenderer} = require('electron');
contextBridge.exposeInMainWorld('captureChooser', {
  read: () => ipcRenderer.invoke('focus:chooser-read'),
  select: (id, audio) => ipcRenderer.invoke('focus:chooser-select', {id, audio}),
  cancel: () => ipcRenderer.invoke('focus:chooser-cancel')
});
