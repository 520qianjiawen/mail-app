'use strict';
const { _electron: electron } = require('playwright-core');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'mail-lite-desktop-'));
// A real 0.1.0-shaped profile verifies that the existing partition survives migration.
fs.mkdirSync(path.join(profile, 'Partitions/mail-lite-global'), { recursive: true });
fs.writeFileSync(path.join(profile, 'preferences.json'), JSON.stringify({ region: 'global', opened: false }));
const results = path.join(root, 'test-results');
fs.mkdirSync(results, { recursive: true });
let application;
async function fixtures(application) {
  await application.evaluate(({ session, app }) => {
    const install = localSession => localSession.protocol.handle('https', request => {
      if (new URL(request.url).hostname === 'mail.zoho.eu') throw new Error('Simulated offline');
      if (request.url.includes('/attachment')) return new Response('Mail Lite attachment fixture\n', {
        headers: { 'Content-Type': 'application/octet-stream', 'Content-Disposition': 'attachment; filename="fixture.txt"' }
      });
      return new Response('<!doctype html><html><head><title>Fixture mail</title></head><body><h1>Mail fixture</h1><a href="/zm/second">Next message</a></body></html>', {
        headers: { 'Content-Type': 'text/html; charset=utf-8' }
      });
    });
    app.on('session-created', install);
    session.fromPartition('persist:mail-lite-global');
  });
}
async function ready(page, accountId) {
  await until(async () => {
    const state = await page.evaluate(() => window.mailDesk.getState());
    return state.phase === 'mail' && (!accountId || state.activeAccountId === accountId);
  });
}
async function addAccount(page, name, region) {
  await page.getByRole('button', { name: '添加账号', exact: true }).click();
  await page.locator('#account-dialog').waitFor({ state: 'visible' });
  await page.getByRole('textbox', { name: '账号名称或邮箱' }).fill(name);
  await page.locator('#account-region').selectOption(region);
  if (region === 'global') await page.screenshot({ path: path.join(results, 'add-account.png') });
  await page.getByRole('button', { name: '添加并登录' }).click();
}
async function until(check) {
  for (let attempt = 0; attempt < 200; attempt++) {
    if (await check()) return;
    await new Promise(resolve => setTimeout(resolve, 50));
  }
  throw new Error('Timed out waiting for desktop state');
}
(async () => {
  application = await electron.launch({ args: [root], executablePath: require('electron'),
    env: { ...process.env, MAIL_LITE_USER_DATA: profile }, timeout: 20000 });
  application.process().stderr.on('data', data => {
    const text = data.toString();
    if (/TypeError|ReferenceError|UnhandledPromise|Uncaught/.test(text)) console.error(text);
  });
  let page = await application.firstWindow();
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.getByRole('heading', { name: '专心，处理邮件。' }).waitFor();
  await page.waitForFunction(() => document.querySelector('#region').options.length === 10);
  assert.equal(await page.locator('#welcome').isVisible(), true);
  await page.screenshot({ path: path.join(results, 'welcome.png') });

  // Inert HTTPS responses are attached to every new test session, never to user sessions.
  await fixtures(application);
  await page.getByRole('button', { name: '打开 Zoho 邮箱' }).click();
  await until(async () => (await page.evaluate(() => window.mailDesk.getState())).phase === 'mail');
  let actual = await application.evaluate(({ webContents }) => {
    const all = webContents.getAllWebContents();
    const mail = all.find(contents => contents.getURL().startsWith('https://mail.zoho.com/'));
    if (!mail) throw new Error(JSON.stringify(all.map(contents => ({ id: contents.id, url: contents.getURL(), type: contents.getType() }))));
    const prefs = mail.getLastWebPreferences();
    return { url: mail.getURL(), nodeIntegration: prefs.nodeIntegration, sandbox: prefs.sandbox,
      contextIsolation: prefs.contextIsolation, preload: prefs.preload || null };
  });
  assert.equal(actual.url, 'https://mail.zoho.com/zm/');
  assert.equal(actual.nodeIntegration, false); assert.equal(actual.sandbox, true);
  assert.equal(actual.contextIsolation, true); assert.equal(actual.preload, null);
  assert.equal(await page.locator('#host').textContent(), 'mail.zoho.com');

  const downloaded = path.join(profile, 'fixture.txt');
  await application.evaluate(({ session, webContents }, destination) => {
    session.fromPartition('persist:mail-lite-global').once('will-download', (_event, item) => item.setSavePath(destination));
    webContents.getAllWebContents().find(contents => contents.getURL().startsWith('https://mail.zoho.com/'))
      .downloadURL('https://mail.zoho.com/attachment');
  }, downloaded);
  await until(() => fs.existsSync(downloaded) && fs.readFileSync(downloaded, 'utf8') === 'Mail Lite attachment fixture\n');
  await until(async () => (await page.evaluate(() => window.mailDesk.getState())).downloads.includes('已下载'));
  if (process.platform === 'darwin') {
    const { execFileSync } = require('node:child_process');
    await until(() => { try { return execFileSync('/usr/bin/xattr', ['-p', 'com.apple.quarantine', downloaded], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).includes('Mail Lite'); } catch { return false; } });
  }

  await application.evaluate(async ({ webContents }) => {
    const mail = webContents.getAllWebContents().find(contents => contents.getURL().startsWith('https://mail.zoho.com/'));
    await mail.loadURL('https://mail.zoho.com/zm/second');
  });
  await until(async () => (await page.evaluate(() => window.mailDesk.getState())).back);
  await page.getByRole('button', { name: '返回', exact: true }).click();
  await until(async () => (await page.evaluate(() => window.mailDesk.getState())).forward);

  const originalViewId = await application.evaluate(async ({ webContents, session }) => {
    const mail = webContents.getAllWebContents().find(contents => contents.getURL().startsWith('https://mail.zoho.com/'));
    await session.fromPartition('persist:mail-lite-global').cookies.set({ url: 'https://mail.zoho.com', name: 'navigation-fixture', value: 'retained' });
    globalThis.__navigationFinishes = 0;
    mail.on('did-finish-load', () => { globalThis.__navigationFinishes++; });
    await mail.loadURL('https://mail.zoho.jp/zm/message');
    return mail.id;
  });
  await until(async () => (await page.evaluate(() => window.mailDesk.getState())).canGoHome && !(await page.evaluate(() => window.mailDesk.getState())).loading);
  await page.getByRole('button', { name: '返回邮箱首页' }).click();
  await until(() => application.evaluate(({ webContents }, id) => webContents.fromId(id)?.getURL() === 'https://mail.zoho.jp/zm/', originalViewId));
  assert.equal(await application.evaluate(({ webContents }, id) => webContents.fromId(id).isDestroyed(), originalViewId), false);
  const beforeReload = await application.evaluate(() => globalThis.__navigationFinishes);
  await page.getByRole('button', { name: '刷新当前页面' }).click();
  await until(async () => await application.evaluate(() => globalThis.__navigationFinishes) > beforeReload);
  const navigationCookie = await application.evaluate(async ({ session }) => (await session.fromPartition('persist:mail-lite-global').cookies.get({ name: 'navigation-fixture' })).map(cookie => cookie.value));
  assert.deepEqual(navigationCookie, ['retained']);
  await application.evaluate(async ({ webContents }, id) => { await webContents.fromId(id).loadURL('https://accounts.zoho.jp/signin'); }, originalViewId);
  await until(async () => (await page.evaluate(() => window.mailDesk.getState())).authPage);
  assert.equal(await page.locator('#reload').isDisabled(), true);
  assert.equal(await page.locator('#home').isDisabled(), true);
  assert.equal(await page.locator('#status').textContent(), '正在登录或验证账号');
  assert.deepEqual(await page.evaluate(async () => [await window.mailDesk.home(), await window.mailDesk.reload()]), [false, false]);
  const guarded = await application.evaluate(({ Menu, webContents }, id) => ({
    url: webContents.fromId(id).getURL(),
    enabled: Menu.getApplicationMenu().items.find(item => item.label === '邮件').submenu.items
      .filter(item => ['返回邮箱首页', '刷新当前页面'].includes(item.label)).map(item => item.enabled)
  }), originalViewId);
  assert.deepEqual(guarded, { url: 'https://accounts.zoho.jp/signin', enabled: [false, false] });
  await application.evaluate(async ({ webContents }, id) => { await webContents.fromId(id).loadURL('https://mail.zoho.com/zm/'); }, originalViewId);
  await ready(page, 'legacy-global');

  await application.evaluate(async ({ session, webContents }) => {
    await session.fromPartition('persist:mail-lite-global').cookies.set({ url: 'https://mail.zoho.com', name: 'fixture-account', value: 'first', expirationDate: Date.now() / 1000 + 3600 });
    await webContents.getAllWebContents().find(contents => contents.getURL().startsWith('https://mail.zoho.com/')).executeJavaScript('localStorage.setItem("fixture-account", "first")');
  });
  await addAccount(page, '个人邮箱', 'global');
  await ready(page);
  const second = (await page.evaluate(() => window.mailDesk.getState())).accounts.find(account => account.name === '个人邮箱');
  assert(second && second.id !== 'legacy-global');
  const isolated = await application.evaluate(async ({ session }, id) => {
    const isolated = session.fromPartition(`persist:mail-lite-account-${id}`);
    const before = await isolated.cookies.get({ name: 'fixture-account' });
    await isolated.cookies.set({ url: 'https://mail.zoho.com', name: 'fixture-account', value: 'second', expirationDate: Date.now() / 1000 + 3600 });
    return before;
  }, second.id);
  assert.deepEqual(isolated, []);
  await page.locator('#accounts').selectOption('legacy-global'); await ready(page, 'legacy-global');
  const firstData = await application.evaluate(async ({ session, webContents }) => ({
    cookies: (await session.fromPartition('persist:mail-lite-global').cookies.get({ name: 'fixture-account' })).map(cookie => cookie.value),
    local: await webContents.getAllWebContents().find(contents => contents.getURL().startsWith('https://mail.zoho.com/')).executeJavaScript('localStorage.getItem("fixture-account")')
  }));
  assert.deepEqual(firstData, { cookies: ['first'], local: 'first' });
  await page.locator('#accounts').selectOption(second.id); await ready(page, second.id);
  const secondData = await application.evaluate(async ({ session, webContents }, id) => ({
    cookies: (await session.fromPartition(`persist:mail-lite-account-${id}`).cookies.get({ name: 'fixture-account' })).map(cookie => cookie.value),
    local: await webContents.getAllWebContents().find(contents => contents.getURL().startsWith('https://mail.zoho.com/')).executeJavaScript('localStorage.getItem("fixture-account")')
  }), second.id);
  assert.deepEqual(secondData, { cookies: ['second'], local: null });
  await page.evaluate(() => window.mailDesk.showAccountForm('rename'));
  await page.getByRole('textbox', { name: '账号名称或邮箱' }).fill('私人邮箱');
  await page.getByRole('button', { name: '保存名称' }).click();
  await until(async () => (await page.evaluate(() => window.mailDesk.getState())).accounts.some(account => account.id === second.id && account.name === '私人邮箱'));

  await addAccount(page, '中国邮箱', 'china');
  await until(async () => {
    const value = await page.evaluate(() => window.mailDesk.getState());
    return value.host === 'mail.zoho.com.cn' && value.phase === 'mail';
  });
  actual = await application.evaluate(({ webContents }) => webContents.getAllWebContents()
    .filter(contents => contents.getURL().startsWith('https://mail.zoho.')).map(contents => contents.getURL()));
  assert.deepEqual(actual, ['https://mail.zoho.com.cn/zm/']);
  await application.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].setSize(900, 640));
  await page.screenshot({ path: path.join(results, 'mail-minimum.png') });

  await addAccount(page, '断网测试', 'europe');
  await page.getByRole('heading', { name: '暂时连不上邮箱' }).waitFor({ timeout: 10000 });
  await page.screenshot({ path: path.join(results, 'offline.png') });
  await page.locator('#accounts').selectOption('legacy-global');
  await until(async () => (await page.evaluate(() => window.mailDesk.getState())).phase === 'mail');
  assert.deepEqual(errors, []);
  await application.close(); application = null;

  // Verify the saved selection after orderly shutdown of this isolated test profile.
  const prefs = JSON.parse(fs.readFileSync(path.join(profile, 'preferences.json'), 'utf8'));
  assert.equal(prefs.region, 'global'); assert.equal(prefs.opened, true);
  assert.equal(prefs.accounts.length, 4); assert.equal(prefs.activeAccountId, 'legacy-global');
  // Keep automatic network startup off until fixture handlers are installed in the second process.
  fs.writeFileSync(path.join(profile, 'preferences.json'), JSON.stringify({ ...prefs, opened: false }));
  application = await electron.launch({ args: [root], executablePath: require('electron'), env: { ...process.env, MAIL_LITE_USER_DATA: profile } });
  page = await application.firstWindow();
  await fixtures(application);
  await until(async () => (await page.evaluate(() => window.mailDesk.getState())).accounts.length === 4);
  assert.equal((await page.evaluate(() => window.mailDesk.getState())).activeAccountId, 'legacy-global');
  const stored = await application.evaluate(async ({ session }, id) => ({
    first: (await session.fromPartition('persist:mail-lite-global').cookies.get({ name: 'fixture-account' })).map(cookie => cookie.value),
    second: (await session.fromPartition(`persist:mail-lite-account-${id}`).cookies.get({ name: 'fixture-account' })).map(cookie => cookie.value)
  }), second.id);
  assert.deepEqual(stored, { first: ['first'], second: ['second'] });
  await page.getByRole('button', { name: '打开 Zoho 邮箱' }).click(); await ready(page, 'legacy-global');
  await page.screenshot({ path: path.join(results, 'accounts-restored.png') });
  await application.close(); application = null;
  console.log('PASS: in-place home/reload, regional mail origin, authentication guards, cookie retention, legacy migration, same-region isolation, add/switch/rename, restart, attachment, offline recovery, shutdown.');
})().catch(error => { console.error(error); process.exitCode = 1; }).finally(async () => {
  if (application) {
    const child = application.process();
    await Promise.race([application.close().catch(() => {}), new Promise(resolve => setTimeout(resolve, 2000))]);
    if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
  }
  fs.rmSync(profile, { recursive: true, force: true });
});
