# 图片框选(Marquee Selection)实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 网格中按住鼠标拖出方框,框内(含部分相交)图片被选中;Shift+拖=加选;单击不拖仍选单张。

**Architecture:** 布局行计算提为纯函数 `GridGeometry`(flowFrames/burstFrames),显示布局与框选命中共用同一份几何;`DragGesture` 挂在 ScrollView 上(坐标空间 `marqueeGrid`),GeometryReader 背景测内容 frame 做 viewport→内容坐标换算;命中集合经纯函数 `MarqueeSelection.resolve` 应用到 `selectedPhotoIDs`。

**Tech Stack:** SwiftUI + AppKit(NSEvent 读 Shift);XCTest(新增 FrameScoopTests 目标,XcodeGen);macOS 14 target,Swift 5.9。

## Global Constraints

- 工程由 XcodeGen 生成:改 `project.yml` 后必须运行 `bash Scripts/generate_project.sh`。
- 构建/测试均用 `-project FrameScoop.xcodeproj -derivedDataPath build/DerivedData`(与 Scripts/build.sh 一致);`.xcodeproj` 在 .gitignore,不提交。
- 目标部署版本 macOS 14.0;代码注释用中文,与现有代码风格一致。
- 网格常量:spacing=4、内容 padding=4、cell 高=thumbnailSize.cellSize、cell 宽=`max(cellSize * photo.aspectRatio, 40)`。
- 现有布局行为不得改变(FlowLayout/BurstFlowLayout 换行规则逐条保持)。
- 提交信息中文,按任务小步提交。

---

### Task 1: 测试目标与 scheme

**Files:**
- Modify: `project.yml`(新增测试 target + 显式 scheme)
- Create: `FrameScoopTests/SmokeTests.swift`

**Interfaces:**
- Produces: `xcodebuild test -project FrameScoop.xcodeproj -scheme FrameScoop -configuration Debug -destination 'platform=macOS' -derivedDataPath build/DerivedData` 可运行 XCTest(后续任务所有测试跑此命令)。

- [ ] **Step 1: project.yml 增加测试 target 与 scheme**

在 `project.yml` 的 `targets:` 段后追加:

```yaml
  FrameScoopTests:
    type: bundle.unit-test
    platform: macOS
    deploymentTarget: "14.0"
    sources:
      - path: FrameScoopTests
    dependencies:
      - target: FrameScoop
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.framescoop.tests
        GENERATE_INFOPLIST_FILE: YES
```

文件末尾追加(顶级键,与 `targets:` 平级):

```yaml
schemes:
  FrameScoop:
    build:
      targets:
        FrameScoop: all
    run:
      config: Debug
    test:
      config: Debug
      targets:
        - FrameScoopTests
```

- [ ] **Step 2: 创建冒烟测试**

`FrameScoopTests/SmokeTests.swift`:

```swift
import XCTest
@testable import FrameScoop

final class SmokeTests: XCTestCase {
    /// 冒烟: 测试模块可加载且宿主 app 可运行(真实断言,验证 200x100 → aspectRatio 2)
    func testModuleLoadsAndHostAppRuns() {
        let p = PhotoItem(url: URL(fileURLWithPath: "/tmp/smoke.jpg"), name: "smoke.jpg", size: 0,
                          creationDate: nil, modificationDate: nil, pixelWidth: 200, pixelHeight: 100)
        XCTAssertEqual(p.aspectRatio, 2)
    }
}
```

- [ ] **Step 3: 生成工程并跑测试(应通过)**

```bash
bash Scripts/generate_project.sh
xcodebuild test -project FrameScoop.xcodeproj -scheme FrameScoop \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData | tail -5
```

Expected: `** TEST SUCCEEDED **`(测试宿主 app 会启动,可能先执行文件夹预计算,属正常)。

- [ ] **Step 4: Commit**

```bash
git add project.yml FrameScoopTests/SmokeTests.swift
git commit -m "新增 FrameScoopTests 测试目标与 scheme（框选功能 TDD 前置）"
```

---

### Task 2: GridGeometry.flowFrames / flowRows,TDD

**Files:**
- Create: `FrameScoop/Views/GridGeometry.swift`(本任务只实现 flowFrames/flowRows 与类型骨架)
- Modify: `FrameScoop/Views/PhotoGridView.swift:306-345`(FlowLayout 改用 flowRows)
- Test: `FrameScoopTests/GridGeometryTests.swift`

**Interfaces:**
- Consumes: Task 1 的测试运行环境。
- Produces(后续任务依赖,签名精确):
  - `struct GridPhotoFrame: Equatable { let photo: PhotoItem; let frame: CGRect }`
  - `enum GridGeometry`:
    - `static func flowFrames(items: [PhotoItem], rowHeight: CGFloat, spacing: CGFloat, availableWidth: CGFloat) -> [GridPhotoFrame]`
    - `static func flowRows(items: [PhotoItem], rowHeight: CGFloat, spacing: CGFloat, availableWidth: CGFloat) -> [[PhotoItem]]`
    - (Task 3 补 burstFrames/burstRows;Task 4 补 hitPhotoIDs)

- [ ] **Step 1: 写失败测试**

`FrameScoopTests/GridGeometryTests.swift`:

```swift
import XCTest
import CoreGraphics
@testable import FrameScoop

final class GridGeometryTests: XCTestCase {

    private func photo(_ name: String, _ w: Int, _ h: Int) -> PhotoItem {
        PhotoItem(url: URL(fileURLWithPath: "/tmp/\(name).jpg"), name: "\(name).jpg", size: 0,
                  creationDate: nil, modificationDate: nil, pixelWidth: w, pixelHeight: h)
    }

    func testFlowFramesSingleRow() {
        // 2 张 1:1(100)+ 1 张 2:1(200): 100+4+100+4+200 = 408 > 400? 否: 100+4+100+4=208, +4+200=412 > 400 → 第三张换行
        let items = [photo("a", 1, 1), photo("b", 1, 1), photo("c", 2, 1)]
        let frames = GridGeometry.flowFrames(items: items, rowHeight: 100, spacing: 4, availableWidth: 400)
        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(frames[0].frame, CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(frames[1].frame, CGRect(x: 104, y: 0, width: 100, height: 100))
        XCTAssertEqual(frames[2].frame, CGRect(x: 0, y: 104, width: 200, height: 100))
    }

    func testFlowFramesWrapsOnOverflow() {
        // 300 宽放不下第 3 张(100+4+100+4+100=308>300)
        let items = [photo("a", 1, 1), photo("b", 1, 1), photo("c", 1, 1)]
        let frames = GridGeometry.flowFrames(items: items, rowHeight: 100, spacing: 4, availableWidth: 300)
        XCTAssertEqual(frames.map { $0.frame.origin }, [CGPoint(x: 0, y: 0), CGPoint(x: 104, y: 0), CGPoint(x: 0, y: 104)])
    }

    func testFlowFramesZeroWidthSingleRow() {
        // availableWidth <= 0 时旧行为: 全部单行
        let items = [photo("a", 1, 1), photo("b", 1, 1)]
        let frames = GridGeometry.flowFrames(items: items, rowHeight: 100, spacing: 4, availableWidth: 0)
        XCTAssertEqual(frames.map { $0.frame.origin.y }, [0, 0])
        XCTAssertEqual(frames[1].frame.origin.x, 104)
    }

    func testFlowFramesKeepsRowWhenExactlyFits() {
        // 边界回归: 3×100 + 2×4 = 308 <= 310 同行(旧规则);若多算一个尾部 spacing(312 > 310)会错误换行
        let items = [photo("a", 1, 1), photo("b", 1, 1), photo("c", 1, 1)]
        let frames = GridGeometry.flowFrames(items: items, rowHeight: 100, spacing: 4, availableWidth: 310)
        XCTAssertEqual(frames.map { $0.frame.origin },
                       [CGPoint(x: 0, y: 0), CGPoint(x: 104, y: 0), CGPoint(x: 208, y: 0)])
    }

    func testFlowRowsGroupsByRow() {
        let items = [photo("a", 1, 1), photo("b", 1, 1), photo("c", 1, 1)]
        let rows = GridGeometry.flowRows(items: items, rowHeight: 100, spacing: 4, availableWidth: 300)
        XCTAssertEqual(rows.map { $0.map(\.name) }, [["a.jpg", "b.jpg"], ["c.jpg"]])
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `xcodebuild test -project FrameScoop.xcodeproj -scheme FrameScoop -configuration Debug -destination 'platform=macOS' -derivedDataPath build/DerivedData`
Expected: FAIL(编译错误: `GridGeometry` / `GridPhotoFrame` 不存在)。

- [ ] **Step 3: 实现 flowFrames / flowRows**

`FrameScoop/Views/GridGeometry.swift`:

```swift
//
//  GridGeometry.swift
//  FrameScoop
//
//  网格布局的确定性几何计算：流式/连拍两种布局的行与 frame 纯函数。
//  显示布局（FlowLayout / BurstFlowLayout）与框选命中（PhotoGridView）共用同一份几何，
//  保证任何布局调整自动同步到框选。
//

import Foundation
import CoreGraphics

/// 一张图片在网格内容坐标中的显示 frame（内容坐标原点 = LazyVStack 左上角）
struct GridPhotoFrame: Equatable {
    let photo: PhotoItem
    let frame: CGRect
}

enum GridGeometry {

    /// 流式布局（固定行高、宽度按比例自适应）的 frame 计算，换行规则与旧 FlowLayout.computeRows 完全一致。
    static func flowFrames(items: [PhotoItem], rowHeight: CGFloat, spacing: CGFloat, availableWidth: CGFloat) -> [GridPhotoFrame] {
        var frames: [GridPhotoFrame] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowCount = 0
        for photo in items {
            let w = max(rowHeight * photo.aspectRatio, 40)
            // 旧规则等价式: currentWidth(含 k-1 个内部 spacing) + spacing + w ≡ x + w(x 为候选起点)
            // 注意勿写成 x + spacing + w: 那会多算一个尾部 spacing,导致刚好放下的行被提前换行。
            if availableWidth > 0, rowCount > 0, x + w > availableWidth {
                x = 0
                y += rowHeight + spacing
                rowCount = 0
            }
            frames.append(GridPhotoFrame(photo: photo, frame: CGRect(x: x, y: y, width: w, height: rowHeight)))
            x += w + spacing
            rowCount += 1
        }
        return frames
    }

    /// 流式布局的行分组：按 frame.minY 相同的连续帧聚合（同 rowHeight 下 y 相等即同行）。
    static func flowRows(items: [PhotoItem], rowHeight: CGFloat, spacing: CGFloat, availableWidth: CGFloat) -> [[PhotoItem]] {
        let frames = flowFrames(items: items, rowHeight: rowHeight, spacing: spacing, availableWidth: availableWidth)
        var rows: [[PhotoItem]] = []
        var lastY: CGFloat? = nil
        for f in frames {
            if lastY == f.frame.minY, !rows.isEmpty {
                rows[rows.count - 1].append(f.photo)
            } else {
                rows.append([f.photo])
                lastY = f.frame.minY
            }
        }
        return rows
    }
}
```

- [ ] **Step 4: FlowLayout 切换到共享几何**

`PhotoGridView.swift` 中 `FlowLayout`(行 306-345):

```swift
    var body: some View {
        let rows = GridGeometry.flowRows(items: items, rowHeight: rowHeight, spacing: spacing, availableWidth: availableWidth)
        LazyVStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: spacing) {
                    ForEach(row) { photo in
                        content(photo)
                    }
                }
            }
        }
    }
```

删除原 `computeRows()` 方法。

- [ ] **Step 5: 跑测试确认通过 + 构建**

```bash
xcodebuild test -project FrameScoop.xcodeproj -scheme FrameScoop \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData | tail -5
CONFIG=Debug bash Scripts/build.sh
```

Expected: `** TEST SUCCEEDED **` 且构建成功(FlowLayout 行为不变,渲染无变化)。

- [ ] **Step 6: Commit**

```bash
git add FrameScoop/Views/GridGeometry.swift FrameScoop/Views/PhotoGridView.swift FrameScoopTests/GridGeometryTests.swift
git commit -m "网格几何提为纯函数 flowFrames/flowRows，FlowLayout 改用共享几何（TDD）"
```

---

### Task 3: GridGeometry.burstFrames / burstRows,TDD

**Files:**
- Modify: `FrameScoop/Views/GridGeometry.swift`(补 burstFrames/burstRows)
- Modify: `FrameScoop/Views/PhotoGridView.swift:352-422`(BurstFlowLayout 改用 burstRows)
- Test: `FrameScoopTests/GridGeometryTests.swift`(追加 burst 测试)

**Interfaces:**
- Consumes: Task 2 的 GridPhotoFrame / GridGeometry。
- Produces:
  - `static func burstFrames(segments: [BurstSegment], cellWidth: (PhotoItem) -> CGFloat, rowHeight: CGFloat, spacing: CGFloat, availableWidth: CGFloat) -> [GridPhotoFrame]`
  - `static func burstRows(segments: [BurstSegment], cellWidth: (PhotoItem) -> CGFloat, rowHeight: CGFloat, spacing: CGFloat, availableWidth: CGFloat) -> [[PhotoItem]]`

- [ ] **Step 1: 写失败测试**

`GridGeometryTests.swift` 追加:

```swift
    // MARK: - 连拍布局

    func testBurstFramesExclusiveRowsAndTrailingGap() {
        // 单张 a + 连拍组(b,c) + 单张 d: 组独占行、组末行留白(d 不在 b,c 行尾)
        let segs: [BurstSegment] = [
            .single(photo("a", 1, 1)),
            .burst([photo("b", 1, 1), photo("c", 1, 1)]),
            .single(photo("d", 1, 1))
        ]
        let frames = GridGeometry.burstFrames(segments: segs, cellWidth: { _ in 100 },
                                              rowHeight: 100, spacing: 4, availableWidth: 400)
        XCTAssertEqual(frames.map { $0.photo.name }, ["a.jpg", "b.jpg", "c.jpg", "d.jpg"])
        XCTAssertEqual(frames[0].frame.origin, CGPoint(x: 0, y: 0))
        XCTAssertEqual(frames[1].frame.origin, CGPoint(x: 0, y: 104))
        XCTAssertEqual(frames[2].frame.origin, CGPoint(x: 104, y: 104))
        XCTAssertEqual(frames[3].frame.origin, CGPoint(x: 0, y: 208))
    }

    func testBurstFramesGroupInternalWrap() {
        // 组内放不下时组内换行(仍独占自己的行,不接下一段)
        let segs: [BurstSegment] = [
            .burst([photo("b", 1, 1), photo("c", 1, 1), photo("d", 1, 1)]),
            .single(photo("e", 1, 1))
        ]
        let frames = GridGeometry.burstFrames(segments: segs, cellWidth: { _ in 100 },
                                              rowHeight: 100, spacing: 4, availableWidth: 210)
        // b,c 同行(0,0)/(104,0);d 组内换行(0,104);e 新行(0,208)
        XCTAssertEqual(frames.map { $0.frame.origin },
                       [CGPoint(x: 0, y: 0), CGPoint(x: 104, y: 0),
                        CGPoint(x: 0, y: 104), CGPoint(x: 0, y: 208)])
    }

    func testBurstFramesSinglesFlowAcrossSegments() {
        // 连续单张段流式同行(与旧 behavior 一致)
        let segs: [BurstSegment] = [.single(photo("a", 1, 1)), .single(photo("b", 1, 1))]
        let frames = GridGeometry.burstFrames(segments: segs, cellWidth: { _ in 100 },
                                              rowHeight: 100, spacing: 4, availableWidth: 400)
        XCTAssertEqual(frames.map { $0.frame.origin }, [CGPoint(x: 0, y: 0), CGPoint(x: 104, y: 0)])
    }

    func testBurstRowsMatchesFrames() {
        let segs: [BurstSegment] = [
            .single(photo("a", 1, 1)),
            .burst([photo("b", 1, 1), photo("c", 1, 1)]),
            .single(photo("d", 1, 1))
        ]
        let rows = GridGeometry.burstRows(segments: segs, cellWidth: { _ in 100 },
                                          rowHeight: 100, spacing: 4, availableWidth: 400)
        XCTAssertEqual(rows.map { $0.map(\.name) }, [["a.jpg"], ["b.jpg", "c.jpg"], ["d.jpg"]])
    }
```

- [ ] **Step 2: 运行确认失败**

Run: 同 Task 2 Step 2 命令。
Expected: FAIL(`burstFrames` / `burstRows` 不存在)。

- [ ] **Step 3: 实现 burstFrames / burstRows**

`GridGeometry.swift` 追加(换行规则与旧 BurstFlowLayout.computeRows 完全一致):

```swift
    /// 连拍分段布局的 frame 计算：连拍组独占行(组内可换行、组末行留白)；单张段流式排列。
    static func burstFrames(segments: [BurstSegment], cellWidth: (PhotoItem) -> CGFloat,
                            rowHeight: CGFloat, spacing: CGFloat, availableWidth: CGFloat) -> [GridPhotoFrame] {
        guard availableWidth > 0 else {
            // 与旧行为一致: 宽度未知时全部单行
            let photos = segments.flatMap { seg -> [PhotoItem] in
                switch seg { case .single(let p): return [p]; case .burst(let ps): return ps }
            }
            var x: CGFloat = 0
            return photos.map { p in
                let w = cellWidth(p)
                defer { x += w + spacing }
                return GridPhotoFrame(photo: p, frame: CGRect(x: x, y: 0, width: w, height: rowHeight))
            }
        }
        var frames: [GridPhotoFrame] = []
        var y: CGFloat = 0
        for segment in segments {
            switch segment {
            case .single(let photo):
                let w = cellWidth(photo)
                let continuesFlow = frames.last.map { $0.frame.minY == y } ?? false
                var x = continuesFlow ? frames.last!.frame.maxX + spacing : 0
                if continuesFlow, x + w > availableWidth {
                    y += rowHeight + spacing
                    x = 0
                }
                frames.append(GridPhotoFrame(photo: photo, frame: CGRect(x: x, y: y, width: w, height: rowHeight)))
            case .burst(let group):
                // 连拍组独占行: 组首永远新行; 组末行留白(与下一段分开)
                if !frames.isEmpty { y += rowHeight + spacing }
                var burstX: CGFloat = 0
                var burstRowCount = 0
                for photo in group {
                    let w = cellWidth(photo)
                    // 与旧 burstRow 换行条件等价: burstWidth + spacing + w ≡ burstX + w(burstX 为候选起点);
                    // 勿写成 burstX + spacing + w(多算尾部 spacing 会提前换行)。
                    if burstRowCount > 0, burstX + w > availableWidth {
                        y += rowHeight + spacing
                        burstX = 0
                        burstRowCount = 0
                    }
                    frames.append(GridPhotoFrame(photo: photo, frame: CGRect(x: burstX, y: y, width: w, height: rowHeight)))
                    burstX += w + spacing
                    burstRowCount += 1
                }
                y += rowHeight + spacing
            }
        }
        return frames
    }

    /// 连拍布局的行分组(同 flowRows: 按 frame.minY 聚合连续帧)。
    static func burstRows(segments: [BurstSegment], cellWidth: (PhotoItem) -> CGFloat,
                          rowHeight: CGFloat, spacing: CGFloat, availableWidth: CGFloat) -> [[PhotoItem]] {
        let frames = burstFrames(segments: segments, cellWidth: cellWidth, rowHeight: rowHeight,
                                 spacing: spacing, availableWidth: availableWidth)
        var rows: [[PhotoItem]] = []
        var lastY: CGFloat? = nil
        for f in frames {
            if lastY == f.frame.minY, !rows.isEmpty {
                rows[rows.count - 1].append(f.photo)
            } else {
                rows.append([f.photo])
                lastY = f.frame.minY
            }
        }
        return rows
    }
```

- [ ] **Step 4: BurstFlowLayout 切换到共享几何**

`PhotoGridView.swift` 中 `BurstFlowLayout.body` 改为:

```swift
    var body: some View {
        let rows = GridGeometry.burstRows(segments: segments, cellWidth: cellWidth,
                                          rowHeight: rowHeight, spacing: spacing,
                                          availableWidth: availableWidth)
        LazyVStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: spacing) {
                    ForEach(row) { photo in content(photo) }
                }
            }
        }
    }
```

删除原 `computeRows()` 方法。

- [ ] **Step 5: 跑测试 + 构建**

Run: 同 Task 2 Step 5。
Expected: `** TEST SUCCEEDED **` 且构建成功。

- [ ] **Step 6: Commit**

```bash
git add FrameScoop/Views/GridGeometry.swift FrameScoop/Views/PhotoGridView.swift FrameScoopTests/GridGeometryTests.swift
git commit -m "连拍布局几何提为 burstFrames/burstRows，BurstFlowLayout 改用共享几何（TDD）"
```

---

### Task 4: hitPhotoIDs 与 MarqueeSelection.resolve,TDD

**Files:**
- Modify: `FrameScoop/Views/GridGeometry.swift`(补 hitPhotoIDs + MarqueeSelection)
- Test: `FrameScoopTests/MarqueeSelectionTests.swift`(新建)

**Interfaces:**
- Consumes: Task 2/3 的 GridGeometry。
- Produces(视图与 VM 依赖):
  - `static func hitPhotoIDs(in rect: CGRect, frames: [GridPhotoFrame]) -> Set<String>`
  - `enum MarqueeSelection { static func resolve(current: Set<String>, hit: Set<String>, additive: Bool) -> Set<String> }`

- [ ] **Step 1: 写失败测试**

`FrameScoopTests/MarqueeSelectionTests.swift`:

```swift
import XCTest
import CoreGraphics
@testable import FrameScoop

final class MarqueeSelectionTests: XCTestCase {

    private func photo(_ name: String) -> PhotoItem {
        PhotoItem(url: URL(fileURLWithPath: "/tmp/\(name).jpg"), name: "\(name).jpg", size: 0,
                  creationDate: nil, modificationDate: nil, pixelWidth: 1, pixelHeight: 1)
    }

    private func frames(_ names: [String]) -> [GridPhotoFrame] {
        GridGeometry.flowFrames(items: names.map(photo), rowHeight: 100, spacing: 4, availableWidth: 400)
    }

    func testHitIntersectsOnlyOverlapping() {
        // a(0,0,100,100) b(104,0,100,100): rect(50,0,50,100) 只与 a 相交
        let hit = GridGeometry.hitPhotoIDs(in: CGRect(x: 50, y: 0, width: 50, height: 100),
                                           frames: frames(["a", "b"]))
        XCTAssertEqual(hit, ["/tmp/a.jpg"])
    }

    func testHitPartialIntersectionCounts() {
        // 擦到 b 左边缘 1pt 也算命中(部分相交)
        let hit = GridGeometry.hitPhotoIDs(in: CGRect(x: 100, y: 0, width: 10, height: 100),
                                           frames: frames(["a", "b"]))
        XCTAssertEqual(hit, ["/tmp/b.jpg"])
    }

    func testHitEmptyRectHitsNothing() {
        let hit = GridGeometry.hitPhotoIDs(in: CGRect(x: 500, y: 500, width: 10, height: 10),
                                           frames: frames(["a", "b"]))
        XCTAssertTrue(hit.isEmpty)
    }

    func testResolveReplace() {
        XCTAssertEqual(MarqueeSelection.resolve(current: ["a", "b"], hit: ["c"], additive: false), ["c"])
    }

    func testResolveReplaceWithEmptyHitClears() {
        XCTAssertTrue(MarqueeSelection.resolve(current: ["a", "b"], hit: [], additive: false).isEmpty)
    }

    func testResolveAdditiveUnions() {
        XCTAssertEqual(MarqueeSelection.resolve(current: ["a", "b"], hit: ["c"], additive: true), ["a", "b", "c"])
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: 同 Task 2 Step 2 命令。
Expected: FAIL(编译错误: `hitPhotoIDs` / `MarqueeSelection` 不存在)。

- [ ] **Step 3: 实现**

`GridGeometry.swift` 追加:

```swift
    /// 与框选矩形相交(含部分相交)的图片 id 集合。
    static func hitPhotoIDs(in rect: CGRect, frames: [GridPhotoFrame]) -> Set<String> {
        var ids: Set<String> = []
        for f in frames where rect.intersects(f.frame) {
            ids.insert(f.photo.id)
        }
        return ids
    }
```

同文件末尾:

```swift
/// 框选结果的纯函数应用逻辑(可单测;VM 仅转发)。
enum MarqueeSelection {
    /// additive=false: 以命中集合替换当前选择(未命中任何图时即清空);
    /// additive=true: 并入当前选择。
    static func resolve(current: Set<String>, hit: Set<String>, additive: Bool) -> Set<String> {
        additive ? current.union(hit) : hit
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: 同 Task 2 Step 2 命令。
Expected: `** TEST SUCCEEDED **`。

- [ ] **Step 5: Commit**

```bash
git add FrameScoop/Views/GridGeometry.swift FrameScoopTests/MarqueeSelectionTests.swift
git commit -m "框选命中与选择应用纯函数 hitPhotoIDs / MarqueeSelection.resolve（TDD）"
```

---

### Task 5: VM 方法 + 视图手势与框选覆盖层

**Files:**
- Modify: `FrameScoop/ViewModels/PhotoLibraryViewModel.swift`(invertSelection 之后,约行 694,追加 `selectPhotoIDs`)
- Modify: `FrameScoop/Views/PhotoGridView.swift`(marquee 状态/手势/覆盖层/共享 layoutFrames)

**Interfaces:**
- Consumes: Task 4 的 `GridGeometry.hitPhotoIDs`、`MarqueeSelection.resolve`。
- Produces: 用户可用的框选交互(无新公共 API 暴露给后续任务)。

- [ ] **Step 1: VM 增加 selectPhotoIDs**

`PhotoLibraryViewModel.swift`,在 `invertSelection()` 之后追加:

```swift
    /// 框选应用：additive=false 以命中集合替换选择（框选未命中任何图时即清空）；
    /// additive=true 并入现有选择。
    func selectPhotoIDs(_ ids: Set<String>, additive: Bool) {
        selectedPhotoIDs = MarqueeSelection.resolve(current: selectedPhotoIDs, hit: ids, additive: additive)
    }
```

- [ ] **Step 2: PhotoGridView 增加框选状态与常量**

文件头部 `import SwiftUI` 后追加 `import AppKit`(NSEvent.modifierFlags 用)。

文件末尾(`BurstFlowLayout` 之后)追加:

```swift
// MARK: - 框选(Marquee)

/// 一次框选拖拽的起止点(坐标空间: ScrollView 视口 "marqueeGrid")
private struct MarqueeDrag {
    var start: CGPoint
    var current: CGPoint
}

/// 网格内容(布局 LazyVStack)在视口中的 frame: origin 含滚动偏移与 padding, size 为内容尺寸。
private struct GridContentFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

/// 视口宽度(布局与框选几何共用;与布局拿到的 geo.size.width 同源)。
private struct GridViewportWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
```

`PhotoGridView` 结构体顶部(`@Environment(\.openWindow)` 之后)追加状态:

```swift
    /// 框选拖拽状态(nil = 未在框选)
    @State private var marquee: MarqueeDrag? = nil
    /// 本次框选是否加选(拖拽起点时刻的 Shift 状态)
    @State private var marqueeAdditive = false
    /// 网格内容在视口中的 frame(由 GridContentFrameKey 偏好回填)
    @State private var contentFrame: CGRect = .zero
    /// 网格视口宽度(由 GridViewportWidthKey 偏好回填)
    @State private var gridWidth: CGFloat = 0
    /// 坐标空间名
    private static let marqueeSpace = "marqueeGrid"
```

- [ ] **Step 3: 布局选择条件与 layoutFrames 提为共享**

`PhotoGridView` 中 `grid` 计算属性的条件判断(行 52-55)改为调用 `usesBurstLayout`;追加:

```swift
    /// 是否走连拍分段布局(与 grid body 原条件一致)
    private var usesBurstLayout: Bool {
        library.showsBurstFilter && !library.showsBlurOnly
            && !library.showsEyeClosedOnly && !library.showsSelectedOnly
            && !library.displayedBurstSegments.isEmpty
    }

    /// 单元格宽度(与 GridCell body 一致)
    private func cellWidth(_ photo: PhotoItem) -> CGFloat {
        max(library.thumbnailSize.cellSize * photo.aspectRatio, 40)
    }

    /// 当前显示布局下每张图的内容坐标 frame(框选命中用;与显示布局共用 GridGeometry)
    private var layoutFrames: [GridPhotoFrame] {
        if usesBurstLayout {
            return GridGeometry.burstFrames(segments: library.displayedBurstSegments,
                                            cellWidth: cellWidth,
                                            rowHeight: library.thumbnailSize.cellSize,
                                            spacing: 4, availableWidth: gridWidth)
        }
        return GridGeometry.flowFrames(items: library.displayedPhotos,
                                       rowHeight: library.thumbnailSize.cellSize,
                                       spacing: 4, availableWidth: gridWidth)
    }
```

`grid` body 中的条件改为 `if usesBurstLayout {` / `else {`(其余不动)。

- [ ] **Step 4: 内容 frame 测量与视口宽度偏好**

`grid` 中布局 `Group` 与 `.padding(4)` 之间插入背景测量:

```swift
                }
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: GridContentFrameKey.self,
                                               value: proxy.frame(in: .named(Self.marqueeSpace)))
                    }
                }
                .padding(4)
```

`ScrollView` 上追加:

```swift
            .coordinateSpace(name: Self.marqueeSpace)
            .gesture(marqueeGesture)
            .overlay { marqueeOverlay }
            .preference(key: GridViewportWidthKey.self, value: geo.size.width)
```

`GeometryReader { geo in ... }` 之后(即 `grid` 末尾)追加:

```swift
        .onPreferenceChange(GridContentFrameKey.self) { contentFrame = $0 }
        .onPreferenceChange(GridViewportWidthKey.self) { gridWidth = $0 }
```

- [ ] **Step 5: 拖拽手势与覆盖层**

`PhotoGridView` 追加:

```swift
    // MARK: - 框选手势

    /// 框选拖拽: 起拖 ≥3pt 进入框选模式; 起拖瞬间记录 Shift 决定加选。
    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.marqueeSpace))
            .onChanged { value in
                if marquee == nil {
                    marquee = MarqueeDrag(start: value.startLocation, current: value.location)
                    marqueeAdditive = NSEvent.modifierFlags.contains(.shift)
                } else {
                    marquee?.current = value.location
                }
                applyMarqueeSelection()
            }
            .onEnded { value in
                marquee?.current = value.location
                applyMarqueeSelection()
                marquee = nil
            }
    }

    /// 视口坐标 → 内容坐标,标准化矩形并裁剪到内容边界,应用选中。
    private func applyMarqueeSelection() {
        guard let m = marquee else { return }
        let raw = CGRect(x: m.start.x - contentFrame.minX, y: m.start.y - contentFrame.minY,
                         width: m.current.x - m.start.x, height: m.current.y - m.start.y)
            .standardized
        let rect = raw.intersection(CGRect(origin: .zero, size: contentFrame.size))
        let ids = GridGeometry.hitPhotoIDs(in: rect, frames: layoutFrames)
        library.selectPhotoIDs(ids, additive: marqueeAdditive)
    }

    /// 框选矩形(视口坐标): accent 描边 + 15% 填充。
    @ViewBuilder
    private var marqueeOverlay: some View {
        if let m = marquee {
            let rect = CGRect(x: min(m.start.x, m.current.x), y: min(m.start.y, m.current.y),
                              width: abs(m.current.x - m.start.x), height: abs(m.current.y - m.start.y))
            Rectangle()
                .stroke(Color.accentColor, lineWidth: 1)
                .background(Color.accentColor.opacity(0.15))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)
        }
    }
```

- [ ] **Step 6: 构建**

```bash
CONFIG=Debug bash Scripts/build.sh
```

Expected: 构建成功(无编译错误)。注意:`applyMarqueeSelection` 中 `layoutFrames` 依赖 `gridWidth`,首帧前为 0,不影响(手势只能发生在布局完成后)。

- [ ] **Step 7: 运行手动验证清单(全部通过才算完成)**

```bash
open "build/DerivedData/Build/Products/Debug/FrameScoop.app"
```

- 普通网格:空白处按下拖动 → 出现框选矩形,框内(含擦边)图片选中,框外清空,松开矩形消失。
- 图片上按下拖动 → 同样框选;图片上单击(不拖) → 仍选单张;双击 → 仍开详情。
- Shift+拖 → 加选(原有选中保持)。
- 拖出可视区域外 → 矩形裁剪到内容边界,行为正常。
- 窗口缩放改变换行后框选 → 命中与显示一致。
- 连拍视图(开启连拍筛选) → 框选命中符合连拍独占行布局。
- 开启「只显示模糊/闭眼/选中」过滤后框选 → 只选中显示集。
- 浅色/深色模式各一遍(描边/填充随 accent)。

- [ ] **Step 8: Commit**

```bash
git add FrameScoop/ViewModels/PhotoLibraryViewModel.swift FrameScoop/Views/PhotoGridView.swift
git commit -m "网格框选：拖拽方框选中（Shift 加选、替换语义、实时更新、连拍/过滤布局共用几何）"
```

---

## Self-Review 记录

- Spec 覆盖:共享几何(Task 2/3)、手势与状态(Task 5)、替换+Shift 加选(Task 4/5)、实时更新(Task 5 onChanged)、边框视觉(Task 5)、无自动滚动/无 ESC(按 spec 明确不做)、过滤显示集(复用 displayedPhotos/displayedBurstSegments,Task 5 验证清单)。
- 类型一致性:`GridPhotoFrame`、`flowFrames/flowRows/burstFrames/burstRows/hitPhotoIDs`、`MarqueeSelection.resolve(current:hit:additive:)`、`selectPhotoIDs(_:additive:)` 各任务签名一致。
- 占位符扫描:无 TBD;所有步骤含完整代码。
