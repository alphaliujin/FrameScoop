# 导入进度条完成后隐藏 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 侧边栏「图片数据导入」进度条只在导入过程中显示；完成后绿色对勾 + 100% 停留约 1 秒再淡出隐藏。

**Architecture:** 视图模型新增 `showPrecomputeSummary` 发布状态（复用既有 `precomputeToken` 防串扰模式做延迟隐藏），视图把显示条件从 `precomputeTotal > 0` 改为「导入中或完成态」，并用 SwiftUI transition 淡出。不改预计算逻辑。

**Tech Stack:** Swift 5.9 / SwiftUI / macOS 14.0+，无新增依赖，不新增文件（无需 `xcodegen generate`）。

**Spec:** `docs/superpowers/specs/2026-09-05-import-progress-hide-design.md`

## Global Constraints

- 部署目标 macOS 14.0，Swift 5.9，手写 Info.plist（勿改）。
- 注释用中文，提交信息用中文，风格与现有代码一致。
- 不新增/删除任何文件；改动仅在 `PhotoLibraryViewModel.swift` 与 `SidebarView.swift`。
- 项目无单元测试目标：验证 = `xcodebuild` 编译 + 运行时观察（DEBUG 日志 + 肉眼/截图确认侧栏）。
- 构建命令统一使用既有 DerivedData 路径：
  `xcodebuild -project FrameScoop.xcodeproj -scheme FrameScoop -configuration Debug -derivedDataPath build/DerivedData build`
- 运行 app：`open build/DerivedData/Build/Products/Debug/FrameScoop.app`
  直接跑 binary 抓 DEBUG 日志：`build/DerivedData/Build/Products/Debug/FrameScoop.app/Contents/MacOS/FrameScoop 2>&1`（沙盒 app 需 `open` 启动才有 TCC 授权；直接跑 binary 仅用于看日志）。
- 改动前工作区应干净：上一次提交为 `1bc298d`（设计文档）。

---

### Task 1: ViewModel 增加「完成态」发布状态

**Files:**
- Modify: `FrameScoop/ViewModels/PhotoLibraryViewModel.swift`（231 行后新增字段；`precomputeAnalysis()` 入口与收尾闭包 ~1080-1086、1192-1200）

**Interfaces:**
- Consumes: 既有 `@Published private(set) var isPrecomputing`、`precomputeToken`（均存在于 229、1071 行）。
- Produces: `@Published private(set) var showPrecomputeSummary: Bool`——Task 2 的视图显示条件依赖此字段。

- [ ] **Step 1: 新增发布字段**

在 `PhotoLibraryViewModel.swift:231`（`precomputeTotal` 声明之后）插入：

```swift
    /// 完成态是否展示中：算完后置 true（对勾 + 100% 停留约 1 秒），延迟任务到期置 false。
    /// 切文件夹/清空时在 precomputeAnalysis 入口重置为 false。
    @Published private(set) var showPrecomputeSummary = false
```

- [ ] **Step 2: 入口重置完成态**

在 `precomputeAnalysis()`（1080 行）函数体最开头、`let photos = self.photos` 之前插入：

```swift
        // 入口即重置完成态：空文件夹、切文件夹、重算都不得残留上一轮的完成标记
        showPrecomputeSummary = false
```

- [ ] **Step 3: 收尾置位 + 延迟隐藏**

在收尾闭包（1192-1200 行）内、`self.isPrecomputing = false` 之后、`if self.showsBurstFilter ...` 之前插入：

```swift
                self.showPrecomputeSummary = true
                // 完成态停留约 1 秒后隐藏；期间切文件夹 token 已递增，旧延迟任务自然失效，
                // 不会误藏新文件夹的进度（新文件夹的完成态由新 token 的新延迟任务负责）。
                let doneToken = token
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard doneToken == self.precomputeToken else { return }
                    self.showPrecomputeSummary = false
                }
```

注意：`Task { @MainActor in ... }` 位于已解包的 `self` 作用域内，捕获 `self` 最长 1 秒，无循环引用（VM 为 app 生命周期单例）。

- [ ] **Step 4: 编译验证**

Run: `xcodebuild -project FrameScoop.xcodeproj -scheme FrameScoop -configuration Debug -derivedDataPath build/DerivedData build`
Expected: `** BUILD SUCCEEDED **`，无新增 warning。

- [ ] **Step 5: 提交**

```bash
git add FrameScoop/ViewModels/PhotoLibraryViewModel.swift
git commit -m "feat: 视图模型新增导入完成态状态（showPrecomputeSummary）"
```

---

### Task 2: 侧边栏显示条件改为「导入中或完成态」+ 淡出

**Files:**
- Modify: `FrameScoop/Views/SidebarView.swift:42-65`（显示条件、注释、transition）

**Interfaces:**
- Consumes: Task 1 的 `library.isPrecomputing`、`library.showPrecomputeSummary`、`library.precomputeTotal`。
- Produces: 无（本任务为终端行为变更）。

- [ ] **Step 1: 改显示条件与注释**

把 `SidebarView.swift:42-44` 的注释与条件改为：

```swift
                // 图片数据导入进度：文件夹加载后自动预计算连拍 dHash + 人脸模糊分。
                // 只在导入过程中显示；完成后绿色对勾 + 100% 停留约 1 秒再淡出隐藏。
                // 全部命中缓存或空文件夹时不出现。切文件夹随新数据重置。
                if (library.isPrecomputing || library.showPrecomputeSummary) && library.precomputeTotal > 0 {
```

- [ ] **Step 2: 加淡出动画**

在 64 行 `.padding(.vertical, 6)` 之后（VStack 结束 `}` 之后）加：

```swift
                    .transition(.opacity)
```

并把 `.animation` 修饰符挂在 safeAreaInset 的外层 `VStack(spacing: 0)`（41 行，`addFolderButton` 之前，与外层 `}` 同级）上：

```swift
        .animation(.easeOut(duration: 0.25), value: library.showPrecomputeSummary)
```

（附着点：`.safeAreaInset` 内容根 VStack 的末尾、`addFolderButton` 属性之前，注意与 `.padding()` 等已有修饰符的同级缩进。）

- [ ] **Step 3: 编译验证**

Run: `xcodebuild -project FrameScoop.xcodeproj -scheme FrameScoop -configuration Debug -derivedDataPath build/DerivedData build`
Expected: `** BUILD SUCCEEDED **`，无新增 warning。

- [ ] **Step 4: 运行时验证（三场景）**

启动：`open build/DerivedData/Build/Products/Debug/FrameScoop.app`

1. **导入中显示**：选中一个尚未导入过的文件夹（无磁盘缓存的），确认侧边栏底部出现「图片数据导入：x / xxx 张」进度条且无绿色对勾。
2. **完成后淡出**：等导入完成，确认进度条变为对勾 + 100%，约 1 秒后淡出消失、区域恢复为只剩「添加文件夹」按钮。可直接跑 binary 抓 `#if DEBUG` 日志辅助判断（`[PRE] progress` 行在导入中周期性出现，结束后不再新增）。
3. **切文件夹**：a) 切到一个全部命中缓存的文件夹，确认进度条不出现；b) 在导入中途切换到另一个未导入文件夹，确认进度立即切换为新文件夹进度、无旧文件夹完成态残留。

如可视确认不便，可用 `screencapture -x /tmp/fs-sidebar.png` 截图后查看（若终端无录屏权限则跳过截图，仅靠用户肉眼确认）。

- [ ] **Step 5: 提交**

```bash
git add FrameScoop/Views/SidebarView.swift
git commit -m "feat: 导入进度条完成后短暂显示完成态并淡出隐藏"
```

---

## Self-Review 结论

- **Spec 覆盖**：spec 第 1 节（VM 字段/入口重置/收尾延迟/token 校验）→ Task 1 三处代码；spec 第 2 节（条件/transition/注释）→ Task 2；spec 行为矩阵五场景 → Task 2 Step 4 覆盖（导入中、完成、切新文件夹、切缓存文件夹、空文件夹由 `precomputeTotal > 0` 条件天然覆盖）。
- **占位符**：无 TBD/TODO；所有代码步骤含完整代码。
- **类型一致性**：`showPrecomputeSummary` 在 Task 1 定义、Task 2 引用，名称一致；`doneToken` 仅 Task 1 内部使用。
