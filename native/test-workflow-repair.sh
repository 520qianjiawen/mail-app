#!/bin/bash
# Only isolated fixture storage and fake transports; no install, login or send.
set -euo pipefail
native_root="$(cd "$(dirname "$0")" && pwd)"
test_dir="$(mktemp -d /tmp/mail-lite-workflow-repair.XXXXXX)"
trap 'rm -rf -- "$test_dir"' EXIT
xcrun swiftc -swift-version 5 -target arm64-apple-macosx14.0 \
  -framework AppKit -framework WebKit -framework CryptoKit -framework ImageIO \
  -framework PDFKit -framework Quartz -framework SwiftUI -framework UserNotifications -lsqlite3 \
  "$native_root"/Sources/*.swift -o "$test_dir/Mail Lite Test"
"$test_dir/Mail Lite Test" --workflow-repair-test
