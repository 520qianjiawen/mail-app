"""Keep the verified installed release and its DMG; trash redundant artifacts.

Run after installing the release. --dry-run inventories only. User mail, sessions,
and sources are outside the candidate set. Removed files remain recoverable.
"""
import argparse
import datetime
import hashlib
import json
import plistlib
import re
import shutil
import subprocess
import zipfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
dist = root / 'dist'
installed = Path('/Applications/Mail Lite.app')
register = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
ids = {'local.mail-lite.native', 'local.mail-lite.desktop'}

def info(app):
    with (app / 'Contents/Info.plist').open('rb') as stream:
        return plistlib.load(stream)

def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()

def version(value):
    assert isinstance(value, str) and re.fullmatch(r'\d+\.\d+\.\d+', value), value
    return tuple(map(int, value.split('.')))

def registered_paths():
    dump = subprocess.check_output([register, '-dump'], text=True)
    paths = set()
    for block in re.split(r'\n-{8,}\n', dump):
        if re.search(r'^identifier:\s+local\.mail-lite\.(native|desktop)\s*$', block, re.M):
            match = re.search(r'^path:\s+(.+?)\s+\(0x[0-9a-f]+\)\s*$', block, re.M)
            if match:
                paths.add(Path(match[1]))
    return paths

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    release = json.loads((root / 'package.json').read_text())['version']
    current = version(release)
    metadata = info(installed)
    assert metadata.get('CFBundleIdentifier') == 'local.mail-lite.native'
    assert metadata.get('CFBundleShortVersionString') == release, 'Install the latest release before cleanup'
    installer = dist / f'Mail-Lite-{release}-arm64.dmg'
    assert installer.is_file() and not installer.is_symlink()
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(installed)], check=True)
    if not args.dry_run:
        subprocess.run(['/usr/bin/hdiutil', 'verify', str(installer)], check=True, stdout=subprocess.DEVNULL)
    kept_hashes = {str(installed): sha(installed / 'Contents/MacOS/Mail Lite'), str(installer): sha(installer)}
    candidates = []
    for folder in sorted(dist.iterdir()):
        if folder.is_symlink():
            continue
        if folder.is_dir() and re.fullmatch(r'\d+\.\d+\.\d+', folder.name) and version(folder.name) <= current:
            app = folder / 'Mail Lite.app'
            children = {p.name for p in folder.iterdir()}
            if app.is_dir() and not app.is_symlink() and children <= {'Mail Lite.app', '.DS_Store'}:
                data = info(app)
                if data.get('CFBundleIdentifier') in ids and version(data['CFBundleShortVersionString']) <= current:
                    candidates.append(folder)
        match = re.fullmatch(r'Mail-Lite-(\d+\.\d+\.\d+)-arm64\.(dmg|zip|pkg)', folder.name)
        if match and folder.is_file() and folder != installer and version(match[1]) <= current:
            candidates.append(folder)
    for archive in sorted((root / 'analysis').rglob('*.zip')):
        if archive.is_symlink() or not (archive.name.startswith('before-app') or archive.name.startswith('Mail-Lite-before-')):
            continue
        try:
            with zipfile.ZipFile(archive) as bundle:
                entries = [n for n in bundle.namelist() if n.endswith('.app/Contents/Info.plist') and not n.startswith('__MACOSX/')]
                if not entries:
                    continue
                data = [plistlib.loads(bundle.read(name)) for name in entries]
                if all(item.get('CFBundleIdentifier') in ids and version(item.get('CFBundleShortVersionString')) <= current for item in data):
                    candidates.append(archive)
        except (OSError, ValueError, zipfile.BadZipFile, plistlib.InvalidFileException):
            continue
    probe = Path('/private/tmp/MailUploadChannelProbe.app')
    if probe.is_dir() and info(probe).get('CFBundleIdentifier') in ids and info(probe).get('CFBundleExecutable') == 'probe':
        candidates.append(probe)
    running = subprocess.check_output(['/bin/ps', '-axo', 'comm='], text=True).splitlines()
    for candidate in candidates:
        assert not candidate.is_symlink()
        assert not any(line.strip().startswith(str(candidate) + '/') for line in running), f'Candidate is running: {candidate}'
    registrations = registered_paths()
    remove_registrations = sorted(p for p in registrations if p != installed)
    result = {'keptApp': str(installed), 'keptInstaller': str(installer), 'dryRun': args.dry_run,
              'moveToTrash': [str(p) for p in candidates], 'unregister': [str(p) for p in remove_registrations]}
    if args.dry_run:
        print(json.dumps(result, ensure_ascii=False, indent=2)); return
    destination = Path.home() / '.Trash' / ('Mail Lite releases ' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))
    destination.mkdir(parents=True, exist_ok=False)
    for path in remove_registrations:
        subprocess.run([register, '-u', str(path)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    moved = []
    for candidate in candidates:
        relative = candidate.relative_to(root) if candidate.is_relative_to(root) else Path('temporary') / candidate.name
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(candidate), str(target))
        moved.append({'from': str(candidate), 'to': str(target)})
    for path in registered_paths():
        if path != installed:
            subprocess.run([register, '-u', str(path)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run([register, '-f', str(installed)], check=True)
    assert kept_hashes[str(installed)] == sha(installed / 'Contents/MacOS/Mail Lite')
    assert kept_hashes[str(installer)] == sha(installer)
    result.update({'movedToTrash': moved, 'trashDirectory': str(destination), 'keptHashesUnchanged': True})
    print(json.dumps(result, ensure_ascii=False, indent=2))

if __name__ == '__main__':
    main()
