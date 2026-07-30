#!/bin/bash
#
# package_dmg.sh
# 打包 Release 版本为可拖拽安装的 .dmg（含 Applications 快捷方式）。
#
# 用法:
#   bash Scripts/package_dmg.sh
#   VOLNAME=FrameScoop bash Scripts/package_dmg.sh
#
# 产物: build/FrameScoop.dmg
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="FrameScoop"
CONFIG="${CONFIG:-Release}"
DERIVED="$ROOT/build/DerivedData"
APP_PATH="$DERIVED/Build/Products/$CONFIG/$APP_NAME.app"
BUILD_DIR="$ROOT/build"
STAGING="$BUILD_DIR/dmg-staging"
VOLNAME="${VOLNAME:-$APP_NAME}"
DMG_PATH="$BUILD_DIR/$APP_NAME.dmg"
RW_DMG="$BUILD_DIR/$APP_NAME-rw.dmg"

cd "$ROOT"

# 1. 确保 Release 产物存在
if [ ! -d "$APP_PATH" ]; then
  echo "-> 未找到 Release 产物，先构建…"
  CONFIG=Release bash Scripts/build.sh
fi
if [ ! -d "$APP_PATH" ]; then
  echo "✗ 构建产物不存在: $APP_PATH" >&2
  exit 1
fi

# 2. 准备临时目录：app + Applications 快捷方式
echo "-> 准备 DMG 内容…"
rm -rf "$STAGING" "$RW_DMG" "$DMG_PATH"
mkdir -p "$STAGING"
ditto "$APP_PATH" "$STAGING/$APP_NAME.app"          # ditto 保留 bundle 权限/资源
ln -s /Applications "$STAGING/Applications"
xattr -cr "$STAGING/$APP_NAME.app" 2>/dev/null || true   # 清除隔离属性

# 3. 创建可读写 DMG
echo "-> 创建 DMG…"
hdiutil create -srcfolder "$STAGING" -volname "$VOLNAME" -fs HFS+ -ov "$RW_DMG" >/dev/null

# 4. 设置 Finder 布局（拖拽安装样式；最佳努力，失败不影响出包）
echo "-> 设置拖拽安装布局…"
MOUNT_DIR="$(mktemp -d)"
hdiutil attach "$RW_DMG" -nobrowse -mountpoint "$MOUNT_DIR" >/dev/null || true
osascript <<APPLESCRIPT 2>/dev/null || echo "  (布局脚本跳过：Finder 未就绪，将使用默认布局)"
tell application "Finder"
    set totalWait to 0
    repeat while (not (exists disk "$VOLNAME")) and totalWait < 10
        delay 0.5
        set totalWait to totalWait + 0.5
    end repeat
    if not (exists disk "$VOLNAME") then return
    tell disk "$VOLNAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 760, 440}
        set view options to icon view
        set arrangement of view options to not arranged
        set icon size of view options to 96
        set position of item "$APP_NAME" to {140, 160}
        set position of item "Applications" to {480, 160}
        close
    end tell
end tell
APPLESCRIPT
# 等待 .DSStore 落盘
sleep 1
hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || hdiutil detach force "$MOUNT_DIR" >/dev/null 2>&1 || true

# 5. 转换为压缩只读（UDZO）
echo "-> 压缩为只读 DMG…"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" >/dev/null
rm -f "$RW_DMG"
rm -rf "$STAGING"

# 6. 校验
echo "-> 校验 DMG…"
hdiutil verify "$DMG_PATH" >/dev/null

echo ""
echo "✅ DMG 生成完成"
echo "   路径: $DMG_PATH"
echo "   大小: $(du -h "$DMG_PATH" | cut -f1)"
echo "   内容: $APP_NAME.app + Applications（拖拽到应用程序文件夹安装）"
