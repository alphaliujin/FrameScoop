# 品牌区文字化实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 右边栏底部品牌区从整幅图片改为「图形标记图片 + 三行文字」(FrameScoop 粗体 / 中文标语 / version),显示效果与原图一致。

**Architecture:** 裁剪脚本从原两变体裁出顶部 FC 图形标记生成 `BrandMark.imageset`(保留明暗双变体);`FilterSidebarView.brandLogo` 改为 VStack(标记图片 + 三行 Text),颜色用 `.primary` + 容器既有 `.opacity(0.55)` 适配明暗,version 行动态读 `CFBundleShortVersionString` 取前两位组件。

**Tech Stack:** SwiftUI;AppKit(裁剪脚本);sips 校验。无测试目标依赖(纯 UI 变更,验证=构建+目测)。

## Global Constraints

- 裁剪脚本为一次性工具,产物(PNG + Contents.json)入库,脚本不提交。
- 原图尺寸 480×281;元素占比:标记 ≈ 高 27%(y_top 约 20-95)、FrameScoop 字高 34px ≈ 12%、标语 ≈ 11%、version ≈ 4%。
- inspector 栏宽 min 200 / ideal 260 / max 360(ContentView.swift:28),内容宽 = 栏宽 - 24(padding 12×2);字号按 ideal 宽度 236 估算:图高 ≈ 138pt。
- 容器样式保持:`opacity(0.55)`、`padding(.vertical, 14)`、`padding(.horizontal, 12)`、`frame(maxWidth: .infinity)`、居中。
- 提交信息中文,按任务小步提交。

---

### Task 1: 生成 BrandMark.imageset 资产

**Files:**
- Create: `FrameScoop/Assets.xcassets/BrandMark.imageset/framescoop-mark-dark.png`
- Create: `FrameScoop/Assets.xcassets/BrandMark.imageset/framescoop-mark-light.png`
- Create: `FrameScoop/Assets.xcassets/BrandMark.imageset/Contents.json`

**Interfaces:**
- Produces: `Image("BrandMark")` 可用(暗/亮变体随外观自动切换)。Task 2 消费。

- [ ] **Step 1: 写裁剪脚本并运行**

```bash
mkdir -p FrameScoop/Assets.xcassets/BrandMark.imageset
cat > /tmp/crop_brand_mark.swift <<'EOF'
import AppKit

/// 从品牌图裁出顶部图形标记: 扫描 y < h*0.38 区域的 alpha 求边界, 四周留 6px 余量。
func cropMark(src: String, dst: String) {
    guard let img = NSImage(contentsOfFile: src), let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { fatalError("load \(src)") }
    let w = rep.pixelsWide, h = rep.pixelsHigh
    var minX = w, maxX = 0, minY = h, maxY = 0
    for y in 0..<Int(Double(h) * 0.38) {
        for x in 0..<w {
            if let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.05 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
    }
    let pad = 6
    minX = max(0, minX - pad); maxX = min(w - 1, maxX + pad)
    minY = max(0, minY - pad); maxY = min(h - 1, maxY + pad)
    guard let cg = rep.cgImage,
          let crop = cg.cropping(to: CGRect(x: minX, y: minY,
                                            width: maxX - minX + 1, height: maxY - minY + 1)) else {
        fatalError("crop \(src)")
    }
    let cr = NSBitmapImageRep(cgImage: crop)
    guard let data = cr.representation(using: .png, properties: [:]) else { fatalError("png \(src)") }
    try! data.write(to: URL(fileURLWithPath: dst))
    print("\(dst): \(crop.width)x\(crop.height)")
}

let root = "/Users/alpha/codespace/FrameScoop"
let imgset = "\(root)/FrameScoop/Assets.xcassets/BrandMark.imageset"
cropMark(src: "\(root)/FrameScoop/Assets.xcassets/BrandLogo.imageset/framescoop-brand-dark.png",
         dst: "\(imgset)/framescoop-mark-dark.png")
cropMark(src: "\(root)/FrameScoop/Assets.xcassets/BrandLogo.imageset/framescoop-brand-light.png",
         dst: "\(imgset)/framescoop-mark-light.png")
EOF
swift /tmp/crop_brand_mark.swift
```

- [ ] **Step 2: 校验产物**

```bash
sips -g pixelWidth -g pixelHeight FrameScoop/Assets.xcassets/BrandMark.imageset/framescoop-mark-dark.png FrameScoop/Assets.xcassets/BrandMark.imageset/framescoop-mark-light.png
```

Expected: 两个文件尺寸一致(约 150×85 量级,具体以输出为准),非 0 非满幅。

- [ ] **Step 3: Contents.json(结构与 BrandLogo 同构,换文件名)**

`FrameScoop/Assets.xcassets/BrandMark.imageset/Contents.json`:

```json
{
  "images" : [
    {
      "filename" : "framescoop-mark-light.png",
      "idiom" : "universal"
    },
    {
      "appearances" : [
        {
          "appearance" : "luminosity",
          "value" : "dark"
        }
      ],
      "filename" : "framescoop-mark-dark.png",
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

- [ ] **Step 4: Commit**

```bash
git add FrameScoop/Assets.xcassets/BrandMark.imageset
git commit -m "新增 BrandMark 图片资产（自品牌图裁剪的 FC 图形标记，明暗双变体）"
```

---

### Task 2: brandLogo 改为「标记图片 + 三行文字」并删除旧资产

**Files:**
- Modify: `FrameScoop/Views/FilterSidebarView.swift:128-136`(brandLogo 重写)
- Delete: `FrameScoop/Assets.xcassets/BrandLogo.imageset/`(全项目仅 brandLogo 一处引用,已确认)

**Interfaces:**
- Consumes: Task 1 的 `BrandMark` 资产。

- [ ] **Step 1: 重写 brandLogo**

`FilterSidebarView.swift` 中替换原 `brandLogo` 计算属性:

```swift
    /// 右边栏底部品牌区:图形标记(图片) + 三行文字,与原整幅品牌图视觉一致。
    /// 文字用 .primary 自动适配明暗(原图两变体即深灰/浅灰),配合整体 opacity(0.55)。
    private var brandLogo: some View {
        VStack(spacing: 0) {
            Image("BrandMark")
                .resizable()
                .scaledToFit()
                .frame(height: 38)          // ≈ 原图标记占比 27%
                .padding(.bottom, 6)
            Text("FrameScoop")
                .font(.system(size: 17, weight: .bold))   // ≈ 原图字高 12%
                .padding(.bottom, 3)
            Text("光影为诗，拾帧成集")
                .font(.system(size: 14))                  // ≈ 原图标语占比 11%
                .padding(.bottom, 2)
            Text("version \(Self.appVersion)")
                .font(.system(size: 9))                   // 原图约 4%,按可读性取 9
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.primary)
        .opacity(0.55)
        .padding(.vertical, 14)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
    }

    /// 短版本号(取 CFBundleShortVersionString 前两位组件: 1.0.0 -> "1.0")
    private static var appVersion: String {
        let full = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let parts = full.split(separator: ".").map(String.init)
        return parts.count >= 2 ? parts[0] + "." + parts[1] : full
    }
```

- [ ] **Step 2: 删除旧资产**

```bash
rm -rf FrameScoop/Assets.xcassets/BrandLogo.imageset
```

- [ ] **Step 3: 构建**

```bash
CONFIG=Debug bash Scripts/build.sh
```

Expected: 构建成功(旧资产无引用残留,否则 xcodebuild 报 asset 错误)。

- [ ] **Step 4: 运行目测(全部通过才算完成)**

```bash
open "build/DerivedData/Build/Products/Debug/FrameScoop.app"
```

- 右侧栏底部:FC 图形标记 + FrameScoop 粗体 + 中文标语 + version 1.0,整体半透明,水平居中,宽度自适应。
- 浅色模式:文字为深灰;深色模式:文字为浅灰、标记自动换浅色变体。
- 与改动前品牌区整体高度、透明感接近(元素齐、比例协调即可;像素级差异属预期)。
- 若字号/间距明显不协调,微调 Step 1 中的 `frame(height:)`、`font(size:)`、`padding(.bottom:)` 数值后重新构建目测。

- [ ] **Step 5: Commit**

```bash
git add FrameScoop/Views/FilterSidebarView.swift FrameScoop/Assets.xcassets
git commit -m "品牌区文字化：图形标记图片 + FrameScoop/标语/version 三行文字，明暗自动适配"
```

---

## Self-Review 记录

- Spec 覆盖:BrandMark 双变体资产(Task 1)、VStack 四层与尺寸比例(Task 2)、primary+opacity 配色(Task 2)、version 前两位动态(Task 2)、删除 BrandLogo(Task 2 Step 2)、构建+深浅色目测验证(Task 2 Step 3/4)。
- 占位符扫描:无 TBD;脚本路径为绝对路径,与仓库实际位置一致。
- 已知偏差:version 字号由原图 4%(≈6pt)调整为 9pt(可读性),spec 已列为允许微调项。
