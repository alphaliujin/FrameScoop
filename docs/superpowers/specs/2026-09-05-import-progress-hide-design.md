# 图片数据导入进度条：完成后隐藏设计

日期：2026-09-05

## 目标

侧边栏底部的「图片数据导入」进度条只在导入（预计算连拍 dHash + 人脸模糊分）过程中显示；
导入完成后先短暂展示完成态（绿色对勾 + 100%），约 1 秒后淡出隐藏。

## 现状

- `SidebarView.swift:44` 显示条件为 `precomputeTotal > 0`，注释（42-43 行）明确保留
  「算完后不消失」的旧行为。
- `PhotoLibraryViewModel` 已有 `@Published isPrecomputing`：有照片需要计算时为 `true`，
  计算结束（1194 行）或全部命中缓存时（1132 行）为 `false`。
- 切文件夹由 `photos.didSet` 同步触发 `precomputeAnalysis()`，用 `precomputeToken`
  防旧任务串扰；收尾闭包已带 token 校验。

## 设计

### 1. ViewModel（`PhotoLibraryViewModel.swift`）

- 新增 `@Published private(set) var showPrecomputeSummary = false`，表示「完成态」是否展示中。
- `precomputeAnalysis()` 入口（`guard !photos.isEmpty` 之前）置 `showPrecomputeSummary = false`：
  空文件夹、切文件夹、重算均立即重置，完成态不会残留到新文件夹。
- 收尾闭包（token 匹配后）：
  - 置 `showPrecomputeSummary = true`；
  - 派发延迟任务，1 秒后置回 `false`，带 `token == precomputeToken` 校验——
    期间若切了文件夹，token 已递增，旧延迟不会误藏新文件夹的进度。
- 全部命中缓存（`toCompute` 为空）时 `isPrecomputing` 与 `showPrecomputeSummary` 均为 `false`，
  进度条不出现，符合「只在导入过程中显示」。

### 2. 视图（`SidebarView.swift:42-65`）

- 显示条件改为：
  `(library.isPrecomputing || library.showPrecomputeSummary) && library.precomputeTotal > 0`
- 完成态下 `isPrecomputing == false`，现有绿色对勾逻辑（53-57 行）保持不变。
- 容器加 `.transition(.opacity)` 与 `.animation(..., value: library.showPrecomputeSummary)`
  实现淡出。
- 更新 42-43 行注释，描述新行为。

### 3. 行为矩阵

| 场景 | 进度条表现 |
| --- | --- |
| 导入进行中 | 显示进度，无对勾 |
| 导入完成 | 对勾 + 100% 停留约 1 秒 → 淡出隐藏 |
| 切到新文件夹（有新照片待算） | 立即显示新文件夹进度 |
| 切到新文件夹（全部命中缓存） | 不显示 |
| 空文件夹 | 不显示 |

## 验证

1. `xcodebuild build` 编译通过。
2. 运行时检查（沿用既有间接验证方式）：
   - 选中一个未导入过的文件夹：进度条出现 → 完成后对勾短暂停留 → 淡出；
   - 切回已缓存文件夹：进度条不出现；
   - 导入中途切文件夹：进度立即切换，无旧完成态残留。

## 范围外

- 不改变预计算本身的计算逻辑、存盘节拍与并发参数。
- 不改动 `PhotoGridView` / `PhotoDetailView` 中的加载 `ProgressView`（与导入进度无关）。
