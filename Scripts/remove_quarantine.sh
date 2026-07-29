#!/bin/bash
#
# remove_quarantine.sh
# 清除指定 App 的 Gatekeeper 隔离属性（com.apple.quarantine 等）。
#
# 适用场景：
#   - 本地未签名构建被 Gatekeeper 拦截（“无法打开，因为无法验证开发者”）
#   - 分发测试包给他人时，对方机器上的临时放行
#
# 用法:
#   bash Scripts/remove_quarantine.sh [path/to/FrameScoop.app]
#   不传路径时默认作用于构建产物 Release 目录。
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:-$ROOT/build/DerivedData/Build/Products/Release/FrameScoop.app}"

if [ ! -d "$APP_PATH" ]; then
  echo "✗ 未找到目标: $APP_PATH" >&2
  echo "  用法: bash Scripts/remove_quarantine.sh [path/to.app]" >&2
  exit 1
fi

# -c 清除所有扩展属性，-r 递归
xattr -cr "$APP_PATH"

echo "✅ 已清除隔离属性: $APP_PATH"
echo "   现在可以双击打开，或执行: open \"$APP_PATH\""
