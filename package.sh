#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
bash test.sh
bash build.sh
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
ARCHIVE="TimeTracker-v$VERSION-macOS-universal.zip"
mkdir -p build/release
ditto -c -k --sequesterRsrc --keepParent build/TimeTracker.app "build/release/$ARCHIVE"
cd build/release
shasum -a 256 "$ARCHIVE" > SHA256SUMS.txt
printf 'Release package: %s\n' "$ARCHIVE"
