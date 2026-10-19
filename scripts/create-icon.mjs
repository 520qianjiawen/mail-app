import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const assets = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../assets');
const iconset = path.join(assets, 'MailLite.iconset');
fs.mkdirSync(iconset, { recursive: true });
// Use an actual Icon Composer asset on modern macOS, rather than a compatibility
// plate around a padded legacy PNG. Scale the original layer; do not redraw it.
const composed = path.join(assets, 'MailLite.icon');
fs.mkdirSync(path.join(composed, 'Assets'), { recursive: true });
fs.copyFileSync(path.join(assets, 'logo.png'), path.join(composed, 'Assets', 'mail.png'));
fs.writeFileSync(path.join(composed, 'icon.json'), JSON.stringify({
  fill: { solid: 'srgb:0.00000,0.47059,0.96078,1.00000' },
  groups: [{ layers: [{ 'image-name': 'mail.png', name: 'Mail',
    position: { scale: 1.24, 'translation-in-points': [0, 0] },
    'glass': false
  }], shadow: { kind: 'neutral', opacity: 0 }, specular: false,
    translucency: { enabled: false, value: 0 } }],
  'supported-platforms': { squares: ['macOS'] }
}, null, 2));
for (const size of [16, 32, 128, 256, 512]) {
  for (const scale of [1, 2]) {
    const pixels = String(size * scale);
    execFileSync('/usr/bin/sips', ['-z', pixels, pixels, path.join(assets, 'logo.png'),
      '--out', path.join(iconset, `icon_${size}x${size}${scale === 2 ? '@2x' : ''}.png`)], { stdio: 'ignore' });
  }
}
execFileSync('/usr/bin/iconutil', ['-c', 'icns', iconset, '-o', path.join(assets, 'MailLite.icns')]);
