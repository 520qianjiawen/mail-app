'use strict';
const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('mailDesk', Object.freeze({
  getState: () => ipcRenderer.invoke('desk:state'),
  open: region => ipcRenderer.invoke('desk:open', region),
  switchAccount: id => ipcRenderer.invoke('desk:switch-account', id),
  showInboxes: () => ipcRenderer.invoke('desk:inboxes'),
  moreInboxes: () => ipcRenderer.invoke('desk:inboxes-more'),
  openInboxMessage: key => ipcRenderer.invoke('desk:inboxes-open', key),
  showAccountForm: mode => ipcRenderer.invoke('desk:account-form', mode),
  closeAccountForm: () => ipcRenderer.invoke('desk:account-form-close'),
  submitAccount: value => ipcRenderer.invoke('desk:account-submit', value),
  navigate: direction => ipcRenderer.invoke('desk:navigate', direction),
  reload: () => ipcRenderer.invoke('desk:reload'), home: () => ipcRenderer.invoke('desk:home'),
  onState: callback => {
    const listener = (_event, value) => callback(value);
    ipcRenderer.on('desk:state-changed', listener);
    return () => ipcRenderer.removeListener('desk:state-changed', listener);
  }
}));
