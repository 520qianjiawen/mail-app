'use strict';
const $ = id => document.getElementById(id);
let current;
let inboxSignature = '', inboxErrorsSignature = '';
function element(tag, className, value) {
  const node = document.createElement(tag); node.className = className;
  if (value != null) node.textContent = value;
  return node;
}
function renderInboxes(state) {
  const data = state.inbox;
  if (!data) return;
  const ready = data.accounts.filter(a => a.status === 'ready').length;
  const errors = data.accounts.filter(a => a.error);
  $('inboxes-summary').textContent = data.busy ? '正在读取各账号的收件箱…' :
    `${ready} / ${state.accounts.length} 个账号已连接 · 已显示 ${data.messages.length} 封邮件`;
  $('inboxes-updated').textContent = data.updatedAt ? `上次刷新 ${new Date(data.updatedAt).toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit' })}` : '';
  const errorSignature = JSON.stringify(errors);
  if (errorSignature !== inboxErrorsSignature) {
    inboxErrorsSignature = errorSignature;
    $('inboxes-errors').replaceChildren(...errors.map(account => {
      const row = element('div', 'inbox-notice');
      row.append(element('span', '', `${account.name}：${account.error}`));
      const button = element('button', 'notice-action', account.status === 'auth' ? '去验证' : '打开账号');
      button.addEventListener('click', () => act(() => window.mailDesk.switchAccount(account.id)));
      row.append(button); return row;
    }));
  }
  const signature = JSON.stringify(data.messages);
  if (signature !== inboxSignature) {
    inboxSignature = signature;
    const now = new Date();
    $('inboxes-list').replaceChildren(...data.messages.map(message => {
      const row = element('button', `inbox-row${message.unread ? ' unread' : ''}`); row.type = 'button';
      row.setAttribute('aria-label', `${message.unread ? '未读，' : ''}${message.accountName}，${message.sender}，${message.subject}`);
      const sender = element('span', 'inbox-sender');
      sender.append(element('span', 'unread-dot'), element('span', 'sender-name', message.sender || message.from || '未知发件人'));
      const body = element('span', 'inbox-message');
      body.append(element('span', 'inbox-subject', `${message.attachment ? '⌁ ' : ''}${message.subject}`), element('span', 'inbox-preview', message.summary));
      const meta = element('span', 'inbox-meta');
      const date = new Date(message.receivedTime);
      const today = date.toDateString() === now.toDateString();
      const stamp = message.receivedTime ? date.toLocaleString('zh-CN', today ? { hour: '2-digit', minute: '2-digit' } :
        { year: date.getFullYear() === now.getFullYear() ? undefined : 'numeric', month: 'short', day: 'numeric' }) : '';
      const time = element('time', 'inbox-time', stamp); if (message.receivedTime) time.dateTime = date.toISOString();
      meta.append(time, element('span', 'account-badge', message.accountName));
      row.append(sender, body, meta);
      row.addEventListener('click', () => act(() => window.mailDesk.openInboxMessage(message.key)));
      return row;
    }));
  }
  $('inboxes-empty').hidden = data.messages.length > 0;
  $('inboxes-spinner').hidden = !data.busy;
  $('inboxes-empty-title').textContent = data.busy ? '正在读取收件箱' : errors.length ? '暂时无法读取收件箱' : '收件箱里还没有邮件';
  $('inboxes-empty-description').textContent = data.busy ? '各账号的来信将在这里按时间排列。' : errors.length ? '请验证账号或点击顶部刷新按钮重试。' : '新邮件会显示在这里。';
  $('inboxes-more').hidden = !data.hasMore;
  $('inboxes-more').disabled = data.busy;
  $('inboxes-more').textContent = data.busy ? '正在读取…' : '加载更多';
  $('inboxes').setAttribute('aria-busy', String(data.busy));
}
function render(state) {
  current = state;
  const all = state.mode === 'inboxes';
  if (!$('region').options.length) for (const region of state.regions) $('region').add(new Option(region.label, region.id));
  if (!$('account-region').options.length) for (const region of state.regions) $('account-region').add(new Option(region.label, region.id));
  $('region').value = state.region;
  $('region-control').hidden = state.accounts.length > 0;
  $('account-control').hidden = state.accounts.length === 0;
  const signature = JSON.stringify(state.accounts);
  if ($('accounts').dataset.signature !== signature) {
    $('accounts').replaceChildren(new Option('所有收件箱', '__all__'), ...state.accounts.map(account => new Option(account.name, account.id)));
    $('accounts').dataset.signature = signature;
  }
  $('accounts').value = all ? '__all__' : state.activeAccountId ?? '';
  $('accounts').disabled = state.busy;
  $('add-account').disabled = state.busy;
  $('all-inboxes').hidden = !state.accounts.length;
  $('all-inboxes').disabled = state.busy;
  $('all-inboxes').setAttribute('aria-pressed', String(all));
  $('welcome-hint').textContent = state.accounts.length ? '选择右上角的账号继续，或点击 ＋ 添加另一个账号。' : '先在右上角选择邮箱地区，然后使用 Zoho 账号登录。';
  $('version').textContent = `v${state.version}`;
  const dialog = $('account-dialog');
  if (state.accountDialog && !dialog.open) {
    const rename = state.accountDialog.mode === 'rename';
    $('account-dialog-title').textContent = rename ? '重命名账号' : '添加账号';
    $('account-dialog-description').textContent = rename ? '名称仅在这台电脑的账号列表中显示。' : '每个账号独立登录，可随时切换。';
    $('account-submit').textContent = rename ? '保存名称' : '添加并登录';
    $('account-name').value = state.accountDialog.name;
    $('account-region').value = state.accountDialog.region;
    $('account-region-field').hidden = rename;
    $('account-error').textContent = '';
    dialog.showModal();
  } else if (!state.accountDialog && dialog.open) dialog.close();
  $('account-submit').disabled = state.busy;
  $('account-cancel').disabled = state.busy;
  $('welcome').hidden = all || state.phase !== 'welcome'; $('loading').hidden = all || state.phase !== 'loading'; $('error').hidden = all || state.phase !== 'error';
  $('inboxes').hidden = !all;
  if (all) renderInboxes(state);
  $('error-message').textContent = state.error; $('host').textContent = all ? '' : state.host || '你的邮件，独立一窗。';
  $('back').disabled = all || !state.back; $('forward').disabled = all || !state.forward;
  $('reload').disabled = state.busy || (all ? state.inbox?.busy : state.phase === 'welcome' || (state.authPage && state.phase !== 'error'));
  $('home').disabled = all || !state.canGoHome || state.authPage || state.busy || state.loading || state.phase === 'error';
  $('reload').title = all ? '刷新所有收件箱 ⌘R' : state.authPage ? '登录或验证期间暂停刷新' : '刷新当前页面 ⌘R';
  $('home').title = state.authPage ? '登录或验证完成后可返回邮箱首页' : '返回邮箱首页 ⌘1';
  $('progress').hidden = !(all ? state.inbox?.busy : state.loading); $('connect').disabled = state.loading;
  $('status').textContent = all ? (state.inbox?.busy ? '正在汇总各账号邮件…' : '所有收件箱 · 每分钟自动刷新') : state.authPage && state.phase !== 'error' ? '正在登录或验证账号' :
    state.downloads || (state.loading ? '正在安全连接…' : state.phase === 'mail' ? '已连接 Zoho 邮件' : state.phase === 'error' ? '连接未完成' : '准备就绪');
}
async function act(action) { try { await action(); } catch { $('status').textContent = '操作未完成，请重试。'; } }
$('connect').addEventListener('click', () => act(() => window.mailDesk.open($('region').value)));
$('retry').addEventListener('click', () => act(() => window.mailDesk.open($('region').value)));
$('back').addEventListener('click', () => act(() => window.mailDesk.navigate('back')));
$('forward').addEventListener('click', () => act(() => window.mailDesk.navigate('forward')));
$('reload').addEventListener('click', () => act(() => window.mailDesk.reload()));
$('home').addEventListener('click', () => act(() => window.mailDesk.home()));
$('all-inboxes').addEventListener('click', () => act(() => window.mailDesk.showInboxes()));
$('inboxes-more').addEventListener('click', () => act(() => window.mailDesk.moreInboxes()));
$('accounts').addEventListener('change', () => act(() => $('accounts').value === '__all__' ? window.mailDesk.showInboxes() : window.mailDesk.switchAccount($('accounts').value)));
$('add-account').addEventListener('click', () => act(() => window.mailDesk.showAccountForm('add')));
$('account-cancel').addEventListener('click', () => act(() => window.mailDesk.closeAccountForm()));
$('account-dialog').addEventListener('cancel', event => { event.preventDefault(); if (!current.busy) void act(() => window.mailDesk.closeAccountForm()); });
$('account-form').addEventListener('submit', async event => {
  event.preventDefault();
  if (current.busy) return;
  $('account-submit').disabled = true;
  try { await window.mailDesk.submitAccount({ name: $('account-name').value, region: $('account-region').value }); }
  catch { $('account-error').textContent = '未能保存账号，请检查名称和地区后重试。'; }
  finally { $('account-submit').disabled = false; }
});
window.mailDesk.onState(render);
void act(async () => render(await window.mailDesk.getState()));
