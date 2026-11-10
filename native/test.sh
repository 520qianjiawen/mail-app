#!/bin/bash
set -euo pipefail
native_root="$(cd "$(dirname "$0")" && pwd)"
native_test_dir="$(mktemp -d /tmp/mail-native-tests.XXXXXX)"
cleanup_test_dir() {
  local resolved expected_parent
  resolved="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "${native_test_dir:?}")"
  expected_parent="$(python3 -c 'import os; print(os.path.realpath("/tmp"))')"
  if [[ -d "$native_test_dir" && ! -L "$native_test_dir" && "$(dirname "$resolved")" == "$expected_parent" && "$(basename "$resolved")" == mail-native-tests.* ]]; then
    rm -rf -- "$resolved"
  fi
}
trap cleanup_test_dir EXIT
xcrun swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macosx14.0 \
  -framework WebKit -framework CryptoKit -framework ImageIO "$native_root/Sources/Models.swift" "$native_root/Sources/MailAppearanceMode.swift" "$native_root/Sources/SenderIdentityModels.swift" "$native_root/Sources/SenderIdentityDiscovery.swift" "$native_root/Sources/MailReminderModels.swift" "$native_root/Sources/SignatureModels.swift" "$native_root/Sources/SignatureHTML.swift" \
  "$native_root/Sources/MailBodyPolicy.swift" "$native_root/Sources/MailServerRejection.swift" "$native_root/Sources/MailUploadProgress.swift" "$native_root/Sources/MailUploadFailure.swift" "$native_root/Sources/MailUploadDiagnostic.swift" "$native_root/Sources/MailInlineImageSend.swift" "$native_root/Sources/MailSourceIP.swift" "$native_root/Sources/MailDetail.swift" "$native_root/Sources/MailQuoteSeparator.swift" "$native_root/Sources/MailInlineImageReference.swift" "$native_root/Sources/MailOriginalHTML.swift" "$native_root/Sources/MailRasterImage.swift" "$native_root/Sources/MailOfficialProtocol.swift" "$native_root/Sources/MailOfficialAPI.swift" "$native_root/Sources/MailAPI.swift" "$native_root/Sources/MailboxAPI.swift" "$native_root/Sources/ZohoAPI.swift" "$native_root/Sources/ZohoOAuthManager.swift" "$native_root/Tests/APIHarness.swift" -o "$native_test_dir/api-tests"
"$native_test_dir/api-tests"
