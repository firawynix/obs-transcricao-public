const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('obsTranscricao', {
  choose: () => ipcRenderer.invoke('media:choose'),
  prepare: () => ipcRenderer.invoke('setup:prepare'),
  state: () => ipcRenderer.invoke('setup:state'),
  start: options => ipcRenderer.invoke('job:start', options),
  cancel: () => ipcRenderer.invoke('job:cancel'),
  installObs: () => ipcRenderer.invoke('obs:install'),
  open: target => ipcRenderer.invoke('path:open', target),
  onProgress: callback => ipcRenderer.on('setup:progress', (_event, value) => callback(value)),
  onLog: callback => ipcRenderer.on('job:log', (_event, value) => callback(value)),
  onState: callback => ipcRenderer.on('job:state', (_event, value) => callback(value)),
  onLaunch: callback => ipcRenderer.on('launch:file', (_event, value) => callback(value))
});
