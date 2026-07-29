#!/bin/bash
#
# generate_icon.sh
# 使用系统 Core Graphics 生成 1024×1024 占位 App 图标，并用 iconutil 打包为 .icns。
# 无需任何第三方库。纯原生：AppKit/CoreGraphics 绘制 + sips 缩放 + iconutil 打包。
#
# 产物：
#   FrameScoop/Resources/AppIcon.icns   （由 CFBundleIconFile 引用，跨 SDK 稳定）
#
# 用法: bash Scripts/generate_icon.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RES_DIR="$ROOT/FrameScoop/Resources"
mkdir -p "$RES_DIR"
ICNS_PATH="$RES_DIR/AppIcon.icns"

if [ -f "$ICNS_PATH" ]; then
  echo "图标已存在，跳过生成: $ICNS_PATH"
  exit 0
fi

WORK="$(mktemp -d)"
PNG_1024="$WORK/icon_512x512@2x.png"   # 1024 像素，对应 512@2x 槽位
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"

# ---------- 1. Core Graphics 绘制 1024×1024 主图 ----------
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

// 圆角裁剪
let path = CGPath(roundedRect: rect, cornerWidth: 224, cornerHeight: 224, transform: nil)
ctx.addPath(path); ctx.clip()

// 渐变填充
let colors = [
    CGColor(red: 0.243, green: 0.620, blue: 0.953, alpha: 1.0),
    CGColor(red: 0.380, green: 0.350, blue: 0.900, alpha: 1.0)
] as CFArray
guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) else { exit(1) }
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(size)),
                        end: CGPoint(x: CGFloat(size), y: 0), options: [])

// 简化相机图形（白色）
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
let body = CGPath(roundedRect: CGRect(x: 340, y: 340, width: 344, height: 344).insetBy(dx: 40, dy: 90),
                  cornerWidth: 40, cornerHeight: 40, transform: nil)
ctx.addPath(body); ctx.fillPath()
let bump = CGPath(roundedRect: CGRect(x: 454, y: 594, width: 116, height: 70),
                  cornerWidth: 12, cornerHeight: 12, transform: nil)
ctx.addPath(bump); ctx.fillPath()

// 镜头挖空
ctx.setBlendMode(.destinationOut)
ctx.addPath(CGPath(ellipseIn: CGRect(x: 412, y: 412, width: 200, height: 200), transform: nil))
ctx.fillPath()
ctx.setBlendMode(.normal)
ctx.setFillColor(CGColor(red: 0.243, green: 0.620, blue: 0.953, alpha: 0.6))
ctx.addPath(CGPath(ellipseIn: CGRect(x: 472, y: 472, width: 80, height: 80), transform: nil))
ctx.fillPath()

guard let cgImage = ctx.makeImage(),
      let pngData = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
else { exit(1) }
try! pngData.write(to: URL(fileURLWithPath: ProcessInfo.processInfo.environment["OUT_PATH"]!))
SWIFT

echo "  ✓ 已绘制 1024 主图"

# ---------- 2. 用 sips 生成各尺寸，组装 iconset ----------
SIZES=(16 32 64 128 256 512 1024)
# iconset 需要的成对文件名
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
  # 1x 尺寸
  px1="${name1%x*}"
  sips -z "$px1" "$px1" "$PNG_1024" --out "$ICONSET/icon_${name1}.png" >/dev/null
  # 2x 尺寸（@2x 文件名，像素 = 2 倍）
  name2="${ENTRIES[$((i+1))]}"
  base="${name2%@*}"
  px2=$(( ${base%x*} * 2 ))
  sips -z "$px2" "$px2" "$PNG_1024" --out "$ICONSET/icon_${name2}.png" >/dev/null
  i=$((i+2))
done

echo "  ✓ 已生成 iconset 各尺寸"

# ---------- 3. iconutil 打包为 icns ----------
iconutil -c icns "$ICONSET" -o "$ICNS_PATH"
rm -rf "$WORK"

echo "✅ 图标生成完成: $ICNS_PATH"
