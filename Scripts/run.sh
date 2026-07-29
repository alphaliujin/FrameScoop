#!/bin/bash
#
# run.sh
# 以 Debug 配置快速构建并直接运行应用（本地开发测试用）。
#
set -euo pipefail
export CONFIG=Debug
bash "$(dirname "$0")/build.sh"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$ROOT/build/DerivedData/Build/Products/Debug/FrameScoop.app"

# 清除隔离属性，避免 Gatekeeper 拦截本地未签名构建
xattr -cr "$APP_PATH" 2>/dev/null || true

echo "-> 启动 FrameScoop…"
open "$APP_PATH"
