#!/bin/bash
# 重置 PinShot 的屏幕录制授权记录（用于 macOS TCC 陈旧条目导致的「开关已开但仍未授权」）。
# 用法：./scripts/reset-screen-permission.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/PinShot.app"
BUNDLE_ID="com.kuxin.pinshot"

echo "🔐 重置 $(basename "$APP") 的屏幕录制授权记录…"
if ! /usr/bin/tccutil reset ScreenCapture "$BUNDLE_ID"; then
    echo "❌ tccutil 执行失败。请在「终端」中运行："
    echo "   sudo tccutil reset ScreenCapture $BUNDLE_ID"
    exit 1
fi

echo "🚪 关闭旧进程并重新打开 PinShot…"
pkill -x PinShot 2>/dev/null || true
sleep 0.6
open "$APP"
echo "✅ 已重置。按 ⇧⌘2 测试；若系统弹出授权提示，请允许后退出并重开 PinShot。"
