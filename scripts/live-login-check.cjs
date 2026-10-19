'use strict';
const { _electron: electron } = require('playwright-core');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'mail-lite-public-login-'));
let application;
(async () => {
  application = await electron.launch({ args: [root], executablePath: require('electron'),
    env: { ...process.env, MAIL_LITE_USER_DATA: profile }, timeout: 20000 });
  const page = await application.firstWindow();
  await page.getByRole('button', { name: '打开 Zoho 邮箱' }).click();
  let result;
  for (let attempt = 0; attempt < 100; attempt++) {
    result = await page.evaluate(() => window.mailDesk.getState());
    if (result.phase === 'mail' && result.host.startsWith('accounts.')) break;
    if (result.phase === 'error') throw new Error(result.error);
    await new Promise(resolve => setTimeout(resolve, 250));
  }
  if (result.phase !== 'mail' || !result.host.startsWith('accounts.')) throw new Error('Did not reach Zoho sign-in');
  fs.writeFileSync(path.join(root, 'test-results/live-login.json'), JSON.stringify({ reached: result.host, authenticated: false }, null, 2));
  console.log(`PASS: reached ${result.host}; stopped before entering credentials.`);
})().catch(error => { console.error(error.message); process.exitCode = 1; }).finally(async () => {
  if (application) {
    const child = application.process();
    await Promise.race([application.close().catch(() => {}), new Promise(resolve => setTimeout(resolve, 3000))]);
    if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
  }
  fs.rmSync(profile, { recursive: true, force: true });
});
