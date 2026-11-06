#!/bin/bash
# 纯逻辑单元测试：坐标换算 / 裁剪 / 快捷键描述 / 设置持久化
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BUILD="$ROOT/build/tests"
mkdir -p "$BUILD/tmp" "$BUILD/clangcache" "$BUILD/bin"
export TMPDIR="$BUILD/tmp"
export CLANG_MODULE_CACHE_PATH="$BUILD/clangcache"
export SWIFT_MODULE_CACHE_PATH="$BUILD/clangcache"

swiftc -swift-version 5 -typecheck >/dev/null 2>&1 || true

swiftc -swift-version 5 -parse-as-library \
    -target "$(uname -m)-apple-macos14.0" \
    -framework AppKit -framework Carbon \
    "$ROOT/Sources/Core/Models.swift" \
    "$ROOT/Sources/Core/CaptureGeometry.swift" \
    "$ROOT/Sources/Core/GlobalHotKey.swift" \
    "$ROOT/Tests/TestMain.swift" \
    -o "$BUILD/bin/PinShotTests"

"$BUILD/bin/PinShotTests"
