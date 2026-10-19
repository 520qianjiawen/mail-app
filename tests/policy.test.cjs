'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { canNavigateInside, isAppURL, externalURL, REGIONS } = require('../src/policy.cjs');
test('mail and account routes use exact HTTPS hosts across supported data centres', () => {
  for (const { domain } of REGIONS) {
    assert.equal(canNavigateInside(`https://mail.${domain}/zm/`), true);
    assert.equal(canNavigateInside(`https://accounts.${domain}/signin`), true);
  }
});
test('untrusted pages and lookalike domains cannot inherit an in-app mail context', () => {
  for (const value of ['http://mail.zoho.com/zm/', 'https://mail.zoho.com.evil.example/',
    'https://mail.zoho.com@evil.example/', 'https://evil.example@mail.zoho.com/', 'https://mail.zoho.com:1234/',
    'https://writer.zoho.com/', 'file:///etc/passwd', 'javascript:alert(1)', 'data:text/html,hello',
    'blob:https://evil.example/id', 'about:blank']) assert.equal(canNavigateInside(value), false, value);
  assert.equal(canNavigateInside('about:blank', { popup: true }), true);
  assert.equal(canNavigateInside('blob:https://mail.zoho.com/id'), true);
});
test('external links reject executable or local schemes and embedded credentials', () => {
  assert.equal(externalURL('https://example.com/document'), 'https://example.com/document');
  assert.equal(externalURL('mailto:test@example.com'), 'mailto:test@example.com');
  for (const value of ['file:///tmp/test', 'javascript:alert(1)', 'data:text/html,x', 'vscode://foo', 'https://user:password@example.com/']) assert.equal(externalURL(value), null);
  assert.equal(isAppURL('https://accounts.google.com/'), false);
});
