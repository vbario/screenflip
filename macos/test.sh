#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p build/tests
xcrun swiftc \
  Sources/Geometry.swift \
  Tests/main.swift \
  -framework CoreGraphics \
  -o build/tests/GeometryTests

build/tests/GeometryTests
