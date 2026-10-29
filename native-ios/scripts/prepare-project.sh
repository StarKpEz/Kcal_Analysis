#!/bin/bash
# Shared generated inputs for simulator tests and the later device build.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
native_root="$repo_root/native-ios"
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Project preparation needs macOS + Xcode; Windows can generate Web assets separately." >&2
  exit 1
fi
cd "$repo_root"
node _tools/build-ios.js
icon_source="$repo_root/icons/icon-512-v3.png"
icon_target="$native_root/App/Assets.xcassets/AppIcon.appiconset/AppIcon.png"

# Resize the existing artwork and remove its unused alpha channel. The PWA
# source image and design remain unchanged.
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
