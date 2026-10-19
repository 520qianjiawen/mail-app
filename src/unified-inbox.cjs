'use strict';
const { regionById, isMailURL } = require('./policy.cjs');
const PAGE = 50;
const ID = /^\d{1,64}$/;
class InboxError extends Error {
  constructor(code) { super(code); this.code = code; }
}
function text(value, limit = 240, stripTags = false) {
  if (typeof value !== 'string') return '';
  return (stripTags ? value.replace(/<[^>]*>/g, '') : value).replace(/&(amp|lt|gt|quot|apos|nbsp);/g,
    (_, entity) => ({ amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ' })[entity])
    .replace(/[\u0000-\u001f\u007f]/g, ' ').trim().slice(0, limit);
}
function normalizeMessage(source, account, remoteId, folderId, origin) {
  if (!source || !ID.test(String(source.messageId ?? ''))) return null;
  if (source.folderId != null && String(source.folderId) !== folderId) return null;
  const received = Number(source.receivedTime ?? source.sentDateInGMT);
  return { key: `${account.id}:${remoteId}:${source.messageId}`, accountId: account.id,
    remoteId, folderId, messageId: String(source.messageId), origin,
    subject: text(source.subject) || '（无主题）', sender: text(source.sender || source.fromAddress, 120),
    from: text(source.fromAddress, 180), summary: text(source.summary, 220, true),
    receivedTime: Number.isFinite(received) && received >= 0 && received <= 8640000000000000 ? received : 0,
    unread: String(source.status) === '0', attachment: source.hasAttachment === true || Number(source.hasAttachment) > 0 };
}
function messageURL(message) {
  if (!isMailURL(message.origin) || !ID.test(message.messageId)) throw new InboxError('invalid-message');
  return `${new URL(message.origin).origin}/zm/#mail/folder/inbox/p/${message.messageId}`;
}
// Chromium sends the cookies directly from the selected partition. No cookie values
// or server responses are logged, persisted, or sent through desktop IPC.
function sessionGet(net, mailSession, url, { headers = {}, signal, json = true } = {}) {
  if (!isMailURL(url)) return Promise.reject(new InboxError('invalid-origin'));
  return new Promise((resolve, reject) => {
    if (signal?.aborted) { reject(new InboxError('cancelled')); return; }
    const request = net.request({ url, method: 'GET', session: mailSession, useSessionCookies: true,
      credentials: 'include', redirect: 'manual', headers: { Accept: 'application/json', ...headers } });
    let done = false;
    const finish = (error, value) => {
      if (done) return;
      done = true; clearTimeout(timer); signal?.removeEventListener('abort', cancel);
      if (error) { request.abort(); reject(error); } else resolve(value);
    };
    const cancel = () => finish(new InboxError('cancelled'));
    const timer = setTimeout(() => finish(new InboxError('network')), 18000);
    signal?.addEventListener('abort', cancel, { once: true });
    request.on('redirect', () => finish(new InboxError('auth')));
    request.on('error', () => finish(new InboxError('network')));
    request.on('login', (_info, callback) => { callback(); finish(new InboxError('auth')); });
    request.on('response', response => {
      const chunks = []; let bytes = 0;
      response.on('data', chunk => {
        bytes += chunk.length;
        if (bytes > 4 * 1024 * 1024) { finish(new InboxError('response')); return; }
        if (json) chunks.push(chunk);
      });
      response.on('error', () => finish(new InboxError('network')));
      response.on('aborted', () => finish(new InboxError('network')));
      response.on('end', () => {
        if (response.statusCode === 401 || response.statusCode === 403) { finish(new InboxError('auth')); return; }
        if (!json) { finish(null, null); return; }
        try {
          const body = JSON.parse(Buffer.concat(chunks).toString('utf8'));
          if (body.data?.reauthUrl || /TICKET|AUTH|TOKEN|LOGIN|CSRF/.test(String(body.data?.errorCode ?? ''))) {
            finish(new InboxError('auth')); return;
          }
          if (response.statusCode === 429 || body.status?.code === 429) { finish(new InboxError('rate')); return; }
          if (response.statusCode !== 200 || body.status?.code !== 200 || !Array.isArray(body.data)) {
            finish(new InboxError('response')); return;
          }
          finish(null, body.data);
        } catch { finish(new InboxError('response')); }
      });
    });
    request.end();
  });
}
const errorLabel = code => code === 'auth' ? '需要登录或重新验证身份' : code === 'rate' ? '请求较多，请稍后刷新' :
  code === 'folder' ? '未找到收件箱' : code === 'response' ? '暂时无法读取邮件列表' : '连接失败，请稍后刷新';
class UnifiedInbox {
  constructor({ sessionFor, get, onChange = () => {} }) {
    this.sessionFor = sessionFor; this.get = get; this.onChange = onChange;
    this.records = new Map(); this.origins = new Map(); this.busy = false; this.limit = PAGE;
    this.updatedAt = 0; this.generation = 0;
  }
  setOrigin(id, origin) { if (isMailURL(origin)) this.origins.set(id, new URL(origin).origin); }
  snapshot(accounts = []) {
    const names = new Map(accounts.map(a => [a.id, a.name]));
    const rows = [...this.records.values()].filter(r => names.has(r.account.id));
    const messages = rows.flatMap(r => r.messages).sort((a, b) => b.receivedTime - a.receivedTime || a.key.localeCompare(b.key));
    return { busy: this.busy, updatedAt: this.updatedAt, messages: messages.slice(0, this.limit).map(m => ({ ...m, accountName: names.get(m.accountId) })),
      hasMore: messages.length > this.limit || rows.some(r => r.hasMore && r.status === 'ready'),
      accounts: rows.map(r => ({ id: r.account.id, name: names.get(r.account.id), status: r.status, error: r.error || '', count: r.messages.length })) };
  }
  find(key) {
    if (typeof key !== 'string') return null;
    for (const r of this.records.values()) { const message = r.messages.find(m => m.key === key); if (message) return message; }
    return null;
  }
  cancel({ clear = false } = {}) {
    this.generation++; this.controller?.abort(); this.busy = false;
    if (clear) { this.records.clear(); this.origins.clear(); this.updatedAt = 0; }
  }
  async read(record, signal, first) {
    const { account } = record;
    const mailSession = this.sessionFor(account);
    const origin = this.origins.get(account.id) || `https://mail.${regionById(account.region).domain}`;
    try {
      let cookies = await mailSession.cookies.get({ url: origin });
      let csrf = cookies.find(c => c.name === 'zmcsr');
      if (!csrf) {
        await this.get(mailSession, `${origin}/zm/jsp/blank.jsp`, { signal, json: false });
        cookies = await mailSession.cookies.get({ url: origin }); csrf = cookies.find(c => c.name === 'zmcsr');
      }
      if (!csrf) throw new InboxError('auth');
      const options = { signal, headers: { 'X-ZCSRF-TOKEN': `zmrcsr=${csrf.value}` } };
      if (first) {
        const remoteAccounts = await this.get(mailSession, `${origin}/api/accounts`, options);
        const remote = remoteAccounts.find(a => a.primaryEmailAddress?.toLowerCase() === account.name.toLowerCase()) ||
          remoteAccounts.find(a => a.isDefaultAccount === true || a.isDefaultAccount === 'true') || remoteAccounts[0];
        if (!ID.test(String(remote?.accountId ?? ''))) throw new InboxError('response');
        record.remoteId = String(remote.accountId);
        const folders = await this.get(mailSession, `${origin}/api/accounts/${record.remoteId}/folders`, options);
        const inbox = folders.find(f => f.path === '/Inbox') || folders.find(f => f.folderType === 'Inbox' && f.folderName === 'Inbox');
        if (!ID.test(String(inbox?.folderId ?? ''))) throw new InboxError('folder');
        record.folderId = String(inbox.folderId);
      }
      const query = new URLSearchParams({ folderId: record.folderId, start: String(record.start), limit: String(PAGE), sortBy: 'date', sortorder: 'false', status: 'all' });
      const sources = await this.get(mailSession, `${origin}/api/accounts/${record.remoteId}/messages/view?${query}`, options);
      const unique = new Map(record.messages.map(m => [m.key, m]));
      for (const source of sources) {
        const m = normalizeMessage(source, account, record.remoteId, record.folderId, origin);
        if (m) unique.set(m.key, m);
      }
      record.messages = [...unique.values()]; record.start += sources.length;
      record.hasMore = sources.length === PAGE; record.status = 'ready'; record.error = '';
    } catch (e) {
      if (signal.aborted) return;
      record.status = e.code === 'auth' ? 'auth' : 'error'; record.error = errorLabel(e.code); record.hasMore = false;
    }
  }
  async refresh(accounts, { more = false } = {}) {
    if (this.busy || !accounts.length) return false;
    this.busy = true; const generation = ++this.generation;
    const controller = new AbortController(); this.controller = controller;
    if (!more) {
      this.limit = PAGE;
      this.records = new Map(accounts.map(account => [account.id, { account, messages: [], start: 1, hasMore: true, status: 'loading', error: '' }]));
    } else this.limit += PAGE;
    const queue = [...this.records.values()].filter(r => !more || (r.hasMore && r.status === 'ready'));
    this.onChange();
    const work = async () => {
      while (queue.length && !controller.signal.aborted) {
        const record = queue.shift();
        await this.read(record, controller.signal, !more);
        if (generation === this.generation) this.onChange();
      }
    };
    try { await Promise.all(Array.from({ length: Math.min(3, queue.length) }, work)); }
    finally {
      if (generation === this.generation) { this.busy = false; this.updatedAt = Date.now(); this.onChange(); }
    }
    return true;
  }
}
module.exports = { UnifiedInbox, sessionGet, normalizeMessage, messageURL, InboxError };
