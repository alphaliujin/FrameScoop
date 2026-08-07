# FrameScoop

纯原生 macOS 图片浏览器 —— 按文件夹看图，界面模仿“照片”App。
基于 SwiftUI 开发，最低系统版本 **macOS 14 Sonoma**，支持 **Apple Silicon 与 Intel**。

> 技术栈：SwiftUI · AppKit · ImageIO · CoreGraphics · Foundation
> 禁止 Electron / Flutter 等跨端框架，100% 苹果原生 API，无任何付费第三方 SDK。

---

## 一、功能特性

| 模块 | 说明 |
| --- | --- |
| 文件夹浏览 | 侧边栏管理多个图片文件夹，重启后通过安全作用域书签保留访问权限 |
| 照片图库 | 侧边栏常驻「照片图库」节点，经 Photos.framework 读取系统照片库（含 iCloud 同步照片）；支持浏览、详情、元数据、移到「最近删除」、导出、复制 |
| 照片网格 | 自适应列数网格，模仿“照片”App 内容区；支持排序、缩略图尺寸切换 |
| 沉浸查看 | 双击进入毛玻璃全屏查看，支持双指缩放、拖拽平移、上下张导航、底部胶片条 |
| 元数据面板 | 显示像素尺寸、色彩空间、拍摄设备、EXIF（光圈/ISO/焦距/快门等） |
| 文件监控 | 文件夹变化自动刷新（DispatchSource，无需轮询） |
| 废纸篓 | 选中图片可移到废纸篓（原生 trashItem，可恢复） |
| 智能筛选 | 右侧筛选边栏：连拍识别（dHash 相似度分组）、人脸模糊检测（Vision + Laplacian）、闭眼检测（Vision 人脸 landmarks）；分析结果跨会话持久化（mtime 未变即复用磁盘缓存） |

---

## 二、权限与安全

遵循最小权限原则，**仅申请 3 项沙盒权限**，不使用内核扩展：

```xml
com.apple.security.app-sandbox              = true   <!-- 启用沙盒 -->
com.apple.security.files.user-selected.read-write = true <!-- 用户授权的文件读写 -->
com.apple.security.files.bookmarks.app-scope = true <!-- 安全作用域书签持久化 -->
```

- 不声明网络权限（应用完全离线；iCloud 照片由系统照片库守护进程按需下载，非应用直接联网）
- 通过 Photos.framework 读取系统照片库（含 iCloud 同步照片）：macOS 沙盒下经 TCC 授权访问，声明 `NSPhotoLibraryUsageDescription`，无需额外沙盒权限项
- 所有命令行调用（`mdls`）均通过 `ShellExecutor` 做异常捕获与超时保护，**绝不因 shell 失败而崩溃**

---

## 三、项目目录结构

```
FrameScoop/
├── project.yml                    # XcodeGen 工程描述（生成 .xcodeproj）
├── FrameScoop.xcodeproj           # 由 XcodeGen 生成（首次构建时自动产出）
├── FrameScoop/
│   ├── FrameScoopApp.swift        # 应用入口、窗口场景、命令菜单
│   ├── Info.plist                 # 应用配置（最低系统、文档类型等）
│   ├── FrameScoop.entitlements    # 沙盒权限声明
│   ├── Assets.xcassets/           # 资源目录（AccentColor 强调色）
│   ├── Resources/
│   │   └── AppIcon.icns           # App 图标（由 generate_icon.sh 生成，CFBundleIconFile 引用）
│   ├── App/
│   │   └── NotificationNames.swift        # 自定义通知名 + 菜单命令通知
│   ├── Models/                    # 数据模型层（纯值类型）
│   │   ├── PhotoItem.swift                # 单张图片
│   │   ├── PhotoFolder.swift              # 图片文件夹 + 书签
│   │   ├── FolderNode.swift               # 文件夹树节点（侧边栏展开）
│   │   ├── SortOption.swift               # 排序/方向/缩略图尺寸枚举
│   │   └── ImageMetadata.swift            # 富元数据
│   ├── ViewModels/
│   │   └── PhotoLibraryViewModel.swift    # 核心业务编排（@MainActor）
│   ├── Views/                     # 视图层（SwiftUI）
│   │   ├── ContentView.swift              # 主容器：SplitView + 详情覆盖层
│   │   ├── SidebarView.swift              # 侧边栏文件夹列表
│   │   ├── PhotoGridView.swift            # 自适应图片网格 + 工具栏
│   │   ├── PhotoThumbnailCell.swift       # 单格缩略图（异步加载）
│   │   ├── PhotoDetailView.swift          # 沉浸式查看（缩放/导航/胶片条）
│   │   ├── MetadataPanelView.swift        # 元数据信息面板
│   │   ├── FilterSidebarView.swift        # 右侧智能筛选边栏
│   │   ├── EmptyStateView.swift           # 空状态占位
│   │   └── SettingsView.swift            # 偏好设置窗口
│   ├── Services/                  # 服务层
│   │   ├── PhotoLoadService.swift         # 文件夹图片枚举加载
│   │   ├── PhotoLoader.swift              # 按 sourceKind 分派取图/取元数据
│   │   ├── PhotosLibraryService.swift     # Photos.framework 照片库读取
│   │   ├── ThumbnailCacheService.swift    # 内存+磁盘缩略图缓存
│   │   ├── FolderMonitorService.swift     # 文件系统事件监控
│   │   ├── MetadataService.swift          # 元数据读取（mdls 安全调用）
│   │   ├── BlurDetectionService.swift     # 人脸模糊 + 闭眼检测（Vision）
│   │   ├── BurstDetectionService.swift    # 连拍识别（dHash 相似度）
│   │   └── PhotoAnalysisStore.swift       # 分析结果持久化（dHash + blur）
│   └── Utilities/                 # 工具层
│       ├── ShellExecutor.swift            # 安全命令行执行（异常/超时）
│       ├── ThumbnailGenerator.swift       # ImageIO 缩略图降采样
│       ├── BookmarkStore.swift            # 安全作用域书签存取
│       └── SharingServiceHelper.swift     # NSSharingService 辅助
├── Scripts/                       # 构建发布脚本
│   ├── generate_icon.sh          # 生成 App 图标（FC.png -> .icns）
│   ├── generate_project.sh       # 生成图标 + Xcode 工程
│   ├── build.sh                  # 编译（Release/Debug）
│   ├── run.sh                    # Debug 构建并直接运行
│   ├── package_dmg.sh            # 打包可拖拽安装的 DMG
│   ├── notarize.sh               # 签名 + 公证 + 装订 + 去隔离
│   └── remove_quarantine.sh      # 清除 Gatekeeper 隔离属性
└── README.md
```

### 分层架构

```
┌─────────────────────────────────────┐
│  视图层 Views (SwiftUI)              │  ContentView / Sidebar / Grid / Detail / FilterSidebar
├─────────────────────────────────────┤
│  视图模型 ViewModels                  │  PhotoLibraryViewModel (@MainActor)
├─────────────────────────────────────┤
│  服务层 Services                     │  Load / Cache / Monitor / Metadata / Blur / Burst / PhotoAnalysisStore
├─────────────────────────────────────┤
│  工具层 Utilities                    │  ShellExecutor / ThumbnailGenerator / BookmarkStore / SharingServiceHelper
├─────────────────────────────────────┤
│  数据模型 Models                      │  PhotoItem / PhotoFolder / FolderNode / SortOption / ImageMetadata
└─────────────────────────────────────┘
```

### Assets 资源说明

工程仅含两类资源，均无第三方依赖：

| 资源 | 路径 | 说明 |
| --- | --- | --- |
| 强调色 | `Assets.xcassets/AccentColor.colorset/` | 浅色/深色模式各一套 sRGB 蓝色强调色，由 `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME` 引用 |
| App 图标 | `Resources/AppIcon.icns` | 由 `Scripts/generate_icon.sh` 生成：优先用项目根目录的 `FC.png`（缩放至 1024 + `sips` 各尺寸 + `iconutil` 打包）；无 `FC.png` 时回退到 Core Graphics 占位图。`Info.plist` 中 `CFBundleIconFile=AppIcon` 引用 |

> 替换图标：用同名 `FC.png` 覆盖项目根目录文件后，删除 `FrameScoop/Resources/AppIcon.icns` 并重新构建即可。
> 采用 `.icns` + `CFBundleIconFile` 而非 asset catalog 单尺寸 AppIcon，是为兼容不同 Xcode SDK 的资产编译器，保证图标稳定嵌入。

---

## 四、环境准备

### 必需
- macOS 14+ （本机为 macOS 26.5，向下兼容至 14）
- Xcode 15+（含 Command Line Tools）
- **XcodeGen**（免费开源工程生成工具，非付费 SDK）

### 安装 XcodeGen
```bash
brew install xcodegen
```

---

## 五、编译 / 本地测试 / 打包发布 —— 分步指南

### 步骤 1：生成工程并编译（Debug）

```bash
# 1.1 一键生成图标 + Xcode 工程
bash Scripts/generate_project.sh

# 1.2 编译 Debug（也可用 CONFIG=Release）
bash Scripts/build.sh

# 产物：build/DerivedData/Build/Products/Debug/FrameScoop.app
```

### 步骤 2：本地运行测试

```bash
# 2.1 构建 + 清除隔离 + 启动（推荐）
bash Scripts/run.sh

# 2.2 或手动打开
open "build/DerivedData/Build/Products/Debug/FrameScoop.app"
```

**手动功能验证清单：**
1. 启动后侧边栏点击 “添加文件夹”，选择一个含图片的目录
2. 主区显示图片网格，缩略图逐渐加载出来
3. 调整工具栏排序方式、缩略图大小，网格实时更新
4. 单击选中（左上角出现勾选），双击进入沉浸查看
5. 在查看视图：方向键切换上下张、双指缩放、拖拽平移、`i` 切换信息面板、`Esc` 退出
6. 把新图片拖入该文件夹，网格应自动刷新（文件监控生效）
7. 右键图片 → “移到废纸篓”，确认后从网格消失
8. 重启应用，文件夹仍在（书签持久化生效）
9. `⌘,` 打开偏好设置，切换默认排序 / 清除缓存

> 若本地未签名构建被 Gatekeeper 拦截：`bash Scripts/remove_quarantine.sh`

### 步骤 3：用 Xcode 调试（可选）

```bash
open FrameScoop.xcodeproj
# 选择 FrameScoop scheme → ⌘R 运行 / ⌘U 测试（预览 SwiftUI Canvas）
```

### 步骤 4：Release 打包

```bash
CONFIG=Release bash Scripts/build.sh
# 产物：build/DerivedData/Build/Products/Release/FrameScoop.app
```

打成分发包：
```bash
# 打成 zip 便于分发
cd build/DerivedData/Build/Products/Release
ditto -c -k --keepParent FrameScoop.app FrameScoop.zip
```

打成 DMG（推荐，可拖拽安装）：
```bash
# 自动构建 Release + 生成含 Applications 快捷方式的 .dmg
bash Scripts/package_dmg.sh
# 产物：build/FrameScoop.dmg（UDZO 压缩，已校验）
```
脚本会尝试设置 Finder 拖拽安装布局（app 与 Applications 左右排列）；无 GUI 环境下自动回退默认布局，不影响出包。

### 步骤 5：公证与去 Gatekeeper 拦截（需 Apple 开发者账号）

> 公证使应用在他人机器上首次打开时不被 Gatekeeper 拦截。

**5.1 准备签名身份与公证凭证**

- 在 Apple Developer 后台创建 “Developer ID Application” 证书并安装到钥匙串。
- 创建 App 专用密码：https://appleid.apple.com → 登录与安全 → App 专用密码。
- 一次性存储 notarytool 凭证：
  ```bash
  xcrun notarytool store-credentials frameScoop-notary \
    --apple-id you@example.com \
    --team-id XXXXXXXXXX \
    --password "xxxx-xxxx-xxxx-xxxx"
  ```

**5.2 编辑脚本配置**

打开 `Scripts/notarize.sh`，修改顶部配置区：
```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
NOTARY_PROFILE="frameScoop-notary"
```

**5.3 执行签名 + 公证 + 装订 + 去隔离**
```bash
bash Scripts/notarize.sh
```
脚本依次完成：代码签名（Hardened Runtime + Entitlements）→ 提交公证并等待 → 装订票据 → 清除隔离属性。

**5.4 验证公证结果**
```bash
spctl -a -vv -t exec "build/DerivedData/Build/Products/Release/FrameScoop.app"
# 期望输出：... accepted ... source=Notarized Developer ID
```

### 步骤 6：未公证构建的临时放行（给测试者）

若不签名直接分发，对方打开会提示 “无法验证开发者”，三种放行方式：

```bash
# 方式 A：清除隔离属性（推荐）
xattr -cr /path/to/FrameScoop.app

# 方式 B：右键 → 打开（系统会记住放行）

# 方式 C：本仓库脚本
bash Scripts/remove_quarantine.sh /path/to/FrameScoop.app
```

---

## 六、关键实现说明

### 1. 安全的命令行调用
`Utilities/ShellExecutor.swift` 是所有 shell 调用的唯一入口：
- 启动前校验可执行文件存在，避免 `NSInvalidArgumentException`。
- `try process.run()` 捕获启动异常，返回结构化 `ShellResult`，**永不抛出**。
- DispatchWorkItem 超时看门狗，子进程超时自动 `terminate()`。
- 唯一使用场景：`Services/MetadataService.swift` 调用 `/usr/bin/mdls` 读取 Spotlight 富元数据（EXIF），失败时静默降级为空值。

### 2. 内存友好的缩略图
`Utilities/ThumbnailGenerator.swift` 使用 `CGImageSourceCreateThumbnailAtIndex` 降采样，**不全量解码大图**，配合 `NSCache`（内存）+ 磁盘缓存，actor 做并发去重。

### 3. 沙盒下的持久文件夹访问
`Utilities/BookmarkStore.swift` 用安全作用域书签保存用户授权的文件夹，应用重启后通过 `URL(resolvingBookmarkData:)` 恢复访问，符合 App Sandbox 规范。

### 4. 通用二进制
`project.yml` 中 `ARCHS: "$(ARCHS_STANDARD)"` 配合 `COMBINE_HIDPI_IMAGES`，产物同时包含 `arm64` 与 `x86_64`，Apple Silicon / Intel 均原生运行。

### 5. 智能筛选的异步检测与并发控制
连拍检测（`detectBurstsIfNeeded`）与模糊/闭眼检测（`detectBlurryIfNeeded`）均采用统一的异步模式，保证大图库下不卡 UI、切文件夹时干净取消：

- **Task 句柄 + token 双重取消**：每种检测持有 `xxxDetectTask: Task<Void, Never>?` 与 `xxxDetectToken: Int`。切换文件夹（`loadContent`）时递增 token 并 `cancel()` 旧任务；`Task.isCancelled` 使在途子任务不再补充新任务，排空即止。token 不匹配时仅复位 spinner、不应用旧结果。
- **maxInflight 并发限制**：`withTaskGroup` 内限制在途子任务数（连拍 16、模糊 16），避免一次性提交数千个子任务压垮 Swift 协作线程池。迭代器按需补充，与 `precomputeAnalysis` 同模式。
- **流式分批刷新**：模糊检测每 16 张调一次 `mergeBlurlyBatch` 增量刷新 UI，不必等全部算完。
- **持久化防覆盖**：存盘时从 `PhotoAnalysisStore.load()` 重新读取最新缓存（而非检测启动时的快照），避免预计算期间其他 `save()` 写入的字段（blur ↔ dHash）被陈旧快照覆盖丢失。
- **缩略图尺寸**：模糊检测取 512px 缩略图（小脸需 4 倍细节，128px 下小脸仅十几像素会导致误判）；连拍检测取 32px dHash。
- **持久化仅在 token 匹配时执行**：避免用旧文件夹的 `mtimeOf` 覆盖新文件夹的数据。

### 6. 详情视图的加载竞态保护
`PhotoDetailView` 在加载大图与元数据后校验 `Task.isCancelled`：用户快速切换上下张时，旧图加载完成后不会短暂覆盖新图。

---

## 七、常用命令速查

| 操作 | 命令 |
| --- | --- |
| 生成工程 | `bash Scripts/generate_project.sh` |
| Debug 编译 | `bash Scripts/build.sh` |
| Release 编译 | `CONFIG=Release bash Scripts/build.sh` |
| 构建+运行 | `bash Scripts/run.sh` |
| 打包 DMG | `bash Scripts/package_dmg.sh` |
| 签名+公证 | `bash Scripts/notarize.sh` |
| 清除隔离 | `bash Scripts/remove_quarantine.sh [path.app]` |
| 验证签名 | `codesign -dv --strict path.app` |
| 验证公证 | `spctl -a -vv -t exec path.app` |
| 查看架构 | `lipo -archs path.app/Contents/MacOS/FrameScoop` |

---

## 八、键盘快捷键

| 快捷键 | 功能 |
| --- | --- |
| ⌘O | 添加文件夹 |
| ⌘R | 刷新当前文件夹 |
| ⌘, | 打开偏好设置 |
| 双击图片 | 进入沉浸查看 |
| ← / → | 上一张 / 下一张（查看视图） |
| Esc | 退出查看视图 |

---

## 九、许可

本工程源码可自由使用与修改。图标为脚本生成的占位图，可替换为自有设计。
