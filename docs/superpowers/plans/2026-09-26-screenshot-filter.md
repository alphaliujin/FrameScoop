# 截屏筛选 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在右侧「智能筛选」边栏增加三态截屏筛选（全部 / 只看截屏 / 隐藏截屏），支持清理与选片两个方向。

**Architecture:** 判定截屏用两条独立判据取或——文件头 `EXIF.UserComment == "Screenshot"`（macOS 系统截屏写死的标记，实测零误报、穿透格式转换）与文件名前缀（覆盖第三方工具）；照片库来源改用系统权威字段 `PHAsset.mediaSubtypes`。判定结果存进视图模型的 `Set<String>`（与既有 `blurryPhotoIDs` 同构），在 `rebuildDisplayedPhotos()` 末尾作为正交过滤追加。**不落盘、不做 mtime 缓存**——只读文件头 1.4ms/张，重算一遍比引入缓存失效逻辑更划算。

**Tech Stack:** Swift 5.9 / SwiftUI / ImageIO（`CGImageSourceCopyPropertiesAtIndex`）/ Photos.framework / XCTest / XcodeGen

**Spec:** `docs/superpowers/specs/2026-09-26-screenshot-filter-design.md`

## Global Constraints

- 部署目标 macOS 14.0，Swift 版本 5.9。
- **新增 `.swift` 文件后必须运行 `bash Scripts/generate_project.sh`**。`.xcodeproj/` 是 gitignore 的、由 `project.yml` 现场生成；不重新生成会编译过但链接报 "Cannot find type"。生成物不入库，无需提交。
- 测试命令固定为：
  `xcodebuild test -scheme FrameScoop -destination 'platform=macOS' 2>&1 | grep -E "Executed|TEST (SUCCEEDED|FAILED)"`
- 基线：既有 34 个测试全绿，任何一步都不得让它们回归。
- **测试计数实际值与本文各步骤的预期值有偏移**：Task 1 的评审修复轮新增了一个钉住测试
  （`企业微信截图`），故该类由 12 个变 13 个。以实际为准：**Task 1 后 47**（34 + 13）、
  **Task 2 后及最终均为 55**（34 + 21）。Task 1 自身步骤里写的 12/46 是计划时的原值，
  保留不改。Tasks 3/4 不新增测试，计数维持 55。
- 代码注释用中文，与仓库既有风格一致。
- 默认不写解释性注释；仅在「为什么」非显然处写（如层级陷阱、性能量级差异）。

---

## File Structure

| 文件 | 职责 | 动作 |
| --- | --- | --- |
| `FrameScoop/Models/ScreenshotFilter.swift` | 三态枚举 + 分段控件标签 | 新建 |
| `FrameScoop/Services/ScreenshotDetectionService.swift` | 文件名判据 + 文件头判据 | 新建 |
| `FrameScoopTests/ScreenshotDetectionTests.swift` | 两个判据的全部测试 | 新建 |
| `FrameScoop/Services/PhotosLibraryService.swift` | `loadAllPhotos()` 顺带返回截屏 id 集合 | 改 2 处 |
| `FrameScoop/ViewModels/PhotoLibraryViewModel.swift` | 状态、扫描任务、过滤分支、触发点 | 改 5 处 |
| `FrameScoop/Views/FilterSidebarView.swift` | 分段控件 + 计数 | 改 1 处 |
| `FrameScoop/Views/PhotoGridView.swift` | `GridCell` / `PhotoBadges` 加角标位 | 改 4 处 |
| `FrameScoop/Views/PhotoDetailView.swift` | `PhotoBadges` 第二个调用点补必填参数 | 改 1 处 |

判定服务与 UI 分离：`ScreenshotDetectionService` 是纯逻辑（可用 TDD 覆盖），VM 只负责调度与状态，视图只读状态。

---

### Task 1: 三态枚举 + 文件名判据

**Files:**
- Create: `FrameScoop/Models/ScreenshotFilter.swift`
- Create: `FrameScoop/Services/ScreenshotDetectionService.swift`
- Create: `FrameScoopTests/ScreenshotDetectionTests.swift`

**Interfaces:**
- Consumes: 无（首个任务）
- Produces:
  - `enum ScreenshotFilter: String, CaseIterable, Codable { case off, only, exclude }`，属性 `var label: String`
  - `ScreenshotDetectionService.matchesFilename(_ name: String) -> Bool`
  - `ScreenshotDetectionService.filenamePrefixes: [String]`

- [ ] **Step 1: 写失败测试**

创建 `FrameScoopTests/ScreenshotDetectionTests.swift`：

```swift
import XCTest
@testable import FrameScoop

final class ScreenshotDetectionTests: XCTestCase {

    // MARK: - 文件名判据

    func testChineseSystemScreenshotName() {
        XCTAssertTrue(ScreenshotDetectionService.matchesFilename("截屏2026-09-26 14.30.00.png"))
    }

    func testChineseSystemScreenshotNameWithMeridiem() {
        XCTAssertTrue(ScreenshotDetectionService.matchesFilename("截屏2026-09-26 下午2.30.00.png"))
    }

    func testEnglishSystemScreenshotName() {
        XCTAssertTrue(ScreenshotDetectionService.matchesFilename("Screenshot 2026-09-26 at 2.30.00 PM.png"))
    }

    func testLegacyEnglishScreenShotName() {
        XCTAssertTrue(ScreenshotDetectionService.matchesFilename("Screen Shot 2026-09-26 at 2.30.00 PM.png"))
    }

    func testWeChatScreenshotName() {
        XCTAssertTrue(ScreenshotDetectionService.matchesFilename("微信截图_20260926143000.png"))
    }

    func testQQScreenshotName() {
        XCTAssertTrue(ScreenshotDetectionService.matchesFilename("QQ截图20260926143000.png"))
    }

    func testSnipasteScreenshotName() {
        XCTAssertTrue(ScreenshotDetectionService.matchesFilename("Snipaste_2026-09-26_14-30-00.png"))
    }

    func testCleanShotScreenshotName() {
        XCTAssertTrue(ScreenshotDetectionService.matchesFilename("CleanShot 2026-09-26 at 14.30.00@2x.png"))
    }

    func testCameraFilenameIsNotScreenshot() {
        XCTAssertFalse(ScreenshotDetectionService.matchesFilename("2T9A3048.JPG"))
    }

    func testAppleOriginalFilenameIsNotScreenshot() {
        XCTAssertFalse(ScreenshotDetectionService.matchesFilename("IMG_1234.HEIC"))
    }

    /// 前缀匹配而非子串：句中出现的"截图"不算
    func testSubstringTrapIsNotScreenshot() {
        XCTAssertFalse(ScreenshotDetectionService.matchesFilename("我的截图旅行.jpg"))
    }

    /// 大小写不敏感
    func testFilenameMatchIsCaseInsensitive() {
        XCTAssertTrue(ScreenshotDetectionService.matchesFilename("SCREENSHOT 2026-09-26.png"))
    }
}
```

- [ ] **Step 2: 生成工程并运行测试确认失败**

```bash
bash Scripts/generate_project.sh
xcodebuild test -scheme FrameScoop -destination 'platform=macOS' -only-testing:FrameScoopTests/ScreenshotDetectionTests 2>&1 | grep -E "error:|Executed|TEST (SUCCEEDED|FAILED)"
```

预期：编译失败，报 `cannot find 'ScreenshotDetectionService' in scope`。

- [ ] **Step 3: 创建枚举**

创建 `FrameScoop/Models/ScreenshotFilter.swift`：

```swift
//
//  ScreenshotFilter.swift
//  FrameScoop
//
//  截屏筛选三态。三态天然互斥，避免既有 showsBlurFilter/showsBurstFilter
//  那套「两个 didSet 互相置 false」的互斥写法（该模式在三个筛选上已显冗余）。
//

import Foundation

enum ScreenshotFilter: String, CaseIterable, Codable {
    case off       // 不过滤
    case only      // 只看截屏（清理场景）
    case exclude   // 隐藏截屏（选片场景）

    var label: String {
        switch self {
        case .off:     return "全部"
        case .only:    return "只看截屏"
        case .exclude: return "隐藏截屏"
        }
    }
}
```

- [ ] **Step 4: 创建检测服务（仅文件名判据）**

创建 `FrameScoop/Services/ScreenshotDetectionService.swift`：

```swift
//
//  ScreenshotDetectionService.swift
//  FrameScoop
//
//  截屏判定：两条独立判据取或。
//  - 文件名前缀：零 I/O，覆盖不写标记的第三方工具（微信/QQ/Snipaste 等）。
//  - 文件头 EXIF UserComment：macOS 系统截屏写死的标记。
//  照片库来源由 PHAsset.mediaSubtypes 判定，不走本服务。
//

import Foundation

enum ScreenshotDetectionService {

    /// 文件名前缀特征。用前缀而非子串：子串会让「我的截图旅行.jpg」误命中。
    static let filenamePrefixes = [
        "截屏", "屏幕截图", "截图",
        "Screenshot", "Screen Shot",
        "Snipaste", "CleanShot", "Shottr",
    ]

    /// 文件名前缀判据（大小写不敏感，零 I/O，纯函数）
    static func matchesFilename(_ name: String) -> Bool {
        let lower = name.lowercased()
        return filenamePrefixes.contains { lower.hasPrefix($0.lowercased()) }
    }
}
```

- [ ] **Step 5: 运行测试确认通过**

```bash
bash Scripts/generate_project.sh
xcodebuild test -scheme FrameScoop -destination 'platform=macOS' -only-testing:FrameScoopTests/ScreenshotDetectionTests 2>&1 | grep -E "error:|Executed|TEST (SUCCEEDED|FAILED)"
```

预期：`Executed 12 tests, with 0 failures`，`** TEST SUCCEEDED **`。

- [ ] **Step 6: 确认既有测试不回归**

```bash
xcodebuild test -scheme FrameScoop -destination 'platform=macOS' 2>&1 | grep -E "Executed [0-9]+ tests|TEST (SUCCEEDED|FAILED)"
```

预期：`Executed 46 tests, with 0 failures`（34 既有 + 12 新增）。

- [ ] **Step 7: 提交**

```bash
git add FrameScoop/Models/ScreenshotFilter.swift FrameScoop/Services/ScreenshotDetectionService.swift FrameScoopTests/ScreenshotDetectionTests.swift
git commit -m "feat: 截屏筛选三态枚举与文件名判据"
```

---

### Task 2: 文件头 EXIF 判据

**Files:**
- Modify: `FrameScoop/Services/ScreenshotDetectionService.swift`
- Modify: `FrameScoopTests/ScreenshotDetectionTests.swift`

**Interfaces:**
- Consumes: Task 1 的 `ScreenshotDetectionService.matchesFilename(_:)`
- Produces:
  - `ScreenshotDetectionService.hasScreenshotMarker(at url: URL) -> Bool`
  - `ScreenshotDetectionService.isScreenshot(name: String, url: URL) -> Bool`

- [ ] **Step 1: 写失败测试**

在 `FrameScoopTests/ScreenshotDetectionTests.swift` 的类内追加。文件顶部 import 区改为：

```swift
import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import FrameScoop
```

追加的测试：

```swift
    // MARK: - 文件头判据

    /// 现场生成样本图。ImageIO 既能写也能读 EXIF UserComment（已实测往返），
    /// 因此不需要把二进制夹具入库。
    private func makePNG(named: String, userComment: String?) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(named)
        try? FileManager.default.removeItem(at: url)
        let ctx = CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        let props: CFDictionary? = userComment.map {
            [kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: $0]] as CFDictionary
        }
        CGImageDestinationAddImage(dest, ctx.makeImage()!, props)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    func testMarkerPresentIsScreenshot() {
        let url = makePNG(named: "fs-marker-yes.png", userComment: "Screenshot")
        XCTAssertTrue(ScreenshotDetectionService.hasScreenshotMarker(at: url))
    }

    func testMarkerAbsentIsNotScreenshot() {
        let url = makePNG(named: "fs-marker-no.png", userComment: nil)
        XCTAssertFalse(ScreenshotDetectionService.hasScreenshotMarker(at: url))
    }

    func testMarkerMatchIsCaseInsensitive() {
        let url = makePNG(named: "fs-marker-lower.png", userComment: "screenshot")
        XCTAssertTrue(ScreenshotDetectionService.hasScreenshotMarker(at: url))
    }

    /// 全等而非子串：多一个 s 不算
    func testMarkerNearMissIsNotScreenshot() {
        let url = makePNG(named: "fs-marker-plural.png", userComment: "Screenshots")
        XCTAssertFalse(ScreenshotDetectionService.hasScreenshotMarker(at: url))
    }

    func testMissingFileIsNotScreenshotAndDoesNotCrash() {
        let url = URL(fileURLWithPath: "/tmp/fs-does-not-exist-\(UUID().uuidString).png")
        XCTAssertFalse(ScreenshotDetectionService.hasScreenshotMarker(at: url))
    }

    // MARK: - 组合判定

    /// 文件名不匹配但文件头带标记 —— 用户把截屏改名后仍能识别
    func testRenamedScreenshotStillDetectedByMarker() {
        let url = makePNG(named: "DSC_0001.png", userComment: "Screenshot")
        XCTAssertTrue(ScreenshotDetectionService.isScreenshot(name: "DSC_0001.png", url: url))
    }

    /// 文件名命中即算，无需读文件头（第三方工具截图不带标记）
    func testFilenameMatchAloneIsEnough() {
        let url = makePNG(named: "微信截图_20260926143000.png", userComment: nil)
        XCTAssertTrue(ScreenshotDetectionService.isScreenshot(name: "微信截图_20260926143000.png", url: url))
    }

    /// 两者都不匹配 —— 相机原图
    func testRealPhotoIsNotScreenshot() {
        let url = makePNG(named: "2T9A3048.png", userComment: nil)
        XCTAssertFalse(ScreenshotDetectionService.isScreenshot(name: "2T9A3048.png", url: url))
    }
```

- [ ] **Step 2: 运行测试确认失败**

```bash
xcodebuild test -scheme FrameScoop -destination 'platform=macOS' -only-testing:FrameScoopTests/ScreenshotDetectionTests 2>&1 | grep -E "error:|Executed|TEST (SUCCEEDED|FAILED)"
```

预期：编译失败，报 `value of type 'ScreenshotDetectionService' has no member 'hasScreenshotMarker'`。

- [ ] **Step 3: 实现文件头判据**

修改 `FrameScoop/Services/ScreenshotDetectionService.swift`：`import Foundation` 下补 `import ImageIO`，并在 `matchesFilename` 之后追加：

```swift
    /// 文件头判据：EXIF UserComment 是否为 "Screenshot"。
    /// 只读元数据、不解码像素（实测 ~1.4 ms/张）；任何读取失败一律返回 false。
    /// 注意层级：Make/Model 在 TIFF 字典里，UserComment 在 EXIF 字典里，别读错。
    static func hasScreenshotMarker(at url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any],
              let comment = exif[kCGImagePropertyExifUserComment as String] as? String
        else { return false }
        return comment.compare("Screenshot", options: .caseInsensitive) == .orderedSame
    }

    /// 综合判定：文件名命中 或 文件头带标记
    static func isScreenshot(name: String, url: URL) -> Bool {
        matchesFilename(name) || hasScreenshotMarker(at: url)
    }
```

- [ ] **Step 4: 运行测试确认通过**

```bash
xcodebuild test -scheme FrameScoop -destination 'platform=macOS' -only-testing:FrameScoopTests/ScreenshotDetectionTests 2>&1 | grep -E "error:|Executed|TEST (SUCCEEDED|FAILED)"
```

预期：`Executed 21 tests, with 0 failures`，`** TEST SUCCEEDED **`。

- [ ] **Step 5: 提交**

```bash
git add FrameScoop/Services/ScreenshotDetectionService.swift FrameScoopTests/ScreenshotDetectionTests.swift
git commit -m "feat: 截屏文件头 EXIF 判据

macOS 系统截屏写入 EXIF UserComment=\"Screenshot\"，实测穿透格式转换、
不随系统语言本地化、387 张相机照片零误报。"
```

---

### Task 3: 扫描任务 + 视图模型状态 + 边栏三态控件

**Files:**
- Modify: `FrameScoop/Services/PhotosLibraryService.swift:65-75`
- Modify: `FrameScoop/ViewModels/PhotoLibraryViewModel.swift`（5 处）
- Modify: `FrameScoop/Views/FilterSidebarView.swift:23-30`

**Interfaces:**
- Consumes: `ScreenshotFilter`（Task 1）、`ScreenshotDetectionService.isScreenshot(name:url:)`（Task 2）
- Produces:
  - `PhotosLibraryService.loadAllPhotos() async -> (items: [PhotoItem], screenshotIDs: Set<String>)`（**签名变更**）
  - `PhotoLibraryViewModel.screenshotFilter: ScreenshotFilter`
  - `PhotoLibraryViewModel.screenshotPhotoIDs: Set<String>`（`private(set)`）
  - `PhotoLibraryViewModel.isScreenshotScanning: Bool`（`private(set)`）

- [ ] **Step 1: 改照片库服务的返回签名**

`FrameScoop/Services/PhotosLibraryService.swift`，把 `loadAllPhotos()` 整个替换：

```swift
    /// 枚举照片库全部图片资产，转为 PhotoItem（未排序，由上层排序）。
    /// 同一次枚举顺带收集截屏资产 id——mediaSubtypes 是系统权威字段，零额外成本。
    func loadAllPhotos() async -> (items: [PhotoItem], screenshotIDs: Set<String>) {
        guard status == .authorized else { return ([], []) }
        let result = PHAsset.fetchAssets(with: .image, options: nil)
        var items: [PhotoItem] = []
        var screenshotIDs: Set<String> = []
        items.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            let item = self.makeItem(from: asset)
            items.append(item)
            if asset.mediaSubtypes.contains(.photoScreenshot) {
                screenshotIDs.insert(item.id)   // 复用 item.id，保证与 PhotoItem 的 id 格式一致
            }
        }
        return (items, screenshotIDs)
    }
```

- [ ] **Step 2: 接入加载路径**

`FrameScoop/ViewModels/PhotoLibraryViewModel.swift:625`，把

```swift
            let items = await PhotosLibraryService.shared.loadAllPhotos()
```

改为

```swift
            let (items, screenshotIDs) = await PhotosLibraryService.shared.loadAllPhotos()
```

并在 `self.photos = items`（原 630 行）**之前**插入赋值——必须先于 `photos` 赋值，因为 `photos` 的 `didSet` 会触发扫描，而扫描入口会按当前列表剪枝：

```swift
            // 先于 photos 赋值：photos 的 didSet 触发扫描，扫描入口按当前列表剪枝
            self.screenshotPhotoIDs = screenshotIDs
            self.photos = items
```

- [ ] **Step 3: 加视图模型状态**

`FrameScoop/ViewModels/PhotoLibraryViewModel.swift`，在闭眼筛选状态块之后（`partialClosedEyePhotoIDs` 声明，原 228 行后）插入：

```swift
    /// 截屏筛选三态（全部/只看截屏/隐藏截屏）。
    /// 与既有三个筛选正交、可同时生效，无需互斥 didSet。
    @Published var screenshotFilter: ScreenshotFilter = .off {
        didSet { rebuildDisplayedPhotos() }
    }
    /// 截屏 id 集合（唯一真源；PhotoItem 不加字段，与 blurryPhotoIDs 同构）
    @Published private(set) var screenshotPhotoIDs: Set<String> = []
    /// 是否正在扫描文件夹（驱动边栏进度文案）
    @Published private(set) var isScreenshotScanning: Bool = false
```

- [ ] **Step 4: 加过滤分支**

`FrameScoop/ViewModels/PhotoLibraryViewModel.swift`，`rebuildDisplayedPhotos()` 内，把

```swift
        // 只显示选中
        if showsSelectedOnly {
            result = result.filter { selectedPhotoIDs.contains($0.id) }
        }
        displayedPhotos = result
```

改为

```swift
        // 只显示选中
        if showsSelectedOnly {
            result = result.filter { selectedPhotoIDs.contains($0.id) }
        }
        // 截屏筛选（三态）：与上面各筛选正交，可叠加
        switch screenshotFilter {
        case .off:     break
        case .only:    result = result.filter { screenshotPhotoIDs.contains($0.id) }
        case .exclude: result = result.filter { !screenshotPhotoIDs.contains($0.id) }
        }
        displayedPhotos = result
```

- [ ] **Step 5: 加扫描任务**

`FrameScoop/ViewModels/PhotoLibraryViewModel.swift`，在 `// MARK: - 图片数据导入` 之前插入新段落：

```swift
    // MARK: - 截屏扫描

    /// 扫描任务句柄：切文件夹时 cancel 旧任务
    private var screenshotScanTask: Task<Void, Never>?
    /// 扫描版本号：切文件夹递增，回调校验丢弃过期结果
    private var screenshotScanToken = 0

    /// 扫描截屏并填充 screenshotPhotoIDs。
    /// 与 precomputeAnalysis 的区别：只读文件头（~1.4ms/张）、不落盘、不做并发调度
    /// ——顺序扫 + 每 64 张回主线程合并即可（3000 张约 4 秒），
    /// 16 路并发换不回可感知收益，只带来调度复杂度。
    /// 照片库来源已在加载时赋值，此处只扫 .folder 项；但剪枝对两个来源都要做。
    private func scanScreenshots() {
        screenshotScanTask?.cancel()
        screenshotScanToken += 1
        let token = screenshotScanToken

        let photos = self.photos
        // 剪枝：切节点后残留旧 id 会让「只看截屏」滤出错项
        let liveIDs = Set(photos.map { $0.id })
        screenshotPhotoIDs = screenshotPhotoIDs.filter { liveIDs.contains($0) }

        let folders = photos.filter { $0.sourceKind == .folder }
        guard !folders.isEmpty else {
            isScreenshotScanning = false
            return
        }
        isScreenshotScanning = true

        screenshotScanTask = Task.detached(priority: .utility) { [weak self] in
            var batch: [String] = []
            for photo in folders {
                // 已取消（切了文件夹）：直接返回，状态由新一轮扫描接管
                if Task.isCancelled { return }
                guard let url = photo.url else { continue }
                if ScreenshotDetectionService.isScreenshot(name: photo.name, url: url) {
                    batch.append(photo.id)
                }
                if batch.count >= 64 {
                    let b = batch
                    batch = []
                    await MainActor.run { [weak self] in
                        guard let self, token == self.screenshotScanToken else { return }
                        self.screenshotPhotoIDs.formUnion(b)
                        self.rebuildDisplayedPhotos()
                    }
                }
            }
            let rest = batch
            await MainActor.run { [weak self] in
                guard let self, token == self.screenshotScanToken else { return }
                self.screenshotPhotoIDs.formUnion(rest)
                self.isScreenshotScanning = false
                self.rebuildDisplayedPhotos()
            }
        }
    }

```

- [ ] **Step 6: 挂触发点**

`FrameScoop/ViewModels/PhotoLibraryViewModel.swift`，`precomputeAnalysis()` 的第一行（原 1140 行 `// 入口即重置完成态…` 之前）插入扫描调用：

```swift
        // 截屏扫描只读文件头、比 dHash/Vision 便宜两个数量级，与本函数同点触发
        scanScreenshots()
        // 入口即重置完成态：空文件夹、切文件夹、重算都不得残留上一轮的完成标记
        showPrecomputeSummary = false
```

同文件 `photos` 的 `didSet` 内，mtime 变化分支（原 81-87 行）追加：

```swift
                if hasMtimeChanges(oldValue, photos) {
                    scanScreenshots()
                    if showsBurstFilter {
                        detectBurstsIfNeeded()
                    } else if showsBlurFilter || showsEyeClosedFilter {
                        detectBlurryIfNeeded()
                    }
                }
```

- [ ] **Step 7: 加边栏控件**

`FrameScoop/Views/FilterSidebarView.swift`，在「闭眼检测」Toggle（原 29 行）之后插入：

```swift
                    Picker("截屏", selection: $library.screenshotFilter) {
                        ForEach(ScreenshotFilter.allCases, id: \.self) { f in
                            Text(f.label).tag(f)
                        }
                    }
                    .pickerStyle(.segmented)
                    .help("按 EXIF 标记与文件名识别截屏；「只看」用于清理，「隐藏」用于选片")

                    Text(library.isScreenshotScanning
                         ? "正在识别截屏…已发现 \(library.screenshotPhotoIDs.count) 张"
                         : "共 \(library.screenshotPhotoIDs.count) 张截屏")
                        .font(.caption)
                        .foregroundStyle(.secondary)
```

- [ ] **Step 8: 构建并跑全部测试**

```bash
xcodebuild test -scheme FrameScoop -destination 'platform=macOS' 2>&1 | grep -E "error:|warning: .*never used|Executed [0-9]+ tests|TEST (SUCCEEDED|FAILED)"
```

预期：`Executed 55 tests, with 0 failures`（34 既有 + 21 新增），`** TEST SUCCEEDED **`，无编译错误。

- [ ] **Step 9: 运行时手测**

```bash
bash Scripts/run.sh
```

用一个同时含真实截屏与相机照片的文件夹验证：

1. 打开文件夹，边栏出现 `截屏` 分段控件与「正在识别截屏…已发现 N 张」，计数递增后稳定为「共 N 张截屏」。
2. 点「只看截屏」→ 网格只剩截屏；点「隐藏截屏」→ 截屏消失；点「全部」→ 恢复。
3. 把一张截屏改名成 `DSC_0001.png` 后重开该文件夹 → 仍被识别（文件头判据生效）。
4. 同开「只显示选中」→ 两条件取交集，不互相清空。
5. 切到「照片图库」节点 → 计数反映库内截屏数（`mediaSubtypes` 路径）。
6. 快照一个含截屏的文件夹后立刻切走 → 无崩溃、无残留计数。

- [ ] **Step 10: 提交**

```bash
git add FrameScoop/Services/PhotosLibraryService.swift FrameScoop/ViewModels/PhotoLibraryViewModel.swift FrameScoop/Views/FilterSidebarView.swift
git commit -m "feat: 截屏扫描与三态筛选（边栏控件）

文件夹来源后台顺序扫文件头，照片库来源复用媒体子类型。
不落盘：重算一遍约 4 秒/3000 张，比引入 mtime 缓存失效逻辑划算。"
```

---

### Task 4: 缩略图角标

**Files:**
- Modify: `FrameScoop/Views/PhotoGridView.swift`（4 处）

**Interfaces:**
- Consumes: Task 3 的 `screenshotFilter` 与 `screenshotPhotoIDs`
- Produces: 无（终态 UI）

- [ ] **Step 1: 加角标视图参数**

`FrameScoop/Views/PhotoGridView.swift`，`PhotoBadges` 结构体（原 350 行起）加一个属性：

```swift
struct PhotoBadges: View {
    let number: Int?
    let isRedBlurry: Bool
    let isYellowBlurry: Bool
    let isRedEye: Bool
    let isYellowEye: Bool
    let isScreenshot: Bool
```

`body` 里的首个 `if` 条件与 `HStack` 内容分别改为：

```swift
            if number != nil || isRedBlurry || isYellowBlurry || isRedEye || isYellowEye || isScreenshot {
```

```swift
                    if isScreenshot {
                        // 中性灰：截屏是「类别」不是「问题」，不与红/黄的严重程度语义混用
                        badge(symbol: "display", bg: .gray, fg: .white)
                    }
```

- [ ] **Step 2: 给 GridCell 加参数**

`FrameScoop/Views/PhotoGridView.swift`，`GridCell` 结构体加属性：

```swift
    let isScreenshot: Bool
```

`static func ==` 末尾追加一行：

```swift
        && lhs.isScreenshot == rhs.isScreenshot
```

`body` 内传给 `PhotoBadges` 的调用补一个参数：

```swift
                PhotoBadges(
                    number: badgeNumber,
                    isRedBlurry: isRedBlurry,
                    isYellowBlurry: isYellowBlurry,
                    isRedEye: isRedEye,
                    isYellowEye: isYellowEye,
                    isScreenshot: isScreenshot
                )
```

- [ ] **Step 3: 在 cell 工厂里传值**

`FrameScoop/Views/PhotoGridView.swift`，`cell(for:)` 内 `GridCell(...)` 构造参数里，`isYellowEye:` 那行之后补：

```swift
            // 不做筛选门控：三态下「只看」会让每张都带角标、「隐藏」又一张不剩，
            // 两种模式里角标都不提供信息；默认（全部）的混合视图才是它唯一有用的场景。
            isScreenshot: library.screenshotPhotoIDs.contains(photo.id),
```

- [ ] **Step 4: 修详情视图的调用点**

`FrameScoop/Views/PhotoDetailView.swift:101` 的 `PhotoBadges(...)` 是**第二个调用点**，`isScreenshot` 是必填参数，不改会编译失败。在 `isYellowEye:` 那行之后补：

```swift
                    isScreenshot: library.screenshotPhotoIDs.contains(photo.id)
```

（注意上一行 `isYellowEye:` 原本没有尾逗号，需补一个。）

- [ ] **Step 5: 构建并跑全部测试**

```bash
xcodebuild test -scheme FrameScoop -destination 'platform=macOS' 2>&1 | grep -E "error:|Executed [0-9]+ tests|TEST (SUCCEEDED|FAILED)"
```

预期：`Executed 55 tests, with 0 failures`（34 既有 + 21 新增），`** TEST SUCCEEDED **`。

- [ ] **Step 6: 运行时手测**

```bash
bash Scripts/run.sh
```

1. 打开含截屏的文件夹 → 截屏缩略图左上角**直接出现**灰色 `display` 图标（无需切筛选模式）。
2. 切到「只看截屏」→ 全部带角标（预期内冗余）；切「隐藏截屏」→ 截屏消失。
3. 与红/黄的人脸模糊、闭眼角标同时出现时视觉可区分（灰 vs 红/黄）。
4. 双击打开一张截屏 → 详情视图左上角同样有灰色角标。
5. 滚动网格 → 角标随 cell 复用正确刷新，无错位或残留。

- [ ] **Step 7: 提交**

```bash
git add FrameScoop/Views/PhotoGridView.swift FrameScoop/Views/PhotoDetailView.swift
git commit -m "feat: 截屏缩略图角标（灰色 display 图标）

不做筛选门控：三态筛选下门控会让角标在「只看」时全量冗余、
在「隐藏」时永不出现，只在默认混合视图里有信息量。"
```

---

## 验证（全部任务完成后）

- [ ] 全部测试绿：`xcodebuild test -scheme FrameScoop -destination 'platform=macOS' 2>&1 | grep -E "Executed [0-9]+ tests|TEST (SUCCEEDED|FAILED)"` → `Executed 55 tests`（34 既有 + 21 新增），`** TEST SUCCEEDED **`
- [ ] `bash Scripts/run.sh` 起 app，逐条走完 Task 3 Step 9 与 Task 4 Step 5 的手测清单
- [ ] 确认 spec 的「范围外」未被越界实现（无自动删除、无阈值调节、未改 `PhotoAnalysisStore`、未改 `PhotoItem`）
