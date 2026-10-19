'use strict';
const { _electron: electron } = require('playwright-core');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'mail-lite-inbox-'));
const accounts = [{ id: 'first', name: '工作邮箱', region: 'global' }, { id: 'second', name: '个人邮箱', region: 'global' }];
fs.writeFileSync(path.join(profile, 'preferences.json'), JSON.stringify({ accounts, activeAccountId: 'first', opened: false }));
let application;
const wait = async check => {
  for (let i = 0; i < 200; i++) { if (await check()) return; await new Promise(resolve => setTimeout(resolve, 50)); }
  throw new Error('Inbox desktop state timed out');
};
(async () => {
  application = await electron.launch({ args: [root], executablePath: require('electron'), env: { ...process.env, MAIL_LITE_USER_DATA: profile } });
  const page = await application.firstWindow(); const errors = [];
  page.on('pageerror', e => errors.push(e.message));
  await page.waitForFunction(() => window.mailDesk);
  await application.evaluate(async ({ session }) => {
    globalThis.__inboxCalls = []; globalThis.__failInboxSecond = false; globalThis.__emptyInbox = false;
    for (const id of ['first', 'second']) {
      const s = session.fromPartition(`persist:mail-lite-account-${id}`);
      await s.cookies.set({ url: 'https://mail.zoho.com', name: 'zmcsr', value: `fixture-${id}` });
      s.protocol.handle('https', request => {
        const url = new URL(request.url);
        const respond = data => new Response(JSON.stringify(data), { headers: { 'Content-Type': 'application/json' } });
        if (url.pathname.startsWith('/api/')) {
          globalThis.__inboxCalls.push({ id, path: url.pathname, start: url.searchParams.get('start'), csrf: request.headers.get('X-ZCSRF-TOKEN') });
          if (id === 'second' && globalThis.__failInboxSecond) return respond({ status: { code: 400 }, data: { reauthUrl: 'https://accounts.zoho.com/secret-auth-details' } });
          if (url.pathname === '/api/accounts') return respond({ status: { code: 200 }, data: [{ accountId: id === 'first' ? '101' : '202', isDefaultAccount: true }] });
          if (url.pathname.endsWith('/folders')) return respond({ status: { code: 200 }, data: [{ folderId: '500', path: '/Inbox' }] });
          const start = Number(url.searchParams.get('start'));
          const messages = globalThis.__emptyInbox ? [] : Array.from({ length: start === 1 ? 50 : 5 }, (_, i) => ({
            messageId: String((id === 'first' ? 10000 : 20000) + start + i), folderId: '500',
            receivedTime: String(1792400000000 - (start + i) * 60000 - (id === 'first' ? 0 : 30000)),
            subject: i === 0 ? '<img src=x onerror=alert(1)>' : `Test message ${start + i}`, summary: '<b>Preview</b>', sender: `Sender ${id}`, status: i % 2 ? '1' : '0'
          }));
          return respond({ status: { code: 200 }, data: messages });
        }
        return new Response('<!doctype html><title>Fixture mailbox</title><h1>Mailbox</h1><textarea aria-label="Draft"></textarea>', { headers: { 'Content-Type': 'text/html' } });
      });
    }
  });
  await page.evaluate(() => window.mailDesk.showInboxes());
  let state = await page.evaluate(() => window.mailDesk.getState());
  assert.equal(state.mode, 'inboxes'); assert.equal(state.inbox.messages.length, 50);
  assert.deepEqual(state.inbox.accounts.map(a => a.status), ['ready', 'ready']);
  assert.equal(await page.locator('.inbox-row').count(), 50);
  assert.equal(await page.locator('#inboxes-list img').count(), 0);
  assert.equal(await page.locator('#accounts').inputValue(), '__all__');
  const first = state.inbox.messages[0], second = state.inbox.messages.find(m => m.accountId === 'second');
  assert(first && second);
  const calls = await application.evaluate(() => globalThis.__inboxCalls);
  assert(calls.every(c => c.csrf === `zmrcsr=fixture-${c.id}`));
  await page.getByRole('button', { name: '加载更多', exact: true }).click();
  await wait(async () => !(await page.evaluate(() => window.mailDesk.getState())).inbox.busy);
  state = await page.evaluate(() => window.mailDesk.getState());
  assert.equal(state.inbox.messages.length, 100);
  assert(state.inbox.hasMore);
  await page.evaluate(key => window.mailDesk.openInboxMessage(key), second.key);
  await wait(async () => (await page.evaluate(() => window.mailDesk.getState())).phase === 'mail');
  assert.equal((await page.evaluate(() => window.mailDesk.getState())).activeAccountId, 'second');
  const openURL = await application.evaluate(({ webContents }) => webContents.getAllWebContents().find(w => w.getURL().startsWith('https://mail.'))?.getURL());
  assert.equal(openURL, `https://mail.zoho.com/zm/#mail/folder/inbox/p/${second.messageId}`);
  await application.evaluate(async ({ webContents, dialog }) => {
    dialog.showMessageBoxSync = () => 0;
    const remote = webContents.getAllWebContents().find(w => w.getURL().startsWith('https://mail.'));
    await remote.executeJavaScript('window.onbeforeunload = () => false; document.querySelector("textarea").value = "Unsent draft"');
    globalThis.__draftContentsId = remote.id;
  });
  await page.getByRole('button', { name: '所有收件箱', exact: true }).click();
  await wait(async () => !(await page.evaluate(() => window.mailDesk.getState())).inbox.busy);
  await page.evaluate(key => window.mailDesk.openInboxMessage(key), first.key);
  assert.equal((await page.evaluate(() => window.mailDesk.getState())).mode, 'inboxes');
  assert.equal(await application.evaluate(async ({ webContents }) => webContents.fromId(globalThis.__draftContentsId).executeJavaScript('document.querySelector("textarea").value')), 'Unsent draft');
  await application.evaluate(async ({ webContents }) => webContents.fromId(globalThis.__draftContentsId).executeJavaScript('window.onbeforeunload = null'));
  await application.evaluate(() => { globalThis.__failInboxSecond = true; });
  await page.evaluate(() => window.mailDesk.reload());
  state = await page.evaluate(() => window.mailDesk.getState());
  assert.equal(state.inbox.accounts[1].status, 'auth');
  assert.equal(state.inbox.messages.length, 50);
  assert.equal(await page.getByRole('button', { name: '去验证', exact: true }).count(), 1);
  assert(!(await page.locator('body').textContent()).includes('secret-auth-details'));
  await application.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].setSize(900, 640));
  await page.screenshot({ path: path.join(root, 'test-results/inboxes-minimum.png') });
  await application.evaluate(() => { globalThis.__failInboxSecond = false; globalThis.__emptyInbox = true; });
  await page.evaluate(() => window.mailDesk.reload());
  assert.equal(await page.getByRole('heading', { name: '收件箱里还没有邮件' }).isVisible(), true);
  assert.deepEqual(errors, []);
  console.log('PASS: real Electron session requests, merged sorting/paging, source labels, literal text safety, message routing, draft cancellation, partial authentication failure, empty state, 900px layout.');
})().catch(error => { console.error(error); process.exitCode = 1; }).finally(async () => {
  if (application) await application.close();
  fs.rmSync(profile, { recursive: true, force: true });
});
