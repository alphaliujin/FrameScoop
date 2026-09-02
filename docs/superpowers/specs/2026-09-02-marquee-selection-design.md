# 图片框选(Marquee Selection)设计(2026-09-02)

## 目标

在图片网格中按住鼠标拖动出一个方框,框内(含部分相交)的图片被选中。照片 App 风格:任意位置可起拖、单击不拖仍选单张、拖拽中实时更新选中。

## 现状

- 网格:`PhotoGridView` → ScrollView → GeometryReader → `FlowLayout` 或 `BurstFlowLayout`(LazyVStack 行 → HStack cell;cell 高 = thumbnailSize.cellSize,宽 = max(cellSize × aspectRatio, 40),行距/列距 spacing=4,内容 .padding(4))。
- 两种布局的行计算均为纯函数:`computeRows()` 由 availableWidth 确定性算出每行照片列表(PhotoGridView.swift:306-422)。
- 选中:`PhotoLibraryViewModel.selectedPhotoIDs: Set<String>`,已有 toggleSelection / selectAll / deselectAll / invertSelection。
- cell 手势:双击打开、单击 toggle、右键菜单;空白区无手势。macOS 上 ScrollView 不消费鼠标拖拽(仅滚轮/触控板滚动),拖拽手势与滚动不冲突。

## 方案 A:SwiftUI DragGesture + 确定性几何命中(已批准)

### 1. 共享几何函数(小重构)

把两种布局的行计算提为共享纯函数,返回每张图的 content frame:

```swift
struct GridPhotoFrame { let photo: PhotoItem; let frame: CGRect }
enum GridGeometry {
    // 普通流式;availableWidth 与 FlowLayout 一致
    static func flowFrames(items: [PhotoItem], rowHeight: CGFloat, spacing: CGFloat, availableWidth: CGFloat) -> [GridPhotoFrame]
    // 连拍分段(与 BurstFlowLayout 逐行逻辑一致,连拍组独占行、末行留白)
    static func burstFrames(segments: [BurstSegment], cellWidth: (PhotoItem) -> CGFloat, rowHeight: CGFloat, spacing: CGFloat, availableWidth: CGFloat) -> [GridPhotoFrame]
}
```

`FlowLayout` / `BurstFlowLayout` 的 `computeRows()` 改为内部调用该共享函数(仅取 photo 顺序),保证显示布局与命中几何**同一份代码**,任何布局调整自动同步。

### 2. 手势与状态

- `PhotoGridView` 新增状态:`@State marquee: MarqueeState?`(startPoint、currentPoint、isAdditive)。
- 手势挂在网格内容容器(ScrollView 内、包住 LazyVStack 的容器视图)上:`.gesture(DragGesture(minimumDistance: 3))`:
  - `onChanged`:首次事件进入框选模式,记录起点;更新 currentPoint;实时算命中并应用选中。
  - `onEnded`:应用最终命中集合,清空 marquee 状态。
- 坐标:手势挂内容容器 → 拖拽坐标天然就是内容坐标,无需滚动偏移换算(内容容器同时是 GeometryReader,顺手取 availableWidth)。
- 修饰键:拖拽中读 `NSEvent.modifierFlags.contains(.shift)` → 加选模式(isAdditive,框选前不清空)。
- cell 单击与框选冲突处理:拖拽 ≥3pt 后框选激活,cell 的 `onTapGesture(count:1)` 不触发(系统手势仲裁:移动后 tap 失败);点击不放鼠标即释放仍走单击选单张。

### 3. 命中与选中应用

- 框选矩形:起点与当前点的标准化 rect,裁剪到内容边界。
- 命中:`frame.intersects(marqueeRect)`(部分相交即选中)。
- `PhotoLibraryViewModel` 新增:
  ```swift
  func selectPhotoIDs(_ ids: Set<String>, additive: Bool)
  // additive=false: selectedPhotoIDs = ids
  // additive=true:  selectedPhotoIDs.formUnion(ids)
  ```
- 框选无命中且非加选 → 清空选择(照片 App 惯例)。
- 过滤器(只显示模糊/闭眼/选中/连拍)作用于显示集:框选只对当前显示的图生效,与现有 displayedPhotos / displayedBurstSegments 语义一致。
- 实时更新:onChanged 每步调用 selectPhotoIDs(几何纯计算,O(n) 遍历,网格万级图片无压力)。

### 4. 框选视觉

- 拖拽中在网格内容上 overlay:
  ```swift
  Rectangle()
      .stroke(Color.accentColor, lineWidth: 1)
      .background(Color.accentColor.opacity(0.15))
      .frame(width: rect.width, height: rect.height)
      .position(rect.center)
  ```
- 松开即消失;`.allowsHitTesting(false)`。

### 5. 明确不做(MVP)

- 边缘自动滚动(拖到可视区外自动滚) — 后续迭代加。
- ESC 取消、Command+拖=反选 — 后续按需。
- 详情页/胶片条不做框选。

## 改动文件

- `FrameScoop/Views/PhotoGridView.swift`:marquee 状态 + 手势 + overlay;FlowLayout/BurstFlowLayout 改用共享几何。
- `FrameScoop/ViewModels/PhotoLibraryViewModel.swift`:新增 `selectPhotoIDs(_:additive:)`。

## 验证

1. 构建通过;运行 app:
   - 普通网格:空白处起拖、图片上起拖均出框;框内(含擦边)图选中,框外清空;Shift+拖加选;单击仍选单张;双击仍开详情。
   - 连拍视图:同上,连拍分组行布局下命中正确(独占行/末行留白)。
   - 缩放窗口换行后框选命中仍与显示一致(共享几何保证)。
   - 过滤(只显示模糊/闭眼/选中)时只框选中显示集。
   - 拖出可视区:无自动滚动,矩形裁剪到边界,行为正常。
2. 深浅色模式各过一遍(描边/填充颜色跟随 accent)。

## 权衡与已知差异

- 与照片 App 差异:暂无边缘自动滚动、暂无 ESC 取消。
- 拖拽起点在已选中图上时仍可框选(照片 App 同)。
- 性能:每次 onChanged O(n) 几何遍历;n 巨大(数万)时如卡顿再优化(空间索引),当前量级无压力。
