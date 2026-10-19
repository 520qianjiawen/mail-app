import { packager } from '@electron/packager';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const version = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8')).version;
const assets = path.join(root, 'assets');
fs.mkdirSync(assets, { recursive: true });
execFileSync(process.execPath, [path.join(root, 'scripts/create-icon.mjs')], { stdio: 'inherit' });
const outputDirectory = path.join(root, 'dist', version);
const staging = path.join(outputDirectory, 'app-source');
fs.mkdirSync(staging, { recursive: true });
for (const entry of ['package.json', 'src', 'ui']) fs.cpSync(path.join(root, entry), path.join(staging, entry), { recursive: true });
const outputs = await packager({ dir: staging, out: outputDirectory, name: 'Mail Lite',
  executableName: 'Mail Lite', appBundleId: 'local.mail-lite.desktop', platform: 'darwin', arch: 'arm64',
  electronVersion: '44.9.0', icon: path.join(assets, 'MailLite.icns'), asar: true, overwrite: true, prune: true,
  appCategoryType: 'public.app-category.productivity', appCopyright: 'Personal mail client — independent of Zoho',
  extendInfo: { LSMinimumSystemVersion: '12.0' }
});
for (const output of outputs) {
  const app = path.join(output, 'Mail Lite.app');
  // Keep the native glass icon on every release, including its compiled asset.
  const partialInfo = path.join(outputDirectory, 'icon-info.plist');
  execFileSync('/usr/bin/xcrun', ['actool', path.join(assets, 'MailLite.icon'),
    '--compile', path.join(app, 'Contents/Resources'), '--platform', 'macosx',
    '--minimum-deployment-target', '12.0', '--app-icon', 'MailLite',
    '--output-partial-info-plist', partialInfo], { stdio: 'inherit' });
  execFileSync('/usr/bin/plutil', ['-replace', 'CFBundleIconName', '-string', 'MailLite', path.join(app, 'Contents/Info.plist')]);
  fs.rmSync(partialInfo, { force: true });
  execFileSync('/usr/bin/codesign', ['--force', '--deep', '--sign', '-', app], { stdio: 'inherit' });
  execFileSync('/usr/bin/codesign', ['--verify', '--deep', '--strict', app], { stdio: 'inherit' });
  console.log(app);
}
fs.rmSync(staging, { recursive: true, force: true });
execFileSync(process.execPath, [path.join(root, 'scripts/cleanup-old-releases.mjs')], { stdio: 'inherit' });
