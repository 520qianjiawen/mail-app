'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { randomUUID } = require('node:crypto');
const { regionById, REGIONS } = require('./policy.cjs');
const ACCOUNT_ID = /^[a-z0-9-]{1,64}$/;
function accountPartition(account) {
  if (account.id === `legacy-${account.region}`) return `persist:mail-lite-${account.region}`;
  return `persist:mail-lite-account-${account.id}`;
}
function accountName(value, fallback) {
  return typeof value === 'string' ? value.replace(/[\u0000-\u001f\u007f]/g, '').trim().slice(0, 80) || fallback : fallback;
}
function newAccount(preferences, { name, region }) {
  if (!regionById(region)) throw new Error('Unknown mail region');
  return { id: randomUUID(), region, name: accountName(name, `账号 ${preferences.accounts.length + 1}`) };
}
function readPreferences(directory) {
  try {
    const data = JSON.parse(fs.readFileSync(path.join(directory, 'preferences.json'), 'utf8'));
    const region = regionById(data.region)?.id ?? 'global';
    const accounts = [];
    if (Array.isArray(data.accounts)) {
      const ids = new Set();
      for (const entry of data.accounts) {
        if (!entry || typeof entry.id !== 'string' || !ACCOUNT_ID.test(entry.id) || !regionById(entry.region) || ids.has(entry.id)) continue;
        // Partitions are derived locally. Arbitrary saved partition/path values are never trusted.
        if (entry.id.startsWith('legacy-') && entry.id !== `legacy-${entry.region}`) continue;
        ids.add(entry.id);
        accounts.push({ id: entry.id, region: entry.region, name: accountName(entry.name, `账号 ${accounts.length + 1}`) });
      }
    } else {
      // Reuse 0.1.0's exact partitions; do not copy, clear or inspect their cookies.
      for (const known of REGIONS) {
        if ((data.opened === true && known.id === region) || fs.existsSync(path.join(directory, 'Partitions', `mail-lite-${known.id}`))) {
          accounts.push({ id: `legacy-${known.id}`, region: known.id, name: `原有账号 · ${known.label.split(' · ')[0]}` });
        }
      }
    }
    const activeAccountId = accounts.some(account => account.id === data.activeAccountId) ? data.activeAccountId :
      accounts.find(account => account.region === region)?.id ?? accounts[0]?.id ?? null;
    return {
      schemaVersion: 2, accounts, activeAccountId, region, opened: data.opened === true,
      width: Number.isInteger(data.width) ? Math.max(900, Math.min(data.width, 2560)) : 1280,
      height: Number.isInteger(data.height) ? Math.max(640, Math.min(data.height, 1600)) : 850
    };
  } catch { return { schemaVersion: 2, accounts: [], activeAccountId: null, region: 'global', opened: false, width: 1280, height: 850 }; }
}
function savePreferences(directory, preferences) {
  fs.mkdirSync(directory, { recursive: true });
  const target = path.join(directory, 'preferences.json');
  fs.writeFileSync(`${target}.tmp`, JSON.stringify(preferences, null, 2), { mode: 0o600 });
  fs.renameSync(`${target}.tmp`, target);
}
module.exports = { readPreferences, savePreferences, newAccount, accountPartition, accountName };
