#!/bin/bash
#
# notarize.sh
# 对 FrameScoop.app 进行签名、公证、装订票据，并清除 Gatekeeper 隔离。
#
# 前置条件（需 Apple 开发者账号）：
#   1. 拥有 “Developer ID Application” 签名证书（Keychain 中已安装）。
#   2. 创建 App 专用密码 或 App Store Connect API Key 用于 notarytool。
#
# 环境变量（按需设置，也可在脚本内填）：
#   SIGN_IDENTITY      签名身份，默认 "Developer ID Application: Your Name (TEAMID)"
#   NOTARY_PROFILE     notarytool 凭证名（需先通过 `xcrun notarytool store-credentials` 创建）
#                      或使用 APPLE_ID / APP_PASSWORD / TEAM_ID 组合
#
# 用法:
#   bash Scripts/notarize.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="FrameScoop"
APP_PATH="$ROOT/build/DerivedData/Build/Products/Release/$APP_NAME.app"

# ====== 配置区（请按实际填写） ======
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Your Name (TEAMID)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-frameScoop-notary}"
# 也可直接用账号密码（二选一）：
# APPLE_ID="you@example.com"
# APP_PASSWORD="xxxx-xxxx-xxxx-xxxx"
# TEAM_ID="XXXXXXXXXX"
ENTITLEMENTS="$ROOT/FrameScoop/FrameScoop.entitlements"
# ====================================

cd "$ROOT"

# 0. 先确保有 Release 构建产物
if [ ! -d "$APP_PATH" ]; then
  echo "-> 未找到 Release 产物，先构建…"
  CONFIG=Release bash Scripts/build.sh
fi

if [ ! -d "$APP_PATH" ]; then
  echo "✗ 构建产物不存在: $APP_PATH" >&2
  exit 1
fi

echo "========================================"
echo " 1) 代码签名 (Hardened Runtime + Entitlements)"
echo "========================================"
# 递归签名内嵌 Helper/框架（本工程暂无），随后签名主 App
codesign --force --deep \
  --options runtime \
  --entitlements "$ENTITLEMENTS" \
  --sign "$SIGN_IDENTITY" \
  "$APP_PATH"

# 校验签名
codesign --verify --strict --verbose=2 "$APP_PATH"

echo "========================================"
echo " 2) 打包 zip 并提交公证"
echo "========================================"
ZIP_PATH="$ROOT/build/$APP_NAME.zip"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

# 提交方式二选一：优先使用已存储的 notarytool 凭证
if [ -n "${APPLE_ID:-}" ] && [ -n "${APP_PASSWORD:-}" ] && [ -n "${TEAM_ID:-}" ]; then
  xcrun notarytool submit "$ZIP_PATH" \
    --apple-id "$APPLE_ID" \
    --password "$APP_PASSWORD" \
    --team-id "$TEAM_ID" \
    --wait
else
  xcrun notarytool submit "$ZIP_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
fi

echo "========================================"
echo " 3) 装订公证票据 (Staple)"
echo "========================================"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

echo "========================================"
echo " 4) 清除 Gatekeeper 隔离属性"
echo "========================================"
xattr -cr "$APP_PATH"

echo ""
echo "✅ 签名、公证、装订、去隔离全部完成"
echo "   产物: $APP_PATH"
echo "   分发方式: 直接分发 .app，或将 build/$APP_NAME.zip 发给用户"
