#!/bin/bash
#
# notarize.sh
# 用 Developer ID 证书签名并打包 DMG，对 DMG 提交公证、装订票据。
#
# 前置条件（需付费 Apple 开发者账号）：
#   1. Keychain 中已安装 “Developer ID Application” 证书
#      （开发者后台创建：Developer ID Application 类型，上传 CSR 后下载 .cer 双击安装）。
#   2. 已配置 notarytool 凭证（App Store Connect API Key 方式）：
#      App Store Connect → 用户与访问 → 集成 → Team Keys → 创建密钥（Developer 角色），
#      下载 .p8 并记下 Key ID 与 Issuer ID，然后执行一次：
#        xcrun notarytool store-credentials "$NOTARY_PROFILE" \
#          --issuer "$ISSUER_ID" --key-id "$KEY_ID" --key "/path/to/AuthKey_XXXX.p8"
#
# 环境变量（按需覆盖）：
#   NOTARY_PROFILE     notarytool 凭证名，默认 frameScoop-notary
#
# 用法:
#   bash Scripts/notarize.sh
#   产物: build/FrameScoop.dmg（已公证 + 装订票据，可直接对外分发）
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="FrameScoop"
DMG_PATH="$ROOT/build/$APP_NAME.dmg"
NOTARY_PROFILE="${NOTARY_PROFILE:-frameScoop-notary}"

cd "$ROOT"

# 0. 定位未吊销的 Developer ID Application 证书（按 SHA-1 传给 package_dmg.sh 重签）
DEVID_HASH="$(security find-identity -v -p codesigning 2>/dev/null \
  | grep 'Developer ID Application' | head -1 | grep -oE '[0-9A-F]{40}')"
if [ -z "$DEVID_HASH" ]; then
  echo "✗ 找不到 Developer ID Application 证书。" >&2
  echo "  请先在 https://developer.apple.com/account/resources/certificates 创建并安装。" >&2
  exit 1
fi
echo "-> Developer ID 证书: $DEVID_HASH"

echo "========================================"
echo " 1) Developer ID 签名 + 打包 DMG"
echo "========================================"
# package_dmg.sh 内部以 RELEASE_SIGN_IDENTITY 重签（注入 Team ID + RFC3161 时间戳）
RELEASE_SIGN_IDENTITY="$DEVID_HASH" bash Scripts/package_dmg.sh

echo "========================================"
echo " 2) 提交公证 (DMG)"
echo "========================================"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

echo "========================================"
echo " 3) 装订公证票据 (Staple DMG)"
echo "========================================"
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

echo "========================================"
echo " 4) 清除 Gatekeeper 隔离属性"
echo "========================================"
xattr -cr "$DMG_PATH" 2>/dev/null || true

echo ""
echo "✅ Developer ID 签名、DMG 打包、公证、装订全部完成"
echo "   产物: $DMG_PATH"
echo "   校验: xcrun stapler validate \"$DMG_PATH\""
