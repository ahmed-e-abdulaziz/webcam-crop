#!/bin/zsh
# Runs the crop-maths unit tests (no camera, no Xcode needed).
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
swiftc -swift-version 5 Sources/Crop.swift Tests/main.swift -o build/crop-tests
build/crop-tests
