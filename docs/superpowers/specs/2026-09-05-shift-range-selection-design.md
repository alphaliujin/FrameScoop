# Shift 范围选择（缩略图区域）设计文档

日期：2026-09-05

## 目标

缩略图区域支持 Finder 风格的 Shift 点击范围选择：选中一张照片后，按住 Shift 点击另一张，
自动选中两者（按展示顺序）之间的所有照片。

## 范围与语义（已与用户确认）

- **仅缩略图区域**生效；详情窗口底部胶片条保持现状（单击切换选中）。
- **Finder 风格**：Shift 点击从「锚点」到被点照片的连续区间**替换**当前选中；
  连续多次 Shift 点击都从同一锚点扩展；锚点只在非 Shift 选中动作时更新。
- 区间顺序 = `displayedPhotos` 顺序。连拍筛选模式下 `displayedPhotos`
  已按连拍段扁平化重排（`rebuildDisplayedPhotos`），与视觉顺序一致；
  普通/模糊筛选模式同样一致。

## 现状

- 网格单击：`GridCell.onTapGesture(count: 1)` → `library.toggleSelection(photo)`（切换选中）。
- 框选（Marquee）：拖拽 ≥3pt，起点时刻记录 Shift；`library.selectPhotoIDs(ids, additive:)`
  → `MarqueeSelection.resolve`（纯函数，已 TDD）。
- 选中状态集中在 VM：`@Published var selectedPhotoIDs: Set<String>`，详情窗口共享。
- 仓库已有测试目标 FrameScoopTests，纯函数 TDD 为既有惯例（GridGeometry / MarqueeSelection）。

## 设计

### 1. 纯函数（`FrameScoop/Views/GridGeometry.swift`，与 MarqueeSelection 同文件）

```swift
enum RangeSelection {
    /// displayed 顺序中 from...to 之间的全部 id（含两端）；任一不存在则返回空。
    static func range(from: String, to: String, in orderedIDs: [String]) -> Set<String>
}
```

- `from` / `to` 任一不在 `orderedIDs` 中 → 返回空集合（调用方兜底）。
- 相等 → 仅含该 id 的单元素集合。

### 2. ViewModel（`PhotoLibraryViewModel.swift`）

- 新增私有状态：`private var selectionAnchor: String?`
  （不发布：无 UI 直接消费锚点，只参与点击路径计算）。
- 新增方法（供网格单击调用，替代 `toggleSelection` 的直接调用）：

```swift
/// 网格单击选中（Finder 风格）：
/// - 普通点击：toggle（维持现状），锚点 = 该张
/// - Shift 点击且锚点有效且不同张：选中集 = 锚点...该张的区间（替换），锚点不变
/// - Shift 点击且锚点 == 该张：选中集收缩为 {该张}，锚点不变
/// - Shift 点击但无锚点/锚点已不在当前列表：选中集 = {该张}，锚点 = 该张
func clickSelection(_ photo: PhotoItem, shift: Bool)
```

- `selectPhotoIDs(_:additive:)` 增加锚点维护：
  - 非加选：锚点 = 新选中集按 `displayedPhotos` 顺序的第一张（新选中集为空则 nil）
  - 加选（Shift 框选）：锚点不变

### 3. 视图（`PhotoGridView.swift`）

- `GridCell` 单击回调改传 Shift 状态：
  `onSingleTap: { library.clickSelection(photo, shift: NSEvent.modifierFlags.contains(.shift)) }`
- 手势结构不变（双击打开 / 单击选择的现有 onTapGesture 组合不动）。

### 4. 已知简化（记录在案，不实现）

- 全选 / 反选 / 详情空格等其他选中入口不更新锚点。锚点过期时 Shift 点击
  落入「锚点已不在当前列表」兜底（仅选中被点张），不会产生错误状态。

## 测试（TDD，仓库新惯例）

新增 `FrameScoopTests/RangeSelectionTests.swift`：

| 用例 | 输入 | 期望 |
| --- | --- | --- |
| 正向区间 | from=2nd, to=5th | 2nd...5th 全部 |
| 反向区间 | from=5th, to=2nd | 2nd...5th 全部（无序 Set 比较） |
| 同一张 | from==to | 仅该 id |
| from 不存在 | from 不在列表 | 空集合 |
| to 不存在 | to 不在列表 | 空集合 |
| 相邻两张 | from=2nd, to=3rd | 两张 |
| 空列表 | 空 orderedIDs | 空集合 |

## 验证

1. 新测试红 → 实现 → 绿（TDD）。
2. 既有 17 个测试不回归。
3. `xcodebuild build` 通过。
4. 运行时手测（缩略图区域）：
   - 普通点击：toggle 不变；
   - 点击 A → Shift 点击 D：A-D 全选中；
   - 继续 Shift 点击 F：A-F 全选中（锚点仍 A）；
   - 点击 A → Shift 点击 A：收缩为仅 A；
   - 反向：点击 D → Shift 点击 A：A-D 全选中；
   - 框选后（非加选）Shift 点击：从框选首张扩展；
   - Shift 框选（加选）后 Shift 点击：锚点保持原普通点击锚点；
   - 连拍筛选开启时 Shift 区间按视觉顺序。

## 范围外

- 详情胶片条不支持 Shift 范围选择（保持现状）。
- 不改框选手势本身；不改双击打开行为。
