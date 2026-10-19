'use strict';
const { app, BrowserWindow, WebContentsView, session, net, ipcMain, Menu, dialog, shell } = require('electron');
const path = require('node:path');
const { execFile } = require('node:child_process');
const { randomUUID } = require('node:crypto');
const { pathToFileURL } = require('node:url');
const { REGIONS, regionById, isAppURL, isMailURL, isLoginURL, canNavigateInside, externalURL, displayHost } = require('./policy.cjs');
const { readPreferences, savePreferences, newAccount, accountPartition, accountName } = require('./preferences.cjs');
const { UnifiedInbox, sessionGet, messageURL } = require('./unified-inbox.cjs');
const VERSION = require('../package.json').version;
app.setName('Mail Lite');
if (!app.isPackaged && process.env.MAIL_LITE_USER_DATA) app.setPath('userData', path.resolve(process.env.MAIL_LITE_USER_DATA));
app.enableSandbox();
const TOP = 44, BOTTOM = 28;
const SHELL_PATH = path.join(__dirname, '../ui/index.html');
const SHELL_URL = pathToFileURL(SHELL_PATH).href;
const SAFE_WEB = Object.freeze({ nodeIntegration: false, nodeIntegrationInSubFrames: false,
  contextIsolation: true, sandbox: true, webSecurity: true, webviewTag: false,
  allowRunningInsecureContent: false, navigateOnDragDrop: false, spellcheck: true });
let window, mailView, preferences, inbox;
let mailboxHome = '';
let quitting = false, quitPending = false, closePending = false, opening = false, clearing = false;
let activeDownloads = 0, completedDownloads = 0;
const configuredSessions = new WeakSet(), childWindows = new Set();
let state = { phase: 'welcome', mode: 'account', inbox: null, region: 'global', host: '', back: false, forward: false,
  loading: false, busy: false, canGoHome: false, authPage: false, accountDialog: null, accounts: [], activeAccountId: null,
  version: VERSION, downloads: '', error: '', regions: REGIONS.map(({ id, label }) => ({ id, label })) };
function activeAccount() { return preferences?.accounts.find(account => account.id === preferences.activeAccountId); }
function currentAccount() { if (activeAccount()) return loadAccount(activeAccount()); }
function persist() {
  try { savePreferences(app.getPath('userData'), preferences); }
  catch { update({ downloads: '设置暂未保存，下次启动可能需要重新选择地区。' }); }
}
function update(changes = {}) {
  Object.assign(state, changes);
  if (preferences) {
    state.accounts = preferences.accounts.map(account => ({ ...account }));
    state.activeAccountId = preferences.activeAccountId;
    if (inbox) state.inbox = inbox.snapshot(preferences.accounts);
  }
  if (window && !window.isDestroyed()) window.webContents.send('desk:state-changed', { ...state });
}
function layout() {
  if (!window || !mailView || window.isDestroyed()) return;
  const [width, height] = window.getContentSize();
  mailView.setBounds({ x: 0, y: TOP, width, height: Math.max(1, height - TOP - BOTTOM) });
}
function navigationState(contents) {
  if (contents.isDestroyed()) return;
  const url = contents.getURL();
  const canGoHome = isMailURL(url);
  const authPage = !canGoHome && isLoginURL(url);
  // Keep the actual regional mail origin if Zoho redirects the chosen data centre.
  if (canGoHome) {
    mailboxHome = new URL('/zm/', url).href;
    if (activeAccount()) inbox?.setOrigin(activeAccount().id, new URL(url).origin);
  }
  const menuChanged = state.canGoHome !== canGoHome || state.authPage !== authPage;
  update({ host: displayHost(url), canGoHome, authPage,
    back: contents.navigationHistory.canGoBack(), forward: contents.navigationHistory.canGoForward() });
  if (menuChanged) createMenu();
}
async function returnToMailbox() {
  if (state.mode === 'inboxes') return false;
  const contents = mailView?.webContents;
  if (!contents || contents.isDestroyed() || opening || clearing || state.accountDialog ||
      !isMailURL(contents.getURL()) || !isMailURL(mailboxHome)) return false;
  // Navigate the existing renderer and session; this is not account switching.
  await contents.loadURL(mailboxHome).catch(() => {});
  return true;
}
async function refreshPage() {
  if (opening || clearing || state.accountDialog) return false;
  if (state.mode === 'inboxes') return inbox.refresh(preferences.accounts);
  if (state.phase === 'error' || !mailView?.webContents) return currentAccount();
  const contents = mailView.webContents;
  if (contents.isDestroyed() || isLoginURL(contents.getURL())) return false;
  contents.reload(); return true;
}
async function openOutside(value) {
  const url = externalURL(value);
  if (!url) return;
  try { await shell.openExternal(url); } catch { update({ downloads: '未能打开外部链接。' }); }
}
function remotePreferences(partition) { return { ...SAFE_WEB, partition }; }
function secureRemote(contents, partition, popup = false) {
  contents.on('will-attach-webview', event => event.preventDefault());
  const guard = (event, value) => {
    if (canNavigateInside(value, { popup })) return;
    event.preventDefault(); void openOutside(value);
  };
  contents.on('will-navigate', guard); contents.on('will-redirect', guard);
  contents.setWindowOpenHandler(({ url }) => {
    if (!canNavigateInside(url, { popup: true })) { void openOutside(url); return { action: 'deny' }; }
    return { action: 'allow', overrideBrowserWindowOptions: {
      width: 1040, height: 760, minWidth: 640, minHeight: 480, autoHideMenuBar: true,
      title: `${displayHost(url) || '邮件窗口'} — Mail Lite`, webPreferences: remotePreferences(partition)
    } };
  });
  contents.on('did-create-window', child => {
    childWindows.add(child); secureRemote(child.webContents, partition, true);
    const setTitle = () => child.setTitle(`${displayHost(child.webContents.getURL()) || '邮件窗口'} — Mail Lite`);
    child.webContents.on('page-title-updated', event => { event.preventDefault(); setTitle(); });
    child.webContents.on('did-navigate', setTitle);
    child.on('closed', () => childWindows.delete(child));
  });
}
function downloadStatus() {
  update({ downloads: activeDownloads ? `正在下载 ${activeDownloads} 个附件…` : completedDownloads ? `已下载 ${completedDownloads} 个附件` : '' });
}
function configureSession(mailSession) {
  if (configuredSessions.has(mailSession)) return;
  configuredSessions.add(mailSession);
  // Use the ordinary website, without impersonating the official client's bridge.
  mailSession.setUserAgent(mailSession.getUserAgent().replace(/\s(?:Electron|Mail-Lite|mail-lite)\/[^\s]+/gi, ''));
  mailSession.setPermissionCheckHandler((_contents, permission, origin) => permission === 'clipboard-sanitized-write' && isAppURL(origin));
  mailSession.setPermissionRequestHandler((contents, permission, callback, details) => {
    callback(permission === 'clipboard-sanitized-write' && isAppURL(details.requestingUrl || contents.getURL()));
  });
  mailSession.on('will-download', (_event, item) => {
    item.setSaveDialogOptions({ title: '保存邮件附件', defaultPath: path.join(app.getPath('downloads'), path.basename(item.getFilename())) });
    activeDownloads += 1; downloadStatus();
    item.once('done', (_event, result) => {
      activeDownloads = Math.max(0, activeDownloads - 1);
      if (result === 'completed') {
        completedDownloads += 1;
        if (process.platform === 'darwin') {
          const quarantine = `0001;${Math.floor(Date.now() / 1000).toString(16)};Mail Lite;${randomUUID()}`;
          execFile('/usr/bin/xattr', ['-w', 'com.apple.quarantine', quarantine, item.getSavePath()], error => {
            if (error) update({ downloads: '附件已保存，但未能写入下载来源标记。' });
          });
        }
      }
      downloadStatus();
      if (result === 'interrupted') update({ downloads: '附件下载中断，请在邮件中重试。' });
    });
  });
}
function destroyMailView() {
  for (const child of childWindows) if (!child.isDestroyed()) child.destroy();
  childWindows.clear();
  if (!mailView) return;
  const old = mailView; mailView = null;
  if (window && !window.isDestroyed()) window.contentView.removeChildView(old);
  const contents = old.webContents;
  if (contents && !contents.isDestroyed()) contents.close({ waitForBeforeUnload: false });
}
function releaseMailView() {
  if (!mailView?.webContents || mailView.webContents.isDestroyed()) { destroyMailView(); return Promise.resolve(true); }
  const view = mailView;
  const contents = view.webContents;
  const savedSession = contents.session;
  return new Promise(resolve => {
    const finished = async () => {
      contents.removeListener('will-prevent-unload', prevented);
      if (mailView === view) destroyMailView();
      savedSession.flushStorageData();
      await savedSession.cookies.flushStore().catch(() => {});
      resolve(true);
    };
    const prevented = event => {
      const choice = dialog.showMessageBoxSync(window, { type: 'question',
        message: '邮件页面有尚未完成的编辑，仍要离开？',
        buttons: ['留在页面', '离开'], defaultId: 0, cancelId: 0 });
      if (choice === 1) event.preventDefault();
      else {
        contents.removeListener('destroyed', finished);
        contents.removeListener('will-prevent-unload', prevented);
        resolve(false);
      }
    };
    contents.once('will-prevent-unload', prevented);
    contents.once('destroyed', finished);
    contents.close({ waitForBeforeUnload: true });
  });
}
async function loadAccount(account, { add = false, message = null } = {}) {
  const region = regionById(account.region);
  if (!region) throw new Error('Unknown mail region');
  if (opening || clearing) { update(); return false; }
  opening = true;
  update({ busy: true });
  try {
  if (!await releaseMailView()) { update(); return false; }
  const partition = accountPartition(account);
  destroyMailView(); configureSession(session.fromPartition(partition));
  const view = new WebContentsView({ webPreferences: remotePreferences(partition) });
  mailView = view; view.setBackgroundColor('#ffffff'); view.setVisible(false);
  window.contentView.addChildView(view); layout();
  if (add) preferences.accounts.push(account);
  preferences.activeAccountId = account.id;
  preferences.region = region.id; preferences.opened = true; persist(); createMenu();
  mailboxHome = `https://mail.${region.domain}/zm/`;
  update({ phase: 'loading', mode: 'account', region: region.id, accountDialog: null, canGoHome: false, authPage: false,
    loading: true, error: '', host: `mail.${region.domain}`, back: false, forward: false });
  const contents = view.webContents;
  secureRemote(contents, partition);
  const current = () => mailView === view && !contents.isDestroyed();
  contents.on('did-start-loading', () => { if (current()) update({ loading: true }); });
  contents.on('dom-ready', () => {
    if (!current() || state.phase === 'error' || !canNavigateInside(contents.getURL())) return;
    if (!state.accountDialog && state.mode === 'account') view.setVisible(true);
    update({ phase: 'mail', error: '' }); navigationState(contents);
  });
  contents.on('did-stop-loading', () => { if (current()) { update({ loading: false }); navigationState(contents); } });
  contents.on('did-navigate', () => { if (current()) navigationState(contents); });
  contents.on('did-navigate-in-page', () => { if (current()) navigationState(contents); });
  contents.on('did-fail-load', (_event, code, _description, _url, mainFrame) => {
    if (!current() || !mainFrame || code === -3) return;
    view.setVisible(false);
    update({ phase: 'error', canGoHome: false, loading: false, error: `连接未完成（${code}）。请检查网络或切换邮箱所在地区后重试。` });
  });
  contents.on('render-process-gone', () => {
    if (!current()) return;
    view.setVisible(false); update({ phase: 'error', canGoHome: false, loading: false, error: '邮件页面意外关闭，点击重新连接即可恢复。' });
  });
  void contents.loadURL(message ? messageURL(message) : `https://mail.${region.domain}/zm/`).catch(() => { /* did-fail-load reports sanitized errors. */ });
  return true;
  } finally { opening = false; update({ busy: false }); }
}
function showAccountForm(mode = 'add') {
  if (!['add', 'rename'].includes(mode) || opening || clearing || (mode === 'rename' && !activeAccount())) return;
  mailView?.setVisible(false);
  update({ accountDialog: { mode, region: activeAccount()?.region ?? state.region,
    name: mode === 'rename' ? activeAccount().name : '' } });
}
function closeAccountForm() {
  update({ accountDialog: null });
  if (mailView && state.phase === 'mail' && state.mode === 'account') mailView.setVisible(true);
}
async function switchAccount(id) {
  const account = preferences.accounts.find(item => item.id === id);
  if (!account) throw new Error('Unknown mail account');
  if (account.id === preferences.activeAccountId && mailView && state.phase !== 'error') {
    update({ mode: 'account' });
    if (state.phase === 'mail') mailView.setVisible(!state.accountDialog);
    navigationState(mailView.webContents); createMenu(); return true;
  }
  return loadAccount(account);
}
async function showUnifiedInbox() {
  if (opening || clearing || state.accountDialog || !preferences.accounts.length) return false;
  // Hide without closing the website: an unfinished draft stays in its session.
  mailView?.setVisible(false); update({ mode: 'inboxes' }); createMenu();
  await inbox.refresh(preferences.accounts); return true;
}
async function openInboxMessage(key) {
  if (opening || clearing || state.accountDialog) return false;
  const message = inbox.find(key);
  const account = message && preferences.accounts.find(a => a.id === message.accountId);
  if (!account) return false;
  if (activeAccount()?.id !== account.id || !mailView || state.phase === 'error') return loadAccount(account, { message });
  await switchAccount(account.id);
  await mailView.webContents.loadURL(messageURL(message)).catch(() => {});
  return true;
}
function trustedShell(event) {
  return Boolean(window && !window.isDestroyed() && event.sender === window.webContents &&
    event.senderFrame === window.webContents.mainFrame && event.senderFrame.url === SHELL_URL);
}
function registerIPC() {
  const handle = (channel, callback) => ipcMain.handle(channel, (event, ...args) => {
    if (!trustedShell(event)) throw new Error('Invalid UI sender'); return callback(...args);
  });
  handle('desk:state', () => ({ ...state }));
  handle('desk:open', id => activeAccount() ? currentAccount() : loadAccount(newAccount(preferences, { region: id }), { add: true }));
  handle('desk:switch-account', switchAccount);
  handle('desk:inboxes', showUnifiedInbox);
  handle('desk:inboxes-more', () => state.mode === 'inboxes' && !state.accountDialog && inbox.refresh(preferences.accounts, { more: true }));
  handle('desk:inboxes-open', openInboxMessage);
  handle('desk:account-form', showAccountForm);
  handle('desk:account-form-close', closeAccountForm);
  handle('desk:account-submit', async payload => {
    if (!state.accountDialog || !payload || typeof payload !== 'object' || opening || clearing) return false;
    if (state.accountDialog.mode === 'rename') {
      const account = activeAccount();
      if (!account) return false;
      account.name = accountName(payload.name, account.name);
      persist(); createMenu(); closeAccountForm(); return true;
    }
    const result = await loadAccount(newAccount(preferences, { name: payload.name, region: payload.region }), { add: true });
    if (!result) closeAccountForm();
    return result;
  });
  handle('desk:reload', refreshPage);
  handle('desk:navigate', direction => {
    if (!['back', 'forward'].includes(direction) || !mailView) return;
    const history = mailView.webContents.navigationHistory;
    if (direction === 'back' && history.canGoBack()) history.goBack();
    if (direction === 'forward' && history.canGoForward()) history.goForward();
  });
  handle('desk:home', returnToMailbox);
}
async function clearLogin() {
  if (clearing || opening) return;
  if (activeDownloads) { await dialog.showMessageBox(window, { type: 'info', message: '请等待附件下载完成后再清除登录状态。' }); return; }
  const { response } = await dialog.showMessageBox(window, {
    type: 'question', message: '清除 Mail Lite 的本机登录状态？',
    detail: '清除本应用所有账号的 Cookie、网页缓存和登录信息。保留账号名称，服务器邮件与已下载附件不受影响。',
    buttons: ['取消', '清除'], defaultId: 0, cancelId: 0
  });
  if (response !== 1) return;
  if (!await releaseMailView()) return;
  inbox.cancel({ clear: true });
  clearing = true;
  update({ phase: 'loading', mode: 'account', accountDialog: null, canGoHome: false, authPage: false, busy: true, loading: true, host: '', back: false, forward: false });
  try {
    const partitions = new Set([...preferences.accounts.map(accountPartition), ...REGIONS.map(region => `persist:mail-lite-${region.id}`)]);
    for (const partition of partitions) {
      const localSession = session.fromPartition(partition);
      await localSession.closeAllConnections(); await localSession.clearStorageData();
      await localSession.clearCache(); await localSession.clearAuthCache();
    }
    preferences.opened = false; persist();
    update({ phase: 'welcome', loading: false, error: '', downloads: '' });
  } catch { update({ phase: 'error', loading: false, error: '未能完整清除本机登录状态，请退出后重试。' }); }
  finally { clearing = false; update({ busy: false }); }
}
function createMenu() {
  const template = [];
  if (process.platform === 'darwin') template.push({ label: app.name, submenu: [
    { role: 'about', label: '关于 Mail Lite' }, { type: 'separator' }, { role: 'hide', label: '隐藏 Mail Lite' },
    { role: 'hideOthers', label: '隐藏其他' }, { role: 'unhide', label: '全部显示' }, { type: 'separator' }, { role: 'quit', label: '退出 Mail Lite' }
  ] });
  template.push({ label: '邮件', submenu: [
    { label: '所有收件箱', accelerator: 'CmdOrCtrl+Shift+I', enabled: Boolean(preferences?.accounts.length), click: () => void showUnifiedInbox() },
    { label: '返回邮箱首页', accelerator: 'CmdOrCtrl+1', enabled: state.mode === 'account' && state.canGoHome && !state.authPage,
      click: () => void returnToMailbox() },
    { label: '刷新当前页面', accelerator: 'CmdOrCtrl+R', enabled: state.mode === 'inboxes' || (state.phase !== 'welcome' && (!state.authPage || state.phase === 'error')),
      click: () => void refreshPage() }, { type: 'separator' }, { label: '清除本机登录状态…', click: () => void clearLogin() },
    ...(process.platform === 'darwin' ? [] : [{ type: 'separator' }, { role: 'quit', label: '退出' }])
  ] });
  template.push({ label: '账号', submenu: [
    { label: '所有收件箱', type: 'radio', checked: state.mode === 'inboxes', enabled: Boolean(preferences?.accounts.length), click: () => void showUnifiedInbox() },
    ...(preferences?.accounts ?? []).map(account => ({ label: account.name, type: 'radio',
      checked: state.mode === 'account' && account.id === preferences.activeAccountId, click: () => void switchAccount(account.id) })),
    ...((preferences?.accounts.length ?? 0) ? [{ type: 'separator' }] : []),
    { label: '添加账号…', accelerator: 'CmdOrCtrl+Shift+N', click: () => showAccountForm('add') },
    { label: '重命名当前账号…', enabled: state.mode === 'account' && Boolean(activeAccount()), click: () => showAccountForm('rename') }
  ] });
  template.push({ label: '编辑', submenu: [
    { role: 'undo', label: '撤销' }, { role: 'redo', label: '重做' }, { type: 'separator' },
    { role: 'cut', label: '剪切' }, { role: 'copy', label: '复制' }, { role: 'paste', label: '粘贴' }, { role: 'selectAll', label: '全选' }
  ] });
  template.push({ label: '窗口', submenu: [{ role: 'minimize', label: '最小化' }, { role: 'togglefullscreen', label: '全屏' }] });
  Menu.setApplicationMenu(Menu.buildFromTemplate(template));
}
async function createWindow() {
  preferences = readPreferences(app.getPath('userData'));
  inbox?.cancel({ clear: true });
  inbox = new UnifiedInbox({ sessionFor: account => {
    const s = session.fromPartition(accountPartition(account)); configureSession(s); return s;
  }, get: (s, url, options) => sessionGet(net, s, url, options), onChange: () => update() });
  state.region = activeAccount()?.region ?? preferences.region;
  update({ phase: 'welcome', mode: 'account', accountDialog: null, canGoHome: false, authPage: false, host: '', back: false, forward: false, error: '', loading: false });
  persist(); createMenu();
  window = new BrowserWindow({ width: preferences.width, height: preferences.height,
    minWidth: 900, minHeight: 640, show: false, title: 'Mail Lite', backgroundColor: '#f8f9fb',
    titleBarStyle: process.platform === 'darwin' ? 'hiddenInset' : 'default', trafficLightPosition: { x: 14, y: 15 },
    webPreferences: { ...SAFE_WEB, preload: path.join(__dirname, 'preload.cjs') }
  });
  window.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  window.webContents.on('will-navigate', event => event.preventDefault());
  window.webContents.on('will-attach-webview', event => event.preventDefault());
  window.webContents.on('page-title-updated', event => event.preventDefault());
  window.on('resize', layout);
  window.on('close', event => {
    if (!window.isMaximized() && !window.isFullScreen()) {
      const [width, height] = window.getSize(); Object.assign(preferences, { width, height }); persist();
    }
    if (!quitting && mailView) {
      event.preventDefault();
      if (closePending) return;
      closePending = true;
      void releaseMailView().then(allowed => { closePending = false; if (allowed && window) window.close(); });
    }
  });
  window.on('closed', () => { inbox.cancel({ clear: true }); window = null; });
  await window.loadFile(SHELL_PATH); window.show();
  if (preferences.opened && activeAccount()) {
    if (preferences.accounts.length > 1) await showUnifiedInbox();
    else await currentAccount();
  }
}
const inboxRefreshTimer = setInterval(() => {
  if (window && !window.isDestroyed() && window.isVisible() && !window.isMinimized() &&
      state.mode === 'inboxes' && !state.accountDialog && !opening && !clearing && !inbox.busy) void inbox.refresh(preferences.accounts);
}, 60000);
inboxRefreshTimer.unref();
app.setAboutPanelOptions({ applicationName: 'Mail Lite', applicationVersion: VERSION, copyright: '个人邮件客户端 · 非 Zoho 官方应用' });
if (!app.requestSingleInstanceLock()) app.quit();
else {
  app.on('second-instance', () => { if (window) { if (window.isMinimized()) window.restore(); window.show(); window.focus(); } });
  app.whenReady().then(async () => { registerIPC(); createMenu(); await createWindow(); });
  app.on('activate', () => { if (!quitting && !window) void createWindow(); });
  app.on('before-quit', event => {
    if (quitting) return;
    event.preventDefault();
    if (quitPending) return;
    quitPending = true;
    void releaseMailView().then(allowed => {
      quitPending = false;
      if (allowed) { inbox?.cancel({ clear: true }); quitting = true; app.quit(); }
    });
  });
  app.on('window-all-closed', () => { if (process.platform !== 'darwin') app.quit(); });
}
