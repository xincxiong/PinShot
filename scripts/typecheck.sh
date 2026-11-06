#!/bin/bash
# 全量类型检查（不产出 .app），开发期快速反馈
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BUILD="$ROOT/build"
mkdir -p "$BUILD/tmp" "$BUILD/clangcache"
export TMPDIR="$BUILD/tmp"
export CLANG_MODULE_CACHE_PATH="$BUILD/clangcache"
export SWIFT_MODULE_CACHE_PATH="$BUILD/clangcache"

SOURCES=$(find "$ROOT/Sources" -name '*.swift' | sort)
# shellcheck disable=SC2086
swiftc -swift-version 5 -parse-as-library -typecheck \
    -target "$(uname -m)-apple-macos14.0" \
    -framework AppKit \
    -framework ScreenCaptureKit \
    -framework Carbon \
    -framework ServiceManagement \
    -framework ImageIO \
    $SOURCES
echo "✅ 类型检查通过"
