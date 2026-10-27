#!/bin/bash
set -euo pipefail
native_root="$(cd "$(dirname "$0")" && pwd)"
test_dir="$(mktemp -d /tmp/mail-lite-signature-html.XXXXXX)"
cleanup_test_dir() {
  local resolved expected_parent
  resolved="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "${test_dir:?}")"
  expected_parent="$(python3 -c 'import os; print(os.path.realpath("/tmp"))')"
  if [[ -d "$test_dir" && ! -L "$test_dir" && "$(dirname "$resolved")" == "$expected_parent" && "$(basename "$resolved")" == mail-lite-signature-html.* ]]; then
    rm -rf -- "$resolved"
  fi
}
trap cleanup_test_dir EXIT
xcrun swiftc -swift-version 5 -target arm64-apple-macosx14.0 \
  -framework AppKit -framework WebKit -framework CryptoKit \
  -framework PDFKit -framework Quartz -framework SwiftUI -lsqlite3 \
  "$native_root"/Sources/*.swift -o "$test_dir/Mail Lite Test"
"$test_dir/Mail Lite Test" --signature-html-test
"$test_dir/Mail Lite Test" --signature-test
