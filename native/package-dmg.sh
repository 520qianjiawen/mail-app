#!/bin/bash
set -euo pipefail
native_root="$(cd "$(dirname "$0")" && pwd)"
project_root="$(dirname "$native_root")"
native_version="0.4.44"
native_app="$project_root/dist/$native_version/Mail Lite.app"
native_dmg="$project_root/dist/Mail-Lite-$native_version-arm64.dmg"
python="${MAIL_LITE_PYTHON:-python3}"
native_stage="$(mktemp -d "$project_root/dist/native-dmg.XXXXXX")"
native_payload="$native_stage/payload"
native_mount="$native_stage/mount"
native_mounted=0
cleanup_stage() {
  # Disk-image and payload copies must not leave duplicate app-search entries.
  local launch_register='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
  if [[ -x "$launch_register" ]]; then
    "$launch_register" -u "$native_payload/Mail Lite.app" >/dev/null 2>&1 || true
    "$launch_register" -u "$native_mount/Mail Lite.app" >/dev/null 2>&1 || true
  fi
  if [[ "$native_mounted" == "1" ]]; then
    hdiutil detach "$native_mount" >/dev/null || { echo "Retained mounted staging directory: $native_stage" >&2; return; }
  fi
  local resolved_stage
  resolved_stage="$("$python" -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "${native_stage:?}")"
  if [[ "$resolved_stage" == "$native_stage" && "$(dirname "$resolved_stage")" == "$project_root/dist" && "$(basename "$resolved_stage")" == native-dmg.* ]]; then
    rm -rf -- "$resolved_stage"
  fi
}
trap cleanup_stage EXIT
mkdir -p "$native_payload/.background" "$native_mount"
ditto "$native_app" "$native_payload/Mail Lite.app"
ln -s /Applications "$native_payload/Applications"
"$python" - "$native_payload/.background/install.png" "$native_version" <<'PY'
from PIL import Image, ImageDraw, ImageFont
import sys
image = Image.new('RGB', (1280, 800), '#f7f9fd')
draw = ImageDraw.Draw(image)
heading = ImageFont.load_default(size=38)
footer = ImageFont.load_default(size=23)
draw.text((640, 90), 'Drag Mail Lite to Applications', font=heading, fill='#24324b', anchor='mm')
draw.line((572, 360, 694, 360), fill='#6277e7', width=12)
draw.polygon([(674, 338), (704, 360), (674, 382)], fill='#6277e7')
draw.text((640, 714), 'Mail Lite ' + sys.argv[2] + '  |  macOS 14+  |  Apple Silicon', font=footer, fill='#79869b', anchor='mm')
# Finder icon-view background coordinates are logical points.
image.resize((640, 400), Image.Resampling.LANCZOS).save(sys.argv[1])
PY
hdiutil create -volname 'Mail Lite' -srcfolder "$native_payload" -format UDRW "$native_stage/installer-rw.dmg" >/dev/null
hdiutil attach "$native_stage/installer-rw.dmg" -noverify -nobrowse -mountpoint "$native_mount" >/dev/null
native_mounted=1
# Finder layout is optional. The default packaging path also works while the
# desktop is locked and never requires GUI scripting.
if [[ "${MAIL_LITE_FINDER_LAYOUT:-0}" == "1" ]]; then
osascript - "$native_mount" <<'APPLESCRIPT'
on run argv
  set mountPath to item 1 of argv
  tell application "Finder"
    set installerFolder to (POSIX file mountPath) as alias
    open installerFolder
    set installerWindow to container window of installerFolder
    set current view of installerWindow to icon view
    set toolbar visible of installerWindow to false
    set statusbar visible of installerWindow to false
    set bounds of installerWindow to {200, 150, 840, 590}
    set layoutOptions to icon view options of installerWindow
    set arrangement of layoutOptions to not arranged
    set icon size of layoutOptions to 112
    set text size of layoutOptions to 13
    set background picture of layoutOptions to file ".background:install.png" of installerFolder
    set position of item "Mail Lite.app" of installerFolder to {170, 180}
    set position of item "Applications" of installerFolder to {470, 180}
    set extension hidden of item "Mail Lite.app" of installerFolder to true
    update installerFolder without registering applications
    delay 1
    close installerWindow
  end tell
end run
APPLESCRIPT
fi

sync
hdiutil detach "$native_mount" >/dev/null
native_mounted=0
hdiutil convert "$native_stage/installer-rw.dmg" -format UDZO -imagekey zlib-level=9 -ov -o "$native_dmg" >/dev/null
printf '%s\n' "$native_dmg"
