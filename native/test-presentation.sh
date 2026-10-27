#!/bin/bash
set -euo pipefail
native_root="$(cd "$(dirname "$0")" && pwd)"
project_root="$(dirname "$native_root")"
test_dir="$(mktemp -d /tmp/mail-lite-presentation.XXXXXX)"
mkdir -p "$project_root/analysis/presentation"
visual_dir="$(mktemp -d "$project_root/analysis/presentation/visual.XXXXXX")"
printf 'Native layout screenshot directory: %s\n' "$visual_dir"
cleanup_test_dir() {
  local resolved expected_parent
  resolved="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "${test_dir:?}")"
  expected_parent="$(python3 -c 'import os; print(os.path.realpath("/tmp"))')"
  if [[ -d "$test_dir" && ! -L "$test_dir" && "$(dirname "$resolved")" == "$expected_parent" && "$(basename "$resolved")" == mail-lite-presentation.* ]]; then
    rm -rf -- "$resolved"
  fi
}
trap cleanup_test_dir EXIT
xcrun swiftc -swift-version 5 -target arm64-apple-macosx14.0 \
  -framework AppKit -framework WebKit -framework CryptoKit \
  -framework PDFKit -framework Quartz -framework SwiftUI -framework UserNotifications -lsqlite3 \
  "$native_root"/Sources/*.swift -o "$test_dir/Mail Lite Test"
"$test_dir/Mail Lite Test" --presentation-test --presentation-output "$visual_dir"
