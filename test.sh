#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
swiftc -swift-version 5 -parse-as-library Sources/TrackingData.swift Tests/TrackingDataTests.swift -o build/TrackingDataTests
build/TrackingDataTests
