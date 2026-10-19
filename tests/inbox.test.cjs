'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const { UnifiedInbox, sessionGet, normalizeMessage, messageURL, InboxError } = require('../src/unified-inbox.cjs');
const a = { id: 'first', name: 'first@example.com', region: 'global' };
const b = { id: 'second', name: 'second@example.com', region: 'global' };
const mail = (id, time, folder = '100') => ({ messageId: id, folderId: folder, receivedTime: String(time), subject: 'Subject', status: '0' });
function fixture({ failSecond = false, paginated = false } = {}) {
  const calls = [];
  const service = new UnifiedInbox({ sessionFor: account => ({ id: account.id, cookies: { get: async () => [{ name: 'zmcsr', value: `csrf-${account.id}` }] } }),
    get: async (s, value, options) => {
      const url = new URL(value); calls.push({ session: s.id, path: url.pathname, start: url.searchParams.get('start') });
      assert.equal(options.headers['X-ZCSRF-TOKEN'], `zmrcsr=csrf-${s.id}`);
      if (failSecond && s.id === 'second') throw new InboxError('auth');
      if (url.pathname === '/api/accounts') return [{ accountId: '900719925474099301', isDefaultAccount: true }];
      if (url.pathname.endsWith('/folders')) return [
        { folderId: '99', folderType: 'Inbox', path: '/Newsletter' },
        { folderId: '100', folderType: 'Inbox', path: '/Inbox' }
      ];
      assert.equal(url.searchParams.get('folderId'), '100');
      const start = Number(url.searchParams.get('start'));
      if (paginated) return Array.from({ length: start === 1 ? 50 : 10 }, (_, i) =>
        mail(String((s.id === 'first' ? 100000 : 200000) + start + i), (s.id === 'first' ? 10000 : 8000) - start - i));
      return [mail('900719925474099303', s.id === 'first' ? 100 : 200), mail('5', 20, '99')];
    } });
  return { service, calls };
}
test('same-region accounts remain isolated, IDs stay strings, and only Inbox is included', async () => {
  const { service, calls } = fixture();
  await service.refresh([a, b]);
  const result = service.snapshot([a, b]);
  assert.equal(result.messages.length, 2);
  assert.deepEqual(result.messages.map(m => m.accountId), ['second', 'first']);
  assert.equal(result.messages[0].remoteId, '900719925474099301');
  assert.equal(result.messages[0].messageId, '900719925474099303');
  assert.notEqual(result.messages[0].key, result.messages[1].key);
  assert.equal(result.messages[0].unread, true);
  assert(calls.some(c => c.session === 'first') && calls.some(c => c.session === 'second'));
  assert.equal(messageURL(result.messages[0]), 'https://mail.zoho.com/zm/#mail/folder/inbox/p/900719925474099303');
  assert.equal(service.find('invented'), null);
  assert.equal(service.snapshot([{ ...a, name: 'Renamed' }, b]).messages[1].accountName, 'Renamed');
});
test('one expired account does not hide another account or produce a false empty-success state', async () => {
  const { service } = fixture({ failSecond: true });
  await service.refresh([a, b]);
  const result = service.snapshot([a, b]);
  assert.equal(result.messages.length, 1);
  assert.equal(result.accounts.find(r => r.id === 'second').status, 'auth');
  assert.match(result.accounts[1].error, /验证/);
});
test('global paging does not skip newer messages in an account with a busier inbox', async () => {
  const { service, calls } = fixture({ paginated: true });
  await service.refresh([a, b]);
  let result = service.snapshot([a, b]);
  assert.equal(result.messages.length, 50);
  assert(result.messages.every(m => m.accountId === 'first'));
  assert.equal(result.hasMore, true);
  await service.refresh([a, b], { more: true });
  result = service.snapshot([a, b]);
  assert.equal(result.messages.length, 100);
  assert.equal(result.messages.filter(m => m.accountId === 'first').length, 60);
  assert.equal(result.messages.filter(m => m.accountId === 'second').length, 40);
  assert.equal(result.hasMore, true); // 20 prefetched messages remain.
  assert.equal(calls.filter(c => c.start === '51').length, 2);
  await service.refresh([a, b], { more: true });
  assert.equal(service.snapshot([a, b]).messages.length, 120);
  assert.equal(service.snapshot([a, b]).hasMore, false);
});
test('cancellation prevents an old response from repopulating cleared mail', async () => {
  let release;
  const gate = new Promise(resolve => { release = resolve; });
  const { service } = fixture(); const original = service.get;
  service.get = async (...args) => { await gate; return original(...args); };
  const pending = service.refresh([a]);
  service.cancel({ clear: true }); release(); await pending;
  assert.equal(service.snapshot([a]).messages.length, 0);
  assert.equal(service.snapshot([a]).busy, false);
});
test('untrusted message fields cannot supply executable navigation or invalid dates', () => {
  const message = normalizeMessage({ ...mail('4', Infinity), subject: '<img src=x onerror=alert(1)>', summary: '<b>Hello</b>&amp; goodbye' }, a, '1', '100', 'https://mail.zoho.com');
  assert.equal(message.receivedTime, 0);
  assert.equal(message.subject, '<img src=x onerror=alert(1)>'); // UI inserts literal textContent.
  assert.equal(message.summary, 'Hello& goodbye');
  assert.equal(normalizeMessage(mail('https://evil.example', 2), a, '1', '100', 'https://mail.zoho.com'), null);
  assert.throws(() => messageURL({ origin: 'https://evil.example', messageId: '1' }));
  assert.throws(() => messageURL({ origin: 'https://mail.zoho.com', messageId: '1/../../' }));
});
test('network reads use the selected session, bound redirects, and do not expose auth URLs', async () => {
  let options, request;
  const net = { request: value => {
    options = value; request = new EventEmitter(); request.abort = () => {}; request.end = () => {};
    return request;
  } };
  const s = {};
  const result = sessionGet(net, s, 'https://mail.zoho.com/api/accounts');
  assert.equal(options.session, s); assert.equal(options.useSessionCookies, true); assert.equal(options.redirect, 'manual');
  request.emit('redirect', {}, 302, 'GET', 'https://accounts.zoho.com/sensitive');
  await assert.rejects(result, e => e.code === 'auth' && !e.message.includes('sensitive'));
  await assert.rejects(sessionGet(net, s, 'https://evil.example/api/accounts'));
});
