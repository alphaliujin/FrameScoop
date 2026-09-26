# 截屏筛选设计文档

日期：2026-09-26

## 目标

在右侧「智能筛选」边栏增加截屏筛选，支持**双向**：

- **只看截屏**——清理场景：全选后批量删除。
- **隐藏截屏**——选片场景：网格里只剩相机拍的照片。

## 判据（实测确定）

判定截屏有两条互相独立的来源，取**或**：

| 来源 | 判据 | 成本 | 实测结果 |
| --- | --- | --- | --- |
| 文件夹 | 文件头 `EXIF.UserComment == "Screenshot"` | 1.37 ms/张 | 387 张真实相机照片 **0 误报** |
| 照片库 | `PHAsset.mediaSubtypes.contains(.photoScreenshot)` | 0（枚举资产时顺带） | 系统权威字段 |
| 文件夹（补充） | 文件名前缀匹配 | 0 | 覆盖第三方工具 |

### 判据一：EXIF UserComment（权威）

macOS 系统截屏（⌘⇧3 / ⌘⇧4 / `screencapture`）在写出的 PNG 里嵌入
`EXIF.UserComment = "Screenshot"`，同时 XMP 里冗余存一份 `exif:UserComment`。

实测证据（`CGImageSourceCopyPropertiesAtIndex` 读取）：

| 样本 | 回读结果 |
| --- | --- |
| 系统截屏 PNG | `"Screenshot"` |
| 同一截图经 sips 转存为 JPEG | `"Screenshot"`（穿透格式转换） |
| ImageIO 生成的无元数据 PNG | `nil`（无误报） |
| 佳能相机 JPEG × 387 张 | 全部 `nil`（无误报） |

**该判据不依赖文件名**，因此用户把 `截屏2026-09-26.png` 改名成 `DSC_0001.jpg` 依然能识别。
标记在中文系统下实测仍为英文 `"Screenshot"`，不随系统语言本地化。

匹配方式：**大小写不敏感的全等比较**（`"Screenshot"`），不做子串匹配。

### 判据二：文件名前缀

覆盖不写 UserComment 标记的第三方工具。**前缀匹配**（非子串）：

```
截屏    屏幕截图    截图
Screenshot    Screen Shot
Snipaste      CleanShot      Shottr
```

用前缀而非子串：子串会让 `我的截图旅行.jpg` 这类文件名误命中。

### 已知缺口（设计上接受）

导出的 iOS 截屏存成 `IMG_1234.PNG` 时，其 EXIF（`Make=Apple`、`Model=iPhone`）
与 iPhone 正常拍摄的照片完全一致，**没有可区分的元数据**，会被漏掉。
照片库来源的 iOS 截屏由 `mediaSubtypes` 覆盖，不受此缺口影响。

### 被否决的方案

- **PNG + 无相机 EXIF 的宽启发式**：会把导出的 PNG 设计图、网图误判为截屏。
- **`mdls` / `kMDItemIsScreenCapture`**：`mdls` 每张要起一个 shell 进程（~50–100 ms/张，
  比头读取贵 50 倍）；且实测在 Spotlight 已索引位置也读不到该属性。
- **Vision / ML 判定**：成本高数个量级，且「是不是屏幕内容」本身没有可靠特征。

## 时机与持久化

- **照片库来源**：枚举资产时直接读 `mediaSubtypes`，加载即完成，无需扫描。
- **文件夹来源**：文件夹加载后启动独立后台 Task 扫全部文件头，结果**流式**填入视图模型。
- **不落盘、不做 mtime 缓存**：每次文件夹加载重新扫一遍，约 4 秒 / 3000 张。

不持久化的理由：现有 `PhotoAnalysisStore` 的 mtime 失效逻辑是为**计算型**筛选造的
（dHash 要解码像素、Vision 要跑神经网络，重算以分钟计，故必须缓存）。截屏判定是
**元数据型**：只读文件头，不碰像素，量级差两个数量级。为省 4 秒而复用那套缓存，
等于引入一整类失效 bug（文件被替换、mtime 精度、跨版本迁移）来换取可忽略的收益。
**代价不对称时，不复用抽象。**

同理，扫描任务**不用** task group 并发：1.37 ms/张 的顺序 I/O 已足够快，
16 路并发带来的调度复杂度换不回可感知的收益。顺序扫 + 每批回主线程刷新即可。

## 设计

### 1. 模型（`FrameScoop/Models/ScreenshotFilter.swift`，新建）

```swift
/// 截屏筛选三态。三态天然互斥——避免现有 showsBlurFilter/showsBurstFilter
/// 那套「两个 didSet 互相置 false」的互斥写法（该模式在三个筛选上已显冗余）。
enum ScreenshotFilter: String, CaseIterable {
    case off       // 不过滤
    case only      // 只看截屏（清理场景）
    case exclude   // 隐藏截屏（选片场景）
}

/// 分段控件标签
var label: String {
    switch self {
    case .off:     return "全部"
    case .only:    return "只看截屏"
    case .exclude: return "隐藏截屏"
    }
}
```

### 2. 检测服务（`FrameScoop/Services/ScreenshotDetectionService.swift`，新建）

```swift
enum ScreenshotDetectionService {
    /// 文件名前缀判据（零 I/O，纯函数，可单测）
    static func matchesFilename(_ name: String) -> Bool

    /// 文件头判据：EXIF UserComment 是否为 "Screenshot"（~1.4 ms/张）
    /// 用 CGImageSource 只读元数据，不解码像素；任何读取失败一律返回 false。
    static func hasScreenshotMarker(at url: URL) -> Bool

    /// 综合判定：文件名命中 或 文件头带标记
    static func isScreenshot(name: String, url: URL) -> Bool
}
```

`hasScreenshotMarker` 走 `CGImageSourceCreateWithURL` + `CGImageSourceCopyPropertiesAtIndex`，
从 `kCGImagePropertyExifDictionary` 取 `kCGImagePropertyExifUserComment`。
注意不要读 TIFF 字典——`Make`/`Model` 在那里，容易误取。

### 3. 照片库服务（`PhotosLibraryService.swift`）

`loadAllPhotos()` 改为同时返回截屏资产 id 集合，复用同一次枚举：

```swift
func loadAllPhotos() async -> (items: [PhotoItem], screenshotIDs: Set<String>)
```

`makeItem` 之外增加一行判定：`asset.mediaSubtypes.contains(.photoScreenshot)`
→ 收集 `"ph:" + localIdentifier`。

调用点仅 1 处（`PhotoLibraryViewModel.swift:625`）。

### 4. 视图模型（`PhotoLibraryViewModel.swift`）

新增状态：

```swift
@Published var screenshotFilter: ScreenshotFilter = .off {
    didSet { rebuildDisplayedPhotos() }
}
/// 截屏 id 集合（唯一真源；PhotoItem 不加字段）
@Published private(set) var screenshotPhotoIDs: Set<String> = []
/// 是否正在扫描文件夹（驱动边栏进度文案）
@Published private(set) var isScreenshotScanning: Bool = false
```

`PhotoItem` **不加字段**：文件夹来源的值在构造时未知，加 `Bool` 会把 unknown 写成
false（撒谎），加 `Bool?` 又要在扫描后回写数组元素（O(n) 索引查找）。沿用
`blurryPhotoIDs` 那套 VM `Set` 作为唯一真源，与既有三个筛选一致。

`rebuildDisplayedPhotos()` 末尾追加过滤，与 `showsBlurOnly` / `showsEyeClosedOnly` /
`showsSelectedOnly` **正交可叠加**：

```swift
switch screenshotFilter {
case .off:     break
case .only:    result = result.filter { screenshotPhotoIDs.contains($0.id) }
case .exclude: result = result.filter { !screenshotPhotoIDs.contains($0.id) }
}
```

**扫描任务**（`scanScreenshots()`）：

- 触发点与 `precomputeAnalysis()` 一致：照片 id 集合变化时、以及同 id 集合下
  mtime 变化时（原地替换文件的情形）。
- **入口先剪枝**：`screenshotPhotoIDs` 只保留当前列表中的 id（两个来源都要，
  否则切节点后残留旧 id 会让「只看截屏」滤出错项）。
- 照片库来源：不扫文件。改为在加载路径（`PhotoLibraryViewModel.swift:630`
  `self.photos = items` 处）把 `loadAllPhotos()` 返回的集合直接赋给
  `screenshotPhotoIDs`。
- 文件夹来源：`Task.detached` 顺序遍历 `.folder` 项，每 64 张回主线程合并一次；
  自有 task 句柄 + token，切文件夹时 cancel。
- 扫描只读文件头，**不**复用 `precomputeTask`（后者含检查点存盘、批量落库等
  仅为持久化服务的机制，此处一概不需要）。

### 5. 边栏（`FilterSidebarView.swift`）

在「智能筛选」section 内、三个 Toggle 之后追加：

```swift
Picker("截屏", selection: $library.screenshotFilter) {
    ForEach(ScreenshotFilter.allCases, id: \.self) { f in
        Text(f.label).tag(f)
    }
}
.pickerStyle(.segmented)
.help("按 EXIF 标记与文件名识别截屏；「只看」用于清理，「隐藏」用于选片")

// 计数兼作扫描进度反馈
Text(library.isScreenshotScanning
     ? "正在识别截屏…已发现 \(library.screenshotPhotoIDs.count) 张"
     : "共 \(library.screenshotPhotoIDs.count) 张截屏")
    .font(.caption)
    .foregroundStyle(.secondary)
```

### 6. 缩略图角标（`PhotoGridView.swift`）

`GridCell` 与 `PhotoBadges` 各加一个 `isScreenshot: Bool`，并**并入 `GridCell.==`**
（漏掉会让 `.equatable()` 跳过 body，角标不刷新）。

符号用 `display`（SF Symbol 实测存在；`screenshot` **不存在**，会静默渲染成空白）。
底色用**中性灰**而非红/黄：

> 红/黄在现有语义里编码「严重程度」（全模糊=红、部分模糊=黄）。
> 截屏不是质量问题而是**类别**，借用红黄会让用户以为截屏"有问题"。
> 中性灰把「类别标记」与「问题标记」在视觉语汇上分开。

**角标不做筛选门控**——与 `blurOn` / `eyeClosedOn` 的写法不同，这里是刻意的：

> 门控条件 `screenshotFilter != .off` 在三态筛选下是自相矛盾的。
> `.only` 模式下可见的每一张都是截屏，门控恒真 → 每格都带角标，纯冗余；
> `.exclude` 模式下截屏全被隐藏，门控恒假 → 角标永不出现。
> **也就是说门控会让角标在它本该有用的场景里从不出现。**
>
> 现有 blur/eye 的门控之所以成立，是因为它们不改变可见集合，角标始终编码
> 「严重程度」这一额外信息。截屏是布尔类别，没有这层额外信息。
> 角标唯一有用的场景是**默认（全部）的混合视图**：打开文件夹即可一眼看出
> 哪些是截屏，不必切换筛选模式。故常显。

### 7. 不改动的部分

- **`PhotoAnalysisStore`** 不动（理由见「时机与持久化」）。
- **`PhotoItem`** 不动。
- 既有三个筛选的互斥逻辑不动。
- **`PhotoDetailView` 行为不动**，但**有一行机械改动**：`PhotoBadges` 的
  `isScreenshot` 是必填参数，详情视图是该结构体的第二个调用点
  （`PhotoDetailView.swift:101`），不补参数会编译失败。补的值与网格一致，
  详情视图因此也显示截屏角标——这与它已镜像连拍编号/模糊/闭眼角标的行为一致。

## 测试（TDD）

新增 `FrameScoopTests/ScreenshotDetectionTests.swift`。

判据可写即可测：ImageIO 既能**读**也能**写** `EXIF.UserComment`（已实测往返：
写入 `"Screenshot"` → 回读 `"Screenshot"`；不写 → 回读 `nil`），
因此测试现场用 `CGImageDestination` 造正反样本即可，**不需要二进制夹具入库**。

| 用例 | 输入 | 期望 |
| --- | --- | --- |
| 文件头带标记 | 现场生成 PNG，写 `UserComment="Screenshot"` | `true` |
| 文件头无标记 | 现场生成 PNG，不写元数据 | `false` |
| 大小写 | 写 `"screenshot"` | `true` |
| 近似值 | 写 `"Screenshots"` | `false`（全等而非子串） |
| 文件不存在 | 不存在的路径 | `false`（不崩溃） |
| 文件名·系统中文 | `截屏2026-09-26 14.30.00.png` | `true` |
| 文件名·系统英文 | `Screenshot 2026-09-26 at 2.30.00 PM.png` | `true` |
| 文件名·旧版英文 | `Screen Shot 2026-09-26 at 2.30.00 PM.png` | `true` |
| 文件名·微信 | `微信截图_20260926143000.png` | `true` |
| 文件名·QQ | `QQ截图20260926143000.png` | `true` |
| 文件名·Snipaste | `Snipaste_2026-09-26_14-30-00.png` | `true` |
| 文件名·相机 | `2T9A3048.JPG` | `false` |
| 文件名·苹果原图 | `IMG_1234.HEIC` | `false`（已知缺口） |
| 文件名·子串陷阱 | `我的截图旅行.jpg` | `false`（前缀匹配） |
| 组合判定 | 文件名不匹配但头带标记 | `true` |

## 验证

1. 新测试红 → 实现 → 绿（TDD）。
2. 既有测试不回归。
3. `xcodebuild build` 通过。
4. 运行时手测：
   - 打开测试文件夹（含真实截屏与相机照片）；
   - 扫描期间边栏计数递增；
   - 「只看截屏」→ 只剩截屏；「隐藏截屏」→ 截屏消失；「全部」→ 恢复；
   - 与「只显示选中」「只显示模糊」同开时取交集、不互相清空；
   - 切到照片库节点：iOS 截屏被正确标记（`mediaSubtypes` 路径）；
   - 角标为灰色 `display` 图标，与红/黄问题角标视觉可分。

## 范围外

- 不为文件夹来源的 iOS 截屏做猜测性判定（已知缺口，见上）。
- 不做截屏的自动删除、自动排除或按截屏归档。
- 不改 `PhotoAnalysisStore` 的存储格式。
- 不为截屏筛选提供阈值/灵敏度调节（判据是布尔事实，没有可调的连续量）。
