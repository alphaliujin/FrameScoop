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
# 为什么是资源目录而不是手搓 .icns：
#   图标唯一来源应是 asset catalog。actool 会把它编进 Assets.car（CFBundleIconName
#   读取），并**同时**在 bundle 里生成 AppIcon.icns（CFBundleIconFile 读取）——
#   两条路径同源，不会出现"两份图标彼此覆盖"的非确定性构建。
#   此前手搓 Resources/AppIcon.icns 的做法会在加了 appiconset 之后与 actool 的产物
#   争抢同一个输出路径，产出的字节随「干净构建 / 增量构建」而变。
#   实测 actool 的重编码是**像素无损**的（512@2x 逐字节比对 0 差异）。
#
# 用法: bash Scripts/generate_icon.sh
#   换图标：替换 FC.png 后删掉 AppIcon.appiconset 再跑本脚本。
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SET_DIR="$ROOT/FrameScoop/Assets.xcassets/AppIcon.appiconset"
SOURCE_PNG="$ROOT/FC.png"          # 用户提供的图标源（可选）

if [ -f "$SET_DIR/icon_512x512@2x.png" ]; then
  echo "图标已存在，跳过生成: $SET_DIR"
  exit 0
fi

mkdir -p "$SET_DIR"
WORK="$(mktemp -d)"
PNG_1024="$WORK/icon_512x512@2x.png"   # 1024 像素，对应 512@2x 槽位

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

# ---------- 3. 写 Contents.json ----------
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
