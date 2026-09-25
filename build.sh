#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="$(pwd)/build/TimeTracker.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/binaries
for arch in arm64 x86_64; do
    swiftc -swift-version 5 -O -parse-as-library -target "$arch-apple-macosx14.0" Sources/TrackingData.swift Sources/TimeTracker.swift -o "build/binaries/TimeTracker-$arch" -framework AppKit -framework SwiftUI -framework Carbon
done
lipo -create build/binaries/TimeTracker-arm64 build/binaries/TimeTracker-x86_64 -output "$APP/Contents/MacOS/TimeTracker"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
printf 'Built %s\n' "$APP"
