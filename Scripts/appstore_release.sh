#!/bin/bash
#
# appstore_release.sh
# Mac App Store 发布：Archive（Apple Distribution 证书 + App Store 描述文件）→
# 导出 App Store 包（.pkg）→ 提示用 Transporter 上传到 App Store Connect。
#
# 前置条件：
#   1. Keychain 已安装 “Apple Distribution” 证书（Mac App Store 类型）。
#   2. 已安装 com.framescoop.app 的 App Store 描述文件
#      （~/Library/MobileDevice/Provisioning Profiles/）。
#   3. App Store Connect 已存在对应 bundle id 的应用记录（上传前建好即可）。
#
# 用法:
#   bash Scripts/appstore_release.sh
#   产物: build/appstore/FrameScoop.pkg
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="FrameScoop"
BUNDLE_ID="com.framescoop.app"
TEAM_ID="${TEAM_ID:-VZ272K534R}"
DERIVED="$ROOT/build/DerivedData"
ARCHIVE="$ROOT/build/$APP_NAME.xcarchive"
EXPORT_DIR="$ROOT/build/appstore"
PLIST="$ROOT/build/export_appstore.plist"

cd "$ROOT"

# 0. 定位未吊销的 Mac App Store 分发证书（钥匙串显示为 "Apple Distribution" 或
#    经典命名 "3rd Party Mac Developer Application"，两者皆匹配）
DIST_HASH="$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -E 'Apple Distribution|3rd Party Mac Developer Application' | head -1 | grep -oE '[0-9A-F]{40}')"
if [ -z "$DIST_HASH" ]; then
  echo "✗ 找不到 Apple Distribution 证书。" >&2
  echo "  请先在 https://developer.apple.com/account/resources/certificates 创建（类型选 Mac App Store 的 Distribution）并安装。" >&2
  exit 1
fi
echo "-> Apple Distribution 证书: $DIST_HASH"

# 1. 定位本 bundle id 的 App Store 描述文件
PROFILE_PATH=""
for f in "$HOME"/Library/MobileDevice/Provisioning\ Profiles/*.mobileprovision; do
  [ -e "$f" ] || continue
  if security cms -D -i "$f" 2>/dev/null | grep -q "$BUNDLE_ID"; then
    PROFILE_PATH="$f"
    break
  fi
done
if [ -z "$PROFILE_PATH" ]; then
  echo "✗ 找不到 $BUNDLE_ID 的 App Store 描述文件。" >&2
  echo "  请先在 https://developer.apple.com/account/resources/profiles 创建（类型 Mac App Store）并安装。" >&2
  exit 1
fi
PROFILE_UUID="$(security cms -D -i "$PROFILE_PATH" | plutil -extract UUID raw -)"
echo "-> App Store 描述文件: $PROFILE_UUID"

# 2. Archive（用 Distribution 证书 + 描述文件手动签名，命令行设置覆盖工程配置）
echo "========================================"
echo " 1) Archive (Apple Distribution 签名)"
echo "========================================"
xcodebuild archive \
  -project "$ROOT/$APP_NAME.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Release \
  -archivePath "$ARCHIVE" \
  -derivedDataPath "$DERIVED" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$DIST_HASH" \
  PROVISIONING_PROFILE_SPECIFIER="$PROFILE_UUID"

# 3. 打包 .pkg：productbuild 直接包装归档里已签名的 .app，并用 Installer 证书签名安装包。
#    不用 xcodebuild -exportArchive（它要求 Xcode 账号会话在线，会话过期会导致身份选择错乱）。
echo "========================================"
echo " 2) 打包并签名 .pkg (productbuild)"
echo "========================================"
INSTALLER_HASH="$(security find-identity -v 2>/dev/null \
  | grep -E '3rd Party Mac Developer Installer' | head -1 | grep -oE '[0-9A-F]{40}')"
if [ -z "$INSTALLER_HASH" ]; then
  echo "✗ 找不到 Mac Installer Distribution 证书。" >&2
  exit 1
fi
APP_IN_ARCHIVE="$ARCHIVE/Products/Applications/$APP_NAME.app"
rm -rf "$EXPORT_DIR"
mkdir -p "$EXPORT_DIR"
productbuild --component "$APP_IN_ARCHIVE" /Applications \
  --sign "$INSTALLER_HASH" \
  "$EXPORT_DIR/$APP_NAME.pkg"

echo ""
echo "✅ App Store 包已生成"
echo "   路径: $EXPORT_DIR/$APP_NAME.pkg"
echo ""
echo "下一步：用 Transporter 上传（App Store 搜索下载 Transporter，拖入 .pkg）"
echo "上传后在 App Store Connect 选择该构建、填完元数据、提交审核。"
