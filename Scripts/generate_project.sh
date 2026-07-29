#!/bin/bash
#
# generate_project.sh
# 生成 Xcode 工程（.xcodeproj）并准备图标资源。
# 依赖：XcodeGen（免费开源工具，非付费 SDK）。安装：brew install xcodegen
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# 1. 生成 App 图标（若缺失）
bash Scripts/generate_icon.sh

# 2. 用 XcodeGen 生成 .xcodeproj
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "✗ 未安装 xcodegen。请执行:  brew install xcodegen" >&2
  exit 1
fi

echo "→ 生成 Xcode 工程…"
xcodegen generate

echo "✅ 工程已生成: $ROOT/FrameScoop.xcodeproj"
echo "   可用 Xcode 打开，或执行: bash Scripts/build.sh"
