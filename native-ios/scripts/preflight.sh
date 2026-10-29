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
if [[ -n "${DEVELOPER_DIR:-}" && ! -d "$DEVELOPER_DIR" ]]; then
  echo "Configured Xcode does not exist: $DEVELOPER_DIR" >&2
  exit 1
fi
node --version
xcodegen --version
xcode-select -p
xcodebuild -version
xcode_version="$(xcodebuild -version | /usr/bin/awk 'NR == 1 { print $2 }')"
iphoneos_sdk="$(xcrun --sdk iphoneos --show-sdk-version)"
simulator_sdk="$(xcrun --sdk iphonesimulator --show-sdk-version)"
node - "$xcode_version" "$iphoneos_sdk" "$simulator_sdk" <<'NODE'
const [xcode,device,simulator]=process.argv.slice(2);
for(const [name,version] of [['Xcode',xcode],['iPhoneOS SDK',device],['iPhone Simulator SDK',simulator]]){
  if(!/^\d+(?:\.\d+)*$/.test(version)||Number(version.split('.')[0])<26){
    throw new Error(name+' 26 or later is required for the native Liquid Glass build; selected '+version+'. Select full Xcode 26+, not the runner default Xcode 16.4.');
  }
  console.log(name+': '+version);
}
NODE
xcrun --sdk iphoneos --find swiftc
xcrun --find simctl
xcrun --find xcresulttool
plutil -lint "$repo_root/native-ios/App/Info.plist" \
  "$repo_root/native-ios/App/KcalAnalysis.entitlements" "$repo_root/native-ios/App/PrivacyInfo.xcprivacy"
if [[ -f "$repo_root/ios-checkpoint.json" ]]; then
  node "$repo_root/_tools/prepare-ios-checkpoint.js" --verify
fi
echo "PASS macOS tools, Xcode/iOS SDK 26+ and plist preflight. Native compile has not run yet."
