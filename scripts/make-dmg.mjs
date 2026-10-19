import { execFileSync } from 'node:child_process';
import path from 'node:path';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const version = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8')).version;
const staging = fs.mkdtempSync(path.join(root, 'dist/dmg-stage-'));
try {
  execFileSync('/usr/bin/ditto', [path.join(root, `dist/${version}/Mail Lite-darwin-arm64/Mail Lite.app`), path.join(staging, 'Mail Lite.app')]);
  fs.symlinkSync('/Applications', path.join(staging, 'Applications'));
  execFileSync('/usr/bin/hdiutil', ['create', '-volname', 'Mail Lite', '-srcfolder', staging,
    '-ov', '-format', 'UDZO', path.join(root, `dist/Mail-Lite-${version}-arm64.dmg`)], { stdio: 'inherit' });
} finally { fs.rmSync(staging, { recursive: true, force: true }); }
execFileSync(process.execPath, [path.join(root, 'scripts/cleanup-old-releases.mjs')], { stdio: 'inherit' });
