#!/bin/bash
#
# build.sh
# 生成工程并编译 FrameScoop。
#
# 用法:
#   bash Scripts/build.sh                # 默认 Release
#   CONFIG=Debug bash Scripts/build.sh   # 指定配置
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="FrameScoop"
SCHEME="FrameScoop"
CONFIG="${CONFIG:-Release}"
DERIVED="$ROOT/build/DerivedData"

cd "$ROOT"

# 1. 确保工程与图标已就绪
bash Scripts/generate_project.sh

# 2. 编译（通用 macOS，支持 Apple Silicon + Intel）
echo "-> 编译 ($CONFIG)…"
set -x
xcodebuild \
  -project "$ROOT/$APP_NAME.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" \
  -destination 'generic/platform=macOS' \
  -quiet \
  build
set +x

APP_PATH="$DERIVED/Build/Products/$CONFIG/$APP_NAME.app"
echo "✅ 构建完成"
echo "   产物: $APP_PATH"
echo "   打开: open \"$APP_PATH\""
