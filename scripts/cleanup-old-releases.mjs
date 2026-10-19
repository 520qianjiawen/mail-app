import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const dist = path.join(root, 'dist');
const version = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8')).version;
const latest = path.join(dist, version, 'Mail Lite-darwin-arm64/Mail Lite.app');
const register = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister';
const dryRun = process.argv.includes('--dry-run');
const versionPattern = /^\d+\.\d+\.\d+$/;
const older = candidate => {
  if (!versionPattern.test(candidate) || !versionPattern.test(version)) return false;
  const a = candidate.split('.').map(Number), b = version.split('.').map(Number);
  for (let i = 0; i < 3; i++) if (a[i] !== b[i]) return a[i] < b[i];
  return false;
};
const plist = (bundle, key) => execFileSync('/usr/bin/plutil', ['-extract', key, 'raw', path.join(bundle, 'Contents/Info.plist')], { encoding: 'utf8' }).trim();
const regularDirectory = directory => fs.existsSync(directory) && fs.lstatSync(directory).isDirectory() && !fs.lstatSync(directory).isSymbolicLink();

if (!regularDirectory(dist) || !regularDirectory(latest) || plist(latest, 'CFBundleIdentifier') !== 'local.mail-lite.desktop' ||
    plist(latest, 'CFBundleShortVersionString') !== version) throw new Error('Verified current Mail Lite release is required before cleanup.');
execFileSync('/usr/bin/codesign', ['--verify', '--deep', '--strict', latest]);
const running = execFileSync('/bin/ps', ['-axo', 'comm='], { encoding: 'utf8' });
const candidates = [], skipped = [];
for (const entry of fs.readdirSync(dist)) {
  const directory = path.join(dist, entry);
  if ((older(entry) || entry === 'Mail Lite-darwin-arm64') && regularDirectory(directory)) {
    const bundle = entry === 'Mail Lite-darwin-arm64' ? path.join(directory, 'Mail Lite.app') : path.join(directory, 'Mail Lite-darwin-arm64/Mail Lite.app');
    if (!regularDirectory(path.dirname(bundle)) || !regularDirectory(bundle) || plist(bundle, 'CFBundleIdentifier') !== 'local.mail-lite.desktop' || !older(plist(bundle, 'CFBundleShortVersionString'))) continue;
    if (running.includes(path.join(bundle, 'Contents/MacOS/Mail Lite'))) { skipped.push({ path: bundle, reason: 'running' }); continue; }
    candidates.push({ path: bundle, kind: 'app' });
  }
  const installer = /^Mail-Lite-(\d+\.\d+\.\d+)-arm64\.dmg$/.exec(entry);
  if (installer && older(installer[1]) && fs.lstatSync(directory).isFile()) candidates.push({ path: directory, kind: 'installer' });
}
const moved = [];
if (!dryRun) {
  const trash = path.join(process.env.HOME, '.Trash');
  fs.mkdirSync(trash, { recursive: true });
  for (const item of candidates) {
    if (item.kind === 'app') {
      try { execFileSync(register, ['-u', item.path], { stdio: 'ignore' }); } catch {}
    }
    const label = item.kind === 'app' ? `Mail Lite ${plist(item.path, 'CFBundleShortVersionString')}.app` : path.basename(item.path);
    let destination = path.join(trash, label), suffix = 1;
    while (fs.existsSync(destination)) destination = path.join(trash, `${path.parse(label).name} (${suffix++})${path.extname(label)}`);
    fs.renameSync(item.path, destination);
    moved.push({ from: item.path, to: destination });
    if (item.kind === 'app') {
      // Remove only empty generated parents; preserve any other contents.
      let parent = path.dirname(item.path);
      while (parent !== dist && parent.startsWith(`${dist}${path.sep}`)) {
        try { fs.rmdirSync(parent); } catch { break; }
        parent = path.dirname(parent);
      }
    }
  }
}
console.log(JSON.stringify({ dryRun, kept: latest, candidates, moved, skipped }, null, 2));
