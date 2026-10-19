'use strict';

const REGIONS = Object.freeze([
  { id: 'global', label: '国际 · zoho.com', domain: 'zoho.com' },
  { id: 'china', label: '中国 · zoho.com.cn', domain: 'zoho.com.cn' },
  { id: 'europe', label: '欧洲 · zoho.eu', domain: 'zoho.eu' },
  { id: 'india', label: '印度 · zoho.in', domain: 'zoho.in' },
  { id: 'australia', label: '澳大利亚 · zoho.com.au', domain: 'zoho.com.au' },
  { id: 'japan', label: '日本 · zoho.jp', domain: 'zoho.jp' },
  { id: 'canada', label: '加拿大 · zohocloud.ca', domain: 'zohocloud.ca' },
  { id: 'saudi', label: '沙特 · zoho.sa', domain: 'zoho.sa' },
  { id: 'uae', label: '阿联酋 · zoho.ae', domain: 'zoho.ae' },
  { id: 'singapore', label: '新加坡 · zoho.sg', domain: 'zoho.sg' }
]);
const MAIL_HOSTS = new Set(REGIONS.map(({ domain }) => `mail.${domain}`));
const ACCOUNT_HOSTS = new Set(REGIONS.map(({ domain }) => `accounts.${domain}`));
const FEDERATED_HOSTS = new Set(['accounts.google.com', 'login.microsoftonline.com', 'login.live.com', 'appleid.apple.com', 'appleid.apple.com.cn']);

function regionById(id) { return REGIONS.find(region => region.id === id); }
function parseWebURL(value) {
  try {
    const url = new URL(value);
    if (!['https:', 'http:'].includes(url.protocol) || url.username || url.password) return null;
    return url;
  } catch { return null; }
}
function isAppURL(value) {
  const url = parseWebURL(value);
  return Boolean(url && url.protocol === 'https:' && !url.port && (MAIL_HOSTS.has(url.hostname) || ACCOUNT_HOSTS.has(url.hostname)));
}
function isLoginURL(value) {
  const url = parseWebURL(value);
  return Boolean(url && url.protocol === 'https:' && !url.port && (ACCOUNT_HOSTS.has(url.hostname) || FEDERATED_HOSTS.has(url.hostname)));
}
function isMailURL(value) {
  const url = parseWebURL(value);
  return Boolean(url && url.protocol === 'https:' && !url.port && MAIL_HOSTS.has(url.hostname));
}
function canNavigateInside(value, { popup = false } = {}) {
  if (popup && value === 'about:blank') return true;
  if (value.startsWith('blob:')) return isMailURL(value.slice(5));
  return isAppURL(value) || isLoginURL(value);
}
function externalURL(value) {
  const url = parseWebURL(value);
  if (url) return url.href;
  try {
    const mailto = new URL(value);
    if (mailto.protocol === 'mailto:' && !/[\r\n]/.test(value)) return mailto.href;
  } catch {}
  return null;
}
function displayHost(value) { try { return new URL(value).hostname; } catch { return ''; } }
module.exports = { REGIONS, regionById, isAppURL, isLoginURL, isMailURL, canNavigateInside, externalURL, displayHost };
