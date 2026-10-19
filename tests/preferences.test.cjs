'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { readPreferences, savePreferences, newAccount, accountPartition } = require('../src/preferences.cjs');
test('corrupt preferences cannot select arbitrary origins or invalid sizes', t => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'mail-lite-prefs-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  fs.writeFileSync(path.join(directory, 'preferences.json'), 'broken');
  assert.equal(readPreferences(directory).region, 'global');
  savePreferences(directory, { region: 'https://evil.example', opened: 'yes', width: -5, height: 90000 });
  const value = readPreferences(directory);
  assert.equal(value.region, 'global'); assert.equal(value.opened, false);
  assert.equal(value.width, 900); assert.equal(value.height, 1600);
});
test('upgrade preserves legacy per-region partitions without moving login data', t => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'mail-lite-migration-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  fs.mkdirSync(path.join(directory, 'Partitions/mail-lite-china'), { recursive: true });
  savePreferences(directory, { region: 'global', opened: true });
  const migrated = readPreferences(directory);
  assert.equal(migrated.activeAccountId, 'legacy-global');
  assert.deepEqual(migrated.accounts.map(accountPartition), ['persist:mail-lite-global', 'persist:mail-lite-china']);
  savePreferences(directory, migrated);
  assert.deepEqual(readPreferences(directory).accounts, migrated.accounts);
});
test('accounts in the same region use different immutable partitions', () => {
  const prefs = { accounts: [] };
  const first = newAccount(prefs, { name: '工作邮箱', region: 'global' });
  const second = newAccount(prefs, { name: '个人邮箱', region: 'global' });
  assert.notEqual(accountPartition(first), accountPartition(second));
  assert.equal(first.name, '工作邮箱');
  assert.throws(() => newAccount(prefs, { region: 'evil.example' }));
});
test('corrupt account identities cannot redirect or share another partition', t => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'mail-lite-account-input-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  savePreferences(directory, { accounts: [
    { name: 'missing id', region: 'global' }, { id: '../../victim', region: 'global' },
    { id: 'legacy-china', region: 'global' }, { id: 'one', region: 'evil.example' },
    { id: 'valid', region: 'global', name: ' Work\u0000 ', partition: 'persist:other-app' },
    { id: 'valid', region: 'china', name: 'duplicate' }
  ], activeAccountId: 'nonexistent' });
  const prefs = readPreferences(directory);
  assert.deepEqual(prefs.accounts, [{ id: 'valid', region: 'global', name: 'Work' }]);
  assert.equal(prefs.activeAccountId, 'valid');
  assert.equal(accountPartition(prefs.accounts[0]), 'persist:mail-lite-account-valid');
});
