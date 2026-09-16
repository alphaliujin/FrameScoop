#!/bin/bash
#
# notarize.sh
# 用 Developer ID 证书签名并打包 DMG，对 app 和 DMG 分别提交公证、装订票据。
#
# 为什么公证两次（2026-09-16 补）：
#   「装订」(staple) 是把公证票据离线塞进产物，而 stapler 只能给**已被公证过**的
#   产物装订。票据写在 app 的 Contents/CodeResources —— 位于 _CodeSignature
#   封条之外，不改变 cdhash，所以「先给 app 装订、再把 app 打进 DMG」完全合法。
#   反过来，若只公证 DMG 而不单独公证 app，app 上就没有票据，用户离线首次启动
#   会被 Gatekeeper 拒绝（在线用户会回查 Apple，无感）。所以顺序必须是：
#
#     app 单独公证 → 装订 app → 构建 DMG（内含已装订的 app）
#                  → 签名 DMG → 公证 DMG → 装订 DMG
#
#   代价是每次发布两个公证提交；第二次因为 cdhash 已被 Apple 见过，通常很快。
#   app 的公证与装订夹在 package_dmg.sh 的 stage / finish 两段之间完成。
#
# 前置条件（需付费 Apple 开发者账号）：
#   1. Keychain 中已安装 “Developer ID Application” 证书
#      （开发者后台创建：Developer ID Application 类型，上传 CSR 后下载 .cer 双击安装）。
#   2. 已配置 notarytool 凭证（App Store Connect API Key 方式）：
#      App Store Connect → 用户与访问 → 集成 → Team Keys → 创建密钥（Developer 角色），
#      下载 .p8 并记下 Key ID 与 Issuer ID，然后执行一次：
#        xcrun notarytool store-credentials "$NOTARY_PROFILE" \
#          --issuer "$ISSUER_ID" --key-id "$KEY_ID" --key "/path/to/AuthKey_XXXX.p8"
#      注意：store-credentials / submit / staple 在 Claude 沙盒 Bash 里会读不到钥匙串
#      （报 No Keychain password item found for profile），需 dangerouslyDisableSandbox
#      或在真实终端里跑。
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
# 必须与 package_dmg.sh 里的 STAGING 保持一致
STAGING="$ROOT/build/dmg-staging"
APP_ZIP="$ROOT/build/$APP_NAME-app.zip"
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
echo " 1/6) Developer ID 签名 + 准备 staging"
echo "========================================"
PHASE=stage RELEASE_SIGN_IDENTITY="$DEVID_HASH" bash Scripts/package_dmg.sh

echo "========================================"
echo " 2/6) 提交公证 (app)"
echo "========================================"
# app 必须打成 zip 提交：notarytool 只接受 .zip / .pkg / .dmg，不接受裸 .app
rm -f "$APP_ZIP"
ditto -c -k --keepParent "$STAGING/$APP_NAME.app" "$APP_ZIP"
xcrun notarytool submit "$APP_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "========================================"
echo " 3/6) 装订 app 票据"
echo "========================================"
# stapler 在 app 没被公证过时会直接失败 —— 这里是「上一步真的成功了」的硬校验
xcrun stapler staple "$STAGING/$APP_NAME.app"
xcrun stapler validate "$STAGING/$APP_NAME.app"

echo "========================================"
echo " 4/6) 构建 DMG（内含已装订的 app）+ 签名 DMG"
echo "========================================"
PHASE=finish RELEASE_SIGN_IDENTITY="$DEVID_HASH" bash Scripts/package_dmg.sh

echo "========================================"
echo " 5/6) 提交公证 (DMG)"
echo "========================================"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

echo "========================================"
echo " 6/6) 装订 DMG 票据 + 清隔离属性"
echo "========================================"
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
xattr -cr "$DMG_PATH" 2>/dev/null || true
rm -f "$APP_ZIP"

echo ""
echo "========================================"
echo " 终检"
echo "========================================"
# DMG 自身签了名 + 公证 + 装订后，这条才会 accepted / source=Notarized Developer ID
spctl -a -vvv -t open --context context:primary-signature "$DMG_PATH" \
  || echo "⚠️  DMG 未被 Gatekeeper 接受（见上方输出）—— 对外分发前请先排查"

echo ""
echo "✅ app + DMG 双份公证、签名、装订全部完成"
echo "   产物: $DMG_PATH"
echo "   校验: xcrun stapler validate \"$DMG_PATH\""
