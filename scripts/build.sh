#!/bin/bash
# 编译 PinShot 并组装 .app（本机仅有 Command Line Tools，不用 SwiftPM / Xcode）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BUILD="$ROOT/build"
APP="$BUILD/PinShot.app"
OPT_FLAG="-O"
if [ "${1:-}" = "--fast" ]; then
    OPT_FLAG="-Onone"
    echo "⚡️ 快速构建（-Onone）"
fi

# DSH 沙箱 / 一般环境：把编译缓存放在工程内，避免 ~/Library 与 /var/folders 权限问题
mkdir -p "$BUILD/tmp" "$BUILD/clangcache"
export TMPDIR="$BUILD/tmp"
export CLANG_MODULE_CACHE_PATH="$BUILD/clangcache"
export SWIFT_MODULE_CACHE_PATH="$BUILD/clangcache"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

SOURCES=$(find "$ROOT/Sources" -name '*.swift' | sort)
if [ -z "$SOURCES" ]; then
    echo "❌ 没有找到 Swift 源文件" >&2
    exit 1
fi

echo "🔨 编译 $(echo "$SOURCES" | wc -l | tr -d ' ') 个源文件…"
# shellcheck disable=SC2086
swiftc \
    -swift-version 5 \
    -parse-as-library \
    "$OPT_FLAG" \
    -target "$(uname -m)-apple-macos14.0" \
    -framework AppKit \
    -framework ScreenCaptureKit \
    -framework Carbon \
    -framework ServiceManagement \
    -framework ImageIO \
    $SOURCES \
    -o "$APP/Contents/MacOS/PinShot"

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# ad-hoc 签名 + 稳定的 designated requirement：
# 默认 ad-hoc 签名的 requirement 是 cdhash，每次重建都会变，TCC 授权随之失效；
# 显式指定 identifier 后 requirement 跨构建稳定，屏幕录制授权可以保留。
SIGNING_REQUIREMENT='=designated => identifier "com.kuxin.pinshot"'
codesign --force --deep --sign - --requirements "$SIGNING_REQUIREMENT" "$APP" >/dev/null 2>&1 || {
    echo "⚠️  ad-hoc 签名失败（应用仍可运行，但 TCC 权限可能在重建后重置）" >&2
}
codesign -d -r- "$APP" 2>/dev/null | tail -1 | sed 's/^/   designated requirement: /' || true

echo "✅ 构建完成: $APP"
echo "   运行: make run   安装: make install"
