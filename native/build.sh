#!/bin/bash
set -euo pipefail
native_root="$(cd "$(dirname "$0")" && pwd)"
project_root="$(dirname "$native_root")"
native_version="0.4.71"
native_output="$project_root/dist/$native_version"
native_app="$native_output/Mail Lite.app"
mkdir -p "$native_app/Contents/MacOS" "$native_app/Contents/Resources"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx14.0 \
  -framework AppKit -framework WebKit -framework CryptoKit -framework Security -framework ImageIO -framework PDFKit -framework Quartz -framework SwiftUI -framework UserNotifications -lsqlite3 \
  "$native_root"/Sources/*.swift -o "$native_app/Contents/MacOS/Mail Lite"
cp "$project_root/assets/Mail_macOS.icns" "$native_app/Contents/Resources/MailLite.icns"
xcrun actool "$project_root/assets/Mail_macOS.icon" --compile "$native_app/Contents/Resources" \
  --platform macosx --minimum-deployment-target 14.0 --app-icon Mail_macOS \
  --output-partial-info-plist "$native_output/icon-info.plist" >/dev/null
python3 - "$native_app" "$native_version" <<'PY'
import sys, plistlib
from pathlib import Path
app, version = Path(sys.argv[1]), sys.argv[2]
info = {
    'CFBundleExecutable': 'Mail Lite', 'CFBundleIdentifier': 'local.mail-lite.native',
    'CFBundleName': 'Mail Lite', 'CFBundleDisplayName': 'Mail Lite', 'CFBundlePackageType': 'APPL',
    'CFBundleShortVersionString': version, 'CFBundleVersion': version,
    'CFBundleIconFile': 'MailLite.icns', 'CFBundleIconName': 'Mail_macOS',
    'LSMinimumSystemVersion': '14.0', 'NSHighResolutionCapable': True,
    'NSPrincipalClass': 'NSApplication', 'LSApplicationCategoryType': 'public.app-category.productivity',
    'NSHumanReadableCopyright': 'Personal mail client - independent of Zoho',
}
with (app/'Contents/Info.plist').open('wb') as f: plistlib.dump(info,f)
PY
verified_output="$(cd "$native_output" && pwd -P)"
[[ "$verified_output" == "$project_root/dist/$native_version" ]] || { echo 'Unexpected build output path' >&2; exit 1; }
rm -f -- "$verified_output/icon-info.plist"
codesign --force --sign - "$native_app"
if [[ "${MAIL_LITE_SKIP_CHECKS:-0}" != "1" ]]; then
  codesign --verify --deep --strict "$native_app"
  "$native_app/Contents/MacOS/Mail Lite" --self-test
fi
# After packaging and installation, run native/cleanup.py. Cleaning here can
# remove the build copy before the DMG has been created.
printf '%s\n' "$native_app"
