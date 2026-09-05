# Shift 范围选择 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 缩略图区域支持 Finder 风格 Shift 点击范围选择：锚点...被点照片之间的照片全选中。

**Architecture:** 纯函数 `RangeSelection.range`（TDD，仿 MarqueeSelection 先例）+ VM 私有锚点 `selectionAnchor` 与新方法 `clickSelection(_:shift:)` + 网格单击回调传 Shift 状态。区间顺序用 `displayedPhotos`（连拍模式已按视觉顺序扁平化）。

**Tech Stack:** Swift 5.9 / SwiftUI / XCTest，无新增依赖。

**Spec:** `docs/superpowers/specs/2026-09-05-shift-range-selection-design.md`

## Global Constraints

- 部署目标 macOS 14.0，Swift 5.9；注释与提交信息用中文，风格与现有代码一致。
- 新增测试文件后必须重新生成工程：`bash Scripts/generate_project.sh`（`.xcodeproj` 不入库）。
- 构建命令：
  `xcodebuild -project FrameScoop.xcodeproj -scheme FrameScoop -configuration Debug -derivedDataPath build/DerivedData build`
- **测试环境怪象（已知）**：测试套件全部通过后 app 宿主进程不退出，xcodebuild 挂到超时后报
  TEST FAILED（无任何失败用例）。判定标准 = 日志里的 `Test Suite 'XxxTests' passed` 行；
  看到套件通过后可提前终止 xcodebuild，不必等它超时。
- 单测快速循环：
  `xcodebuild test -project FrameScoop.xcodeproj -scheme FrameScoop -configuration Debug -derivedDataPath build/DerivedData -only-testing:FrameScoopTests/RangeSelectionTests 2>&1 | tee /tmp/range-tests.log`
- 运行 app 验证：`open build/DerivedData/Build/Products/Debug/FrameScoop.app`（GUI 操作需用户配合）。
- 改动前工作区应干净：HEAD = `74e24dd`。

---

### Task 1: 纯函数 RangeSelection.range（TDD）

**Files:**
- Create: `FrameScoopTests/RangeSelectionTests.swift`
- Modify: `FrameScoop/Views/GridGeometry.swift`（`MarqueeSelection` 枚举之后，~160 行）

**Interfaces:**
- Consumes: 无（纯函数）。
- Produces: `RangeSelection.range(from: String, to: String, in orderedIDs: [String]) -> Set<String>`
  —— Task 2 的 `clickSelection` 依赖此签名。

- [ ] **Step 1: 写失败测试**

创建 `FrameScoopTests/RangeSelectionTests.swift`（风格仿 `MarqueeSelectionTests`）：

```swift
import XCTest
@testable import FrameScoop

final class RangeSelectionTests: XCTestCase {

    /// 6 个 id 的有序列表
    private let ids = ["a", "b", "c", "d", "e", "f"]

    func testForwardRangeIncludesBothEnds() {
        XCTAssertEqual(RangeSelection.range(from: "b", to: "e", in: ids), ["b", "c", "d", "e"])
    }

    func testBackwardRangeSameSet() {
        XCTAssertEqual(RangeSelection.range(from: "e", to: "b", in: ids), ["b", "c", "d", "e"])
    }

    func testSamePhotoIsSingleton() {
        XCTAssertEqual(RangeSelection.range(from: "c", to: "c", in: ids), ["c"])
    }

    func testMissingFromIsEmpty() {
        XCTAssertTrue(RangeSelection.range(from: "x", to: "c", in: ids).isEmpty)
    }

    func testMissingToIsEmpty() {
        XCTAssertTrue(RangeSelection.range(from: "c", to: "x", in: ids).isEmpty)
    }

    func testAdjacentPair() {
        XCTAssertEqual(RangeSelection.range(from: "b", to: "c", in: ids), ["b", "c"])
    }

    func testEmptyListIsEmpty() {
        XCTAssertTrue(RangeSelection.range(from: "a", to: "b", in: []).isEmpty)
    }
}
```

- [ ] **Step 2: 重新生成工程 + 跑测试确认失败**

```bash
bash Scripts/generate_project.sh
xcodebuild test -project FrameScoop.xcodeproj -scheme FrameScoop -configuration Debug \
  -derivedDataPath build/DerivedData -only-testing:FrameScoopTests/RangeSelectionTests 2>&1 | tee /tmp/range-tests.log
```

Expected: 编译错误 `cannot find 'RangeSelection' in scope`（红 = 编译失败即可，不必等测试执行）。
看到编译错误后按 Ctrl-C 终止（若 xcodebuild 已进入测试执行阶段，参照「测试环境怪象」判定）。

- [ ] **Step 3: 实现纯函数**

在 `GridGeometry.swift` 的 `MarqueeSelection` 枚举之后追加：

```swift
/// Shift 点击范围选择：orderedIDs（展示顺序）中 from...to 之间的全部 id（含两端）。
/// 任一 id 不存在或列表为空则返回空集合（调用方兜底为「仅选中被点张」）。
enum RangeSelection {
    static func range(from: String, to: String, in orderedIDs: [String]) -> Set<String> {
        guard let i = orderedIDs.firstIndex(of: from),
              let j = orderedIDs.firstIndex(of: to) else { return [] }
        return Set(orderedIDs[min(i, j)...max(i, j)])
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

```bash
xcodebuild test -project FrameScoop.xcodeproj -scheme FrameScoop -configuration Debug \
  -derivedDataPath build/DerivedData -only-testing:FrameScoopTests/RangeSelectionTests 2>&1 | tee /tmp/range-tests.log
```

Expected: 日志出现 `Test Suite 'RangeSelectionTests' passed`、`Executed 7 tests, with 0 failures`。
（整体 `** TEST FAILED **` 若来自宿主不退出超时属已知怪象，以套件行为准。）

- [ ] **Step 5: 提交**

```bash
git add FrameScoopTests/RangeSelectionTests.swift FrameScoop/Views/GridGeometry.swift
git commit -m "feat: Shift 范围选择纯函数 RangeSelection.range（TDD）"
```

---

### Task 2: VM 锚点 + clickSelection + 网格接线

**Files:**
- Modify: `FrameScoop/ViewModels/PhotoLibraryViewModel.swift`（~97 行加私有锚点；~660 行加 `clickSelection`；~688 行改 `selectPhotoIDs`）
- Modify: `FrameScoop/Views/PhotoGridView.swift`（137 行单击回调）

**Interfaces:**
- Consumes: Task 1 的 `RangeSelection.range(from:to:in:)`；既有 `selectedPhotoIDs`、`displayedPhotos`、`toggleSelection`、`MarqueeSelection.resolve`。
- Produces: `func clickSelection(_ photo: PhotoItem, shift: Bool)` —— 视图单击回调调用；无后续任务依赖。

- [ ] **Step 1: VM 加私有锚点**

在 `PhotoLibraryViewModel.swift` 的 `selectedPhotoIDs` 声明（~97 行）之后插入：

```swift
    /// Shift 范围选择的锚点（Finder 语义）：最近一次非 Shift 选中动作确定，
    /// 连续 Shift 点击从同一锚点扩展；框选非加选时更新为框选结果首张。
    private var selectionAnchor: String?
```

- [ ] **Step 2: VM 加 clickSelection**

在 `toggleSelection(_:)`（~666 行）之后插入：

```swift
    /// 网格单击选中（Finder 风格 Shift 范围选择）：
    /// - 普通点击：toggle（维持现状），锚点 = 该张
    /// - Shift 点击且锚点有效且不同张：选中集 = 锚点...该张的区间（替换），锚点不变
    /// - Shift 点击且锚点 == 该张：选中集收缩为 {该张}（锚点赋同值，无实际变化）
    /// - Shift 点击但无锚点/锚点已不在当前列表：选中集 = {该张}，锚点 = 该张
    func clickSelection(_ photo: PhotoItem, shift: Bool) {
        if shift {
            if let anchor = selectionAnchor, anchor != photo.id {
                let range = RangeSelection.range(from: anchor, to: photo.id,
                                                 in: displayedPhotos.map(\.id))
                if !range.isEmpty {
                    selectedPhotoIDs = range
                    return  // 锚点不变：连续 Shift 点击从同一锚点扩展
                }
            }
            selectedPhotoIDs = [photo.id]
            selectionAnchor = photo.id
            return
        }
        toggleSelection(photo)
        selectionAnchor = photo.id
    }
```

- [ ] **Step 3: selectPhotoIDs 维护锚点**

把 `selectPhotoIDs(_:additive:)`（~688 行）改为：

```swift
    func selectPhotoIDs(_ ids: Set<String>, additive: Bool) {
        selectedPhotoIDs = MarqueeSelection.resolve(current: selectedPhotoIDs, hit: ids, additive: additive)
        if !additive {
            // 非加选框选后，锚点 = 新选中集按展示顺序的第一张（空则 nil）；
            // 加选（Shift 框选）保持原锚点，后续 Shift 点击仍从原锚点扩展。
            selectionAnchor = displayedPhotos.first(where: { selectedPhotoIDs.contains($0.id) })?.id
        }
    }
```

- [ ] **Step 4: 网格单击传 Shift 状态**

把 `PhotoGridView.swift:137` 的

```swift
            onSingleTap: { library.toggleSelection(photo) },
```

改为

```swift
            onSingleTap: { library.clickSelection(photo, shift: NSEvent.modifierFlags.contains(.shift)) },
```

（`NSEvent` 已在文件内使用，无需新 import。）

- [ ] **Step 5: 编译 + 全量测试不回归**

```bash
xcodebuild -project FrameScoop.xcodeproj -scheme FrameScoop -configuration Debug \
  -derivedDataPath build/DerivedData build 2>&1 | grep -E "error:|warning:|BUILD"
xcodebuild test -project FrameScoop.xcodeproj -scheme FrameScoop -configuration Debug \
  -derivedDataPath build/DerivedData 2>&1 | tee /tmp/full-tests.log
```

Expected: `** BUILD SUCCEEDED **`；日志出现三个既有套件 + RangeSelectionTests 全部 `passed`，
共 `Executed 24 tests, with 0 failures`（17 旧 + 7 新）。

- [ ] **Step 6: 运行时手测（需用户配合 GUI 操作）**

启动：`open build/DerivedData/Build/Products/Debug/FrameScoop.app`，在缩略图区域依次验证：

1. 普通点击 A：toggle 行为与之前一致（选中/取消）；
2. 点击 A → Shift 点击 D：A-D 之间全部选中；
3. 继续 Shift 点击 F：A-F 全部选中（锚点仍为 A）；
4. 点击 A → Shift 点击 A：收缩为仅 A；
5. 反向：点击 D → Shift 点击 A：A-D 全部选中；
6. 拖拽框选 C-D（非加选）→ Shift 点击 F：从 C 扩展到 F；
7. 点击 A → Shift 拖拽框选（加选）→ Shift 点击 D：从 A 扩展到 D（锚点未因加选框选而变）；
8. 开启连拍筛选后重复 2：区间按视觉顺序（连拍段顺序）。

- [ ] **Step 7: 提交**

```bash
git add FrameScoop/ViewModels/PhotoLibraryViewModel.swift FrameScoop/Views/PhotoGridView.swift
git commit -m "feat: 缩略图区域 Shift 范围选择（Finder 风格锚点语义）"
```

---

## Self-Review 结论

- **Spec 覆盖**：纯函数与 7 用例 → Task 1；锚点字段/clickSelection 四分支/selectPhotoIDs 锚点维护 → Task 2 Step 1-3；视图传 Shift → Step 4；spec 验证清单 8 项 → Step 6 一一对应；spec「范围外」无遗漏实现。
- **占位符**：无 TBD；所有代码步骤含完整代码。
- **类型一致性**：`RangeSelection.range(from:to:in:)` 签名在 Task 1 定义、Task 2 引用一致；`selectionAnchor` 两处引用一致。
