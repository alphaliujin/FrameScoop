#!/bin/bash
#
# generate_icon.sh
# 生成 App 图标资源。
#
# 图标来源（按优先级）：
#   1. 项目根目录的 FC.png（用户提供的图标，存在则使用）
#   2. 否则用系统 Core Graphics 绘制占位图标
#
# 产物：FrameScoop/Assets.xcassets/AppIcon.appiconset/（各尺寸 PNG + Contents.json）
#
# 为什么用资源目录（2026-09-26 实测结论）：
#   App Store 的**可见界面**（ASC 构建列表、商店搜索结果）只有资源目录 AppIcon
#   才渲染得出图标；只有手搓 .icns 时这些位置是空白占位图。实测依据：
#   1.0.10 及其之前的构建（无资源目录）在 ASC 列表全是空白，
#   而加了资源目录的 1.0.11 build 3 是列表里唯一有图标的。
#
# 同时产出 FrameScoop/Resources/AppIcon.icns（完整 11 块，含 1024）。
# 该 .icns **不参与资源拷贝**（见 project.yml 的 excludes），而是由 project.yml 里
# 的 postBuildScript 在 actool 之后、代码签名之前，覆写掉 actool 生成的那份截断版本。
#
# 为什么需要这一步：
#   actool 除了把 AppIcon 编进 Assets.car，还会在 bundle 里生成一份
#   **截断的** AppIcon.icns（只有 ic04/ic07/ic11/ic13 四个块，最大 256px），
#   并把 CFBundleIconFile 改指向它。Apple 提取商店页美术（iconAssetToken）
#   读的就是这份 .icns，于是美术从 1024 掉到 256。
#   试过另两条路都失败：① 给 appiconset 改名 → actool 仍覆写 CFBundleIconFile；
#   ② 不设 ASSETCATALOG_COMPILER_APPICON_NAME → 条目被整体排除出 Assets.car，
#   图标又不显示了。即「图标可见」与「美术 1024」被 actool 绑成一体，无法用配置分开，
#   只能在其后覆写文件。
#
# 用法: bash Scripts/generate_icon.sh
#   换图标：替换 FC.png 后删掉 AppIcon.appiconset 再跑本脚本。
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SET_DIR="$ROOT/FrameScoop/Assets.xcassets/AppIcon.appiconset"
ICNS_PATH="$ROOT/FrameScoop/Resources/AppIcon.icns"
SOURCE_PNG="$ROOT/FC.png"          # 用户提供的图标源（可选）

if [ -f "$SET_DIR/icon_512x512@2x.png" ] && [ -f "$ICNS_PATH" ]; then
  echo "图标已存在，跳过生成: $SET_DIR"
  exit 0
fi

mkdir -p "$SET_DIR" "$(dirname "$ICNS_PATH")"
WORK="$(mktemp -d)"
PNG_1024="$WORK/icon_512x512@2x.png"   # 1024 像素，对应 512@2x 槽位
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"

# ---------- 1. 取得 1024×1024 主图 ----------
if [ -f "$SOURCE_PNG" ]; then
  echo "  ✓ 使用图标源: $SOURCE_PNG"
  # 缩放/裁剪到 1024×1024（正方形），避免 iconutil 因尺寸不符报错
  sips -z 1024 1024 "$SOURCE_PNG" --out "$PNG_1024" >/dev/null
else
  echo "  ✓ 未找到 FC.png，使用 Core Graphics 绘制占位图标"
  OUT_PATH="$PNG_1024" swift - <<'SWIFT'
import Cocoa
import CoreGraphics
let size = 1024
let rect = CGRect(x: 0, y: 0, width: size, height: size)
let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8,
    bytesPerRow: 0, space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fputs("创建 CGContext 失败\n", stderr); exit(1) }
let path = CGPath(roundedRect: rect, cornerWidth: 224, cornerHeight: 224, transform: nil)
ctx.addPath(path); ctx.clip()
let colors = [
    CGColor(red: 0.243, green: 0.620, blue: 0.953, alpha: 1.0),
    CGColor(red: 0.380, green: 0.350, blue: 0.900, alpha: 1.0)
] as CFArray
guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) else { exit(1) }
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(size)),
                        end: CGPoint(x: CGFloat(size), y: 0), options: [])
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
ctx.addPath(CGPath(roundedRect: CGRect(x: 300, y: 300, width: 424, height: 424).insetBy(dx: 40, dy: 90),
                   cornerWidth: 40, cornerHeight: 40, transform: nil)); ctx.fillPath()
ctx.setBlendMode(.destinationOut)
ctx.addPath(CGPath(ellipseIn: CGRect(x: 412, y: 412, width: 200, height: 200), transform: nil)); ctx.fillPath()
ctx.setBlendMode(.normal)
ctx.setFillColor(CGColor(red: 0.243, green: 0.620, blue: 0.953, alpha: 0.6))
ctx.addPath(CGPath(ellipseIn: CGRect(x: 472, y: 472, width: 80, height: 80), transform: nil)); ctx.fillPath()
guard let cgImage = ctx.makeImage(),
      let pngData = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
else { exit(1) }
try! pngData.write(to: URL(fileURLWithPath: ProcessInfo.processInfo.environment["OUT_PATH"]!))
SWIFT
fi

echo "  ✓ 已准备 1024 主图"

# ---------- 2. 用 sips 生成各尺寸，直接写入 appiconset ----------
declare -a ENTRIES=(
  "16x16"        "16x16@2x"
  "32x32"        "32x32@2x"
  "128x128"      "128x128@2x"
  "256x256"      "256x256@2x"
  "512x512"      "512x512@2x"
)
i=0
while [ $i -lt ${#ENTRIES[@]} ]; do
  name1="${ENTRIES[$((i+0))]}"
  px1="${name1%x*}"
  sips -s format png -z "$px1" "$px1" "$PNG_1024" --out "$SET_DIR/icon_${name1}.png" >/dev/null
  name2="${ENTRIES[$((i+1))]}"
  base="${name2%@*}"
  px2=$(( ${base%x*} * 2 ))
  sips -s format png -z "$px2" "$px2" "$PNG_1024" --out "$SET_DIR/icon_${name2}.png" >/dev/null
  i=$((i+2))
done
echo "  ✓ 已生成 appiconset 各尺寸"

# ---------- 3. 同一套 PNG 另存为 iconset，打包成完整 .icns ----------
# 这份 .icns 不参与资源拷贝（见 project.yml 的 excludes），而是在构建的
# postBuildScript 阶段覆写 actool 生成的那份截断版本 —— 见下方"已知代价"。
cp "$SET_DIR"/icon_*.png "$ICONSET"/
iconutil -c icns "$ICONSET" -o "$ICNS_PATH"
echo "  ✓ 已生成完整 .icns: $(basename "$ICNS_PATH")"

# ---------- 4. 写 Contents.json ----------
{
  printf '{\n  "images" : [\n'
  i=0
  first=1
  while [ $i -lt ${#ENTRIES[@]} ]; do
    for name in "${ENTRIES[$((i+0))]}" "${ENTRIES[$((i+1))]}"; do
      base="${name%@*}"
      if [ "$name" = "$base" ]; then scale="1x"; else scale="2x"; fi
      [ $first -eq 0 ] && printf ',\n'
      printf '    { "filename" : "icon_%s.png", "idiom" : "mac", "scale" : "%s", "size" : "%s" }' \
        "$name" "$scale" "$base"
      first=0
    done
    i=$((i+2))
  done
  printf '\n  ],\n  "info" : { "author" : "xcode", "version" : 1 }\n}\n'
} > "$SET_DIR/Contents.json"

rm -rf "$WORK"

echo "✅ 图标生成完成: $SET_DIR"
