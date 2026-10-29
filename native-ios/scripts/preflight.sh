#!/bin/bash
# Read-only macOS tool/SDK checks. Does not install tools, sign or upload.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Preflight requires macOS and full Xcode; Windows checks are not a native compile." >&2
  exit 1
fi
for required_tool in node xcodegen xcodebuild xcrun codesign plutil ditto shasum zip; do
  if ! command -v "$required_tool" >/dev/null 2>&1; then
    echo "Missing required build tool: $required_tool" >&2
    exit 1
  fi
done
node --version
xcodegen --version
xcode-select -p
xcodebuild -version
xcrun --sdk iphoneos --show-sdk-version
xcrun --sdk iphoneos --find swiftc
plutil -lint "$repo_root/native-ios/App/Info.plist" \
  "$repo_root/native-ios/App/KcalAnalysis.entitlements" "$repo_root/native-ios/App/PrivacyInfo.xcprivacy"
if [[ -f "$repo_root/ios-checkpoint.json" ]]; then
  node "$repo_root/_tools/prepare-ios-checkpoint.js" --verify
fi
echo "PASS macOS tools, iphoneos SDK and plist preflight. Native compile has not run yet."
