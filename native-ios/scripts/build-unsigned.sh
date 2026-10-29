#!/bin/bash
# Build without an Apple signing identity. The final ad-hoc signature only carries
# requested entitlements for a later Windows re-sign; it cannot install on iPhone.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
native_root="$repo_root/native-ios"
build_root="$native_root/build"
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
run_root="$build_root/runs/$run_id"
artifact_root="$run_root/artifacts"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This build needs macOS + Xcode. Windows can generate the Web assets with node _tools/build-ios.js." >&2
  exit 1
fi
cd "$repo_root"
mkdir -p "$artifact_root"
# Every run has its own logs/artifacts; a failed build cannot expose an older IPA.
exec > >(tee "$run_root/build.log") 2>&1
trap 'build_status=$?; echo "Build exit: $build_status; evidence: $run_root"' EXIT
bash "$native_root/scripts/preflight.sh"
node _tools/build-ios.js
package_root="$(mktemp -d "$run_root/package.XXXXXX")"
icon_source="$repo_root/icons/icon-512-v3.png"
icon_target="$native_root/App/Assets.xcassets/AppIcon.appiconset/AppIcon.png"

# Reuse the existing artwork. CoreGraphics only sizes it for Xcode and removes
# the unused alpha channel; the PWA image and visual design remain unchanged.
xcrun swift - "$icon_source" "$icon_target" <<'SWIFT'
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count == 3,
      let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: arguments[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      let context = CGContext(data: nil, width: 1024, height: 1024,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
else { fatalError("Cannot prepare existing app icon") }
context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
context.interpolationQuality = .high
context.draw(image, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
guard let output = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: arguments[2]) as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fatalError("Cannot create app icon") }
CGImageDestinationAddImage(destination, output, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Cannot save app icon") }
SWIFT

plutil -lint "$native_root/App/Info.plist" "$native_root/App/KcalAnalysis.entitlements" "$native_root/App/PrivacyInfo.xcprivacy"
xcodegen generate --spec "$native_root/project.yml" --project "$native_root"
xcodebuild \
  -project "$native_root/KcalAnalysis.xcodeproj" \
  -scheme KcalAnalysis \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$run_root/DerivedData" \
  -resultBundlePath "$run_root/Build.xcresult" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY= \
  DEVELOPMENT_TEAM= \
  build

app_path="$run_root/DerivedData/Build/Products/Release-iphoneos/KcalAnalysis.app"
if [[ ! -f "$app_path/Web/index.html" || ! -f "$app_path/KcalAnalysis" ]]; then
  echo "Build did not produce the native app with its bundled Web/index.html." >&2
  exit 1
fi
plutil -lint "$app_path/Info.plist" "$app_path/PrivacyInfo.xcprivacy"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Info.plist")" == "com.starkpez.kcalanalysis" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Info.plist")" == "1.0.0" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_path/Info.plist")" == "1" ]]
/usr/libexec/PlistBuddy -c 'Print :NSHealthShareUsageDescription' "$app_path/Info.plist" >/dev/null
# Confirm Xcode copied every generated Web file byte-for-byte, with no extras.
node - "$native_root/Web" "$app_path/Web" <<'NODE'
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const [source,bundled]=process.argv.slice(2);
function list(root,relative=''){
  return fs.readdirSync(path.join(root,relative),{withFileTypes:true}).flatMap(entry=>{
    const file=path.join(relative,entry.name);
    assert(!entry.isSymbolicLink(),'Unexpected linked Web resource');
    return entry.isDirectory()?list(root,file):[file];
  }).sort();
}
const expected=list(source);assert.deepEqual(list(bundled),expected);
for(const file of expected)assert(fs.readFileSync(path.join(source,file)).equals(fs.readFileSync(path.join(bundled,file))),'Bundled Web mismatch: '+file);
console.log('PASS bundled Web inventory/checksums: '+expected.length+' files');
NODE

# This is not an Apple development signature or a provisioning profile. It
# allows the re-signing tool to inspect our declared HealthKit entitlement.
codesign --force --sign - \
  --entitlements "$native_root/App/KcalAnalysis.entitlements" \
  --generate-entitlement-der "$app_path"
codesign --verify --strict "$app_path"
codesign --display --entitlements - --xml "$app_path" > "$artifact_root/requested-entitlements.plist"
plutil -lint "$artifact_root/requested-entitlements.plist"
/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.healthkit' \
  "$artifact_root/requested-entitlements.plist" | /usr/bin/grep -qx true

mkdir -p "$package_root/Payload"
ditto "$app_path" "$package_root/Payload/KcalAnalysis.app"
(
  cd "$package_root"
  /usr/bin/zip -qry KcalAnalysis-unprovisioned.ipa Payload
)
cp "$package_root/KcalAnalysis-unprovisioned.ipa" "$artifact_root/KcalAnalysis-unprovisioned.ipa"
cp "$native_root/App/KcalAnalysis.entitlements" "$artifact_root/KcalAnalysis.entitlements"
if [[ -f "$repo_root/ios-checkpoint.json" ]]; then
  cp "$repo_root/ios-checkpoint.json" "$artifact_root/ios-checkpoint.json"
fi
{
  echo "Built UTC: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Run: $run_id"
  echo "Apple signing: none (ad-hoc metadata only)"
  node --version
  xcodegen --version
  xcodebuild -version
  xcrun --sdk iphoneos --show-sdk-version
  if [[ -d "$repo_root/.git" ]]; then
    git rev-parse HEAD
    git status --short --untracked-files=all
  fi
} > "$artifact_root/BUILD-INFO.txt"
(
  cd "$artifact_root"
  shasum -a 256 KcalAnalysis-unprovisioned.ipa KcalAnalysis.entitlements requested-entitlements.plist BUILD-INFO.txt > SHA256SUMS.txt
)
cat > "$artifact_root/INSTALL-NOTES.txt" <<'NOTES'
KcalAnalysis-unprovisioned.ipa has NO Apple certificate or provisioning profile.
Its ad-hoc signature carries HealthKit metadata only. It cannot install directly.
Sign locally on Windows with your own free Apple ID. No credentials go to CI.
Both the final signature and provisioning profile must permit
com.apple.developer.healthkit = true. The included entitlement file is a request,
not a grant. Re-signing tools may remove capabilities; test on iPhone first.
Keep the same Apple ID and final Bundle ID for updates/refreshes; do not uninstall.
Use synthetic-backup-v7.json for first acceptance; keep real records in the PWA.
Migrate only after device/refresh acceptance and explicit user confirmation.
App and PWA have separate storage. Share completion is not proof of file saving.
See native-ios/README.md in the source for installation and migration steps.
NOTES
echo "Built: $artifact_root/KcalAnalysis-unprovisioned.ipa"
echo "Still required: Windows signing, iPhone installation, HealthKit and refresh verification."
