//
//  PhotoLibraryViewModel.swift
//  FrameScoop
//
//  图片库视图模型（核心业务编排层）。
//
//  职责：
//  - 管理用户添加的根文件夹（书签持久化）并构建「逐级展开」的文件夹树
//  - 保持各根文件夹的安全作用域常驻激活，使任意层级的子文件夹都可访问
//  - 选中任意节点时加载该文件夹（含下级目录）的图片、启动文件监控
//  - 维护选择状态、排序、缩略图尺寸、沉浸式详情查看
//  - 订阅 App 层菜单命令通知
//
//  所有 UI 更新在主线程执行（@MainActor）。
//

import Foundation
import AppKit
import Combine
import SwiftUI
import Photos

#if DEBUG
/// 调试日志：同时写 stderr 与 /tmp/framescoop-debug.log（串行队列追加，线程安全）。
/// 文件作用域 + nonisolated，便于从 detached task 直接调用收集（无 MainActor 跳转）。
enum DebugLog {
    private static let url = URL(fileURLWithPath: "/tmp/framescoop-debug.log")
    private nonisolated(unsafe) static let queue = DispatchQueue(label: "framescoop.debuglog")

    static func write(_ s: String) {
        let data = Data((s + "\n").utf8)
        FileHandle.standardError.write(data)
        queue.async {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            if let h = try? FileHandle(forWritingTo: url) {
                _ = try? h.seekToEnd()
                _ = try? h.write(contentsOf: data)
                try? h.close()
            }
        }
    }
}
#endif

@MainActor
final class PhotoLibraryViewModel: ObservableObject {

    // MARK: - 发布状态（驱动 UI）

    /// 侧边栏文件夹树（根节点 = 用户添加的文件夹，可逐级展开）
    @Published var folderTree: [FolderNode] = []

    /// 当前选中节点的 id（文件夹路径）
    @Published var selectedNodeID: String?

    /// 当前选中文件夹的图片（未排序原始顺序，含下级目录）
    @Published var photos: [PhotoItem] = [] {
        didSet {
            // 仅当照片集合（id）实际变化时才重启检测；同一文件夹的 reload（文件监控、
            // iCloud 同步触动的元数据/属性变化等若内容不变）不取消在途检测，
            // 否则进度会被反复顶掉 token 而永远卡在「已识别 0」。
            let changed = Set(oldValue.map(\.id)) != Set(photos.map(\.id))
            if showsBurstFilter || showsBlurFilter {
                if changed {
                    if showsBurstFilter { detectBurstsIfNeeded() }
                    if showsBlurFilter { detectBlurryIfNeeded() }
                } else {
                    rebuildDisplayedPhotos()
                }
            } else {
                rebuildDisplayedPhotos()
            }
        }
    }

    /// 排序后的展示列表（缓存）：仅在 photos / sortOption / sortOrder 变化时重算。
    /// 避免每次访问都重新排序（网格、胶片条、currentPhotoIndex 都会读取它）。
    @Published private(set) var displayedPhotos: [PhotoItem] = []

    /// 多选中的图片 id（基于 url.path，与 PhotoItem.id 一致，跨 reload 稳定）
    @Published var selectedPhotoIDs: Set<String> = []

    /// 详情视图当前展示的图片
    @Published var currentPhoto: PhotoItem?

    /// 加载中状态
    @Published var isLoading: Bool = false

    /// 排序维度 / 方向
    /// 默认按「创建时间」（照片库源即拍摄时间），降序（最新在前）。
    @Published var sortOption: SortOption = .dateCreated {
        didSet {
            if !isLoadingSettings { persistSettings() }
            rebuildDisplayedPhotos()
        }
    }
    @Published var sortOrder: SortOrder = .descending {
        didSet {
            if !isLoadingSettings { persistSettings() }
            rebuildDisplayedPhotos()
        }
    }

    /// 缩略图尺寸档位
    @Published var thumbnailSize: ThumbnailSize = .medium {
        didSet {
            if !isLoadingSettings { persistSettings() }
        }
    }

    /// 详情视图中是否显示信息面板
    @Published var showsInfoPanel: Bool = false

    /// 右侧「智能筛选」边栏是否显示（功能逐步添加中，当前为占位）
    @Published var showsFilterPanel: Bool = true

    /// 连拍筛选：开启后按画面相似（dHash）识别连拍并分段显示
    @Published var showsBurstFilter: Bool = false {
        didSet { detectBurstsIfNeeded() }
    }
    /// 连拍相似度阈值（dHash Hamming 距离）：<= 此值视为画面相似；越小越严格
    @Published var burstSimilarityThreshold: Int = 10 {
        didSet { regroupBursts() }
    }
    /// 仅显示连拍组内的照片（隐藏非连拍单张）
    @Published var showsBurstOnly: Bool = false {
        didSet { rebuildDisplayedPhotos() }
    }
    /// 连拍分组结果（连拍模式有效；空表示未检测/无连拍）
    @Published private(set) var burstSegments: [BurstSegment] = []
    /// 连拍组内编号（photoID -> 从 1 开始的序号）；仅连拍组内照片有值，单张无
    @Published private(set) var burstPhotoNumbers: [String: Int] = [:]
    /// 是否正在识别连拍（后台取图算哈希中）
    @Published private(set) var isBurstDetecting: Bool = false

    /// 人脸模糊筛选：开启后检测人脸并判断人脸是否模糊（任一清晰即不算），左上角标红感叹号
    @Published var showsBlurFilter: Bool = false {
        didSet { detectBlurryIfNeeded() }
    }
    /// 人脸模糊判定阈值（拉普拉斯方差）：score 低于此值视为该人脸模糊；越小越严格
    @Published var blurThreshold: Double = 100.0 {
        didSet { regroupBlurry() }
    }
    /// 仅显示人脸模糊照片（隐藏无人脸或人脸清晰的照片）
    @Published var showsBlurOnly: Bool = false {
        didSet { rebuildDisplayedPhotos() }
    }
    /// 人脸全模糊照片 id 集合（所有人脸都模糊）-> 标红感叹号
    @Published private(set) var blurryPhotoIDs: Set<String> = []
    /// 人脸部分模糊照片 id 集合（有清晰也有模糊人脸）-> 标黄感叹号
    @Published private(set) var partialBlurryPhotoIDs: Set<String> = []
    /// 是否正在识别人脸模糊（后台检测人脸 + 算 FFT）
    @Published private(set) var isBlurDetecting: Bool = false

    /// 用户可关闭的错误提示（非空时弹窗）
    @Published var errorMessage: String?

    /// 照片库访问被拒绝/受限（选中「照片图库」节点且未授权时为 true，驱动空状态提示）
    @Published var photosAccessDenied: Bool = false

    /// 照片库鉴权状态版本号：每次成功授权后递增，
    /// 驱动侧边栏「照片图库」节点重算计数（未授权时 fetchAssets 返回 0，授权后需刷新）
    @Published var photosAuthTick: Int = 0

    // MARK: - 私有依赖与状态

    private let loadService = PhotoLoadService()
    private let bookmarkStore = BookmarkStore()
    private let monitor = FolderMonitorService()
    private var cancellables = Set<AnyCancellable>()

    /// 用户添加的根文件夹（含书签，持久化）
    private var roots: [PhotoFolder] = []

    /// 已激活安全作用域的根 URL，与 roots 按索引一一对应；书签解析失败时为 nil（仍占位以保持对齐）
    private var activeRootURLs: [URL?] = []

    /// 文件夹内容加载的版本号：切换到不同文件夹时递增，回调时校验丢弃过期结果
    private var loadToken = 0
    /// 最近一次加载的源 key：folder 为 url.path，照片库为固定常量。
    /// 同源的 reload 不递增 token，避免文件监控频繁触发时加载任务互相取消。
    private var lastLoadedKey: String?
    /// 文件夹树重建的版本号：仅最新一次重建结果写回 folderTree，过期结果丢弃
    private var rebuildToken = 0

    private let settingsKey = "FrameScoop.settings"
    /// 旧版默认按「修改时间」排序；v2 起默认改为「创建时间」。标记是否已完成一次性迁移。
    private let sortDefaultMigratedKey = "FrameScoop.sortDefault.v2"
    /// 加载设置期间置 true，跳过 didSet 中冗余的 persistSettings（避免把刚读出的值又写回）
    private var isLoadingSettings = false

    #if DEBUG
    /// 调试输出：stderr + /tmp/framescoop-debug.log（nonisolated，可从 detached task 调用）
    nonisolated private func dbg(_ s: String) { DebugLog.write(s) }
    #endif

    // MARK: - Init

    init() {
        // 以下两项不修改 @Published，可在 init 中安全设置
        monitor.onChange = { [weak self] in
            #if DEBUG
            self?.dbg("[DBG] monitor onChange -> reload")
            #endif
            Task { @MainActor in self?.reloadCurrentFolder() }
        }
        observeMenuCommands()

        // 重要：本对象作为 @StateObject，其初始值是在首个视图 body 求值期间才创建的。
        // 若在 init 中同步修改 @Published，会在“视图更新期间发布”，触发警告。
        // 因此将所有会发布状态的初始化工作延后到下一个 runloop 执行。
        Task { @MainActor [weak self] in
            self?.setUp()
        }
    }

    /// 延后执行的初始化：读取设置与根文件夹，激活安全作用域并构建树。
    /// 选中动作仅修改 selectedNodeID；实际图片加载由视图的 onChange 触发 loadContent。
    @MainActor
    private func setUp() {
        loadSettings()
        migrateSortDefaultIfNeeded()
        roots = bookmarkStore.loadAll()
        startAllRootScopes()
        // 重建完成后选中首个节点（此时 folderTree 已就绪）：
        // 优先选首个用户文件夹，无则落到常驻的「照片图库」节点
        rebuildTree { [weak self] in
            guard let self else { return }
            if self.selectedNodeID == nil {
                self.selectedNodeID = self.folderTree.first(where: { !$0.isPhotosLibrary })?.id
                    ?? self.folderTree.first?.id
            }
        }
    }

    // MARK: - 计算属性

    /// 当前选中节点
    var selectedNode: FolderNode? {
        guard let id = selectedNodeID else { return nil }
        return findNode(id: id, in: folderTree)
    }

    /// 当前图片在 displayedPhotos 中的索引（读取缓存的排序数组，仅线性查找）
    var currentPhotoIndex: Int? {
        guard let current = currentPhoto else { return nil }
        return displayedPhotos.firstIndex(where: { $0.id == current.id })
    }

    // MARK: - 根文件夹管理

    /// 弹出 NSOpenPanel 添加根文件夹
    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择图片文件夹"
        panel.message = "FrameScoop 将保存该文件夹的访问权限，重启后仍可浏览。"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        addRootURL(url)
    }

    /// 添加根文件夹：创建书签、激活安全作用域、重建树并选中。
    func addRootURL(_ url: URL) {
        do {
            let bookmark = try bookmarkStore.makeBookmark(for: url)
            let folder = PhotoFolder(name: url.lastPathComponent,
                                     url: url,
                                     bookmarkData: bookmark)
            roots.append(folder)
            bookmarkStore.saveAll(roots)

            // 激活该根的安全作用域并记录；与 roots 保持索引对齐（解析失败时占位 nil）
            var resolvedPath: String? = nil
            if let (resolved, _) = bookmarkStore.resolveURL(for: folder) {
                _ = resolved.startAccessingSecurityScopedResource()
                activeRootURLs.append(resolved)
                resolvedPath = resolved.path
            } else {
                // 书签刚创建却无法解析（极少见，如权限瞬时丢失）：占位 nil，并提示用户
                activeRootURLs.append(nil)
                errorMessage = "无法恢复文件夹「\(url.lastPathComponent)」的访问权限，请重新添加。"
            }
            // 树重建（后台枚举）完成后选中新增的根，触发 onChange -> loadContent
            let selectPath = resolvedPath ?? url.path
            rebuildTree { [weak self] in
                self?.selectedNodeID = selectPath
            }
        } catch {
            errorMessage = "无法保存文件夹权限：\(error.localizedDescription)"
        }
    }

    /// 移除根文件夹（仅根节点可移除）
    func removeRoot(by rootID: UUID) {
        guard let idx = roots.firstIndex(where: { $0.id == rootID }) else { return }
        // 停止该根的安全作用域（解析失败的根为 nil，跳过）
        if idx < activeRootURLs.count, let url = activeRootURLs[idx] {
            url.stopAccessingSecurityScopedResource()
        }
        activeRootURLs.remove(at: idx)
        roots.remove(at: idx)
        bookmarkStore.saveAll(roots)
        // 重建完成后：若当前选中已不在树中（被移除），切到首个根
        rebuildTree { [weak self] in
            guard let self else { return }
            if let sel = self.selectedNodeID, self.findNode(id: sel, in: self.folderTree) == nil {
                self.selectedNodeID = self.folderTree.first?.id
            }
        }
    }

    /// 重命名根文件夹
    func renameRoot(by rootID: UUID, to name: String) {
        guard let idx = roots.firstIndex(where: { $0.id == rootID }) else { return }
        roots[idx].name = name
        bookmarkStore.saveAll(roots)
        rebuildTree()
    }

    // MARK: - 安全作用域与树构建

    /// 激活所有根文件夹的安全作用域。
    /// 解析失败的根以 nil 占位，保持与 roots 索引一一对应，避免后续错配。
    private func startAllRootScopes() {
        stopAllRootScopes()
        var staleRefresh: [(index: Int, url: URL)] = []
        activeRootURLs = roots.enumerated().map { index, root in
            guard let (resolved, stale) = bookmarkStore.resolveURL(for: root) else { return nil }
            _ = resolved.startAccessingSecurityScopedResource()
            if stale { staleRefresh.append((index, resolved)) }
            return resolved
        }
        // 在循环外刷新陈旧书签，避免 map 期间修改 roots
        for item in staleRefresh {
            if let newBookmark = try? bookmarkStore.makeBookmark(for: item.url) {
                roots[item.index].bookmarkData = newBookmark
            }
        }
        if !staleRefresh.isEmpty { bookmarkStore.saveAll(roots) }
    }

    private func stopAllRootScopes() {
        for case let url? in activeRootURLs {
            url.stopAccessingSecurityScopedResource()
        }
        activeRootURLs = []
    }

    /// 由 roots（已激活作用域）构建文件夹树。
    /// 目录枚举在后台线程执行（避免大目录树阻塞主线程），完成后回主线程写回 folderTree，
    /// 再执行 completion（用于设置选中态等依赖 tree 就绪的后置逻辑）。
    private func rebuildTree(then completion: @MainActor @escaping () -> Void = {}) {
        rebuildToken += 1
        let token = rebuildToken
        // 仅取构建所需字段组成 Sendable 快照（UUID/String/URL 均为 Sendable），
        // 避免把整个 [PhotoFolder]（非 Sendable）捕获进 @Sendable 后台闭包；
        // 同时对 roots 与 activeRootURLs 做索引对齐快照，防止枚举期间主线程增删根导致错配。
        let snapshot: [(id: UUID, name: String, url: URL)] = roots.enumerated().compactMap { index, root in
            guard index < activeRootURLs.count else { return nil }
            // 书签解析失败的根（activeRootURLs[index] 为 nil）跳过，避免名字与 URL 错配
            guard let resolved = activeRootURLs[index] else { return nil }
            return (id: root.id, name: root.name, url: resolved)
        }
        Task { @MainActor [weak self] in
            let tree = await Task.detached(priority: .userInitiated) { () -> [FolderNode] in
                snapshot.map { entry in
                    let children = PhotoLoadService.buildFolderTree(url: entry.url)
                    return FolderNode(
                        id: entry.url.path,
                        name: entry.name,
                        url: entry.url,
                        children: children.isEmpty ? nil : children,
                        isRoot: true,
                        rootID: entry.id
                    )
                }
            }.value
            // 过期的重建结果丢弃（用户在此期间又增删了根）
            guard let self, token == self.rebuildToken else { return }
            // 常驻的「照片图库」节点置于首位（不可移除/重命名，内容经 PhotosLibraryService 加载）
            let photosNode = FolderNode(
                id: PhotosLibraryService.sidebarNodeID,
                name: "照片图库",
                url: nil,
                children: nil,
                isRoot: true,
                rootID: nil,
                isPhotosLibrary: true
            )
            self.folderTree = [photosNode] + tree
            completion()
        }
    }

    /// 递归查找节点
    private func findNode(id: String, in nodes: [FolderNode]) -> FolderNode? {
        for node in nodes {
            if node.id == id { return node }
            if let children = node.children, let found = findNode(id: id, in: children) {
                return found
            }
        }
        return nil
    }

    // MARK: - 选择与加载

    /// 选中节点变化后加载其内容。
    /// 仅由视图的 `.onChange(of: selectedNodeID)` 调用（在更新事务之后执行，安全）。
    func loadContent(for id: String?) {
        // 切换节点 = 切换照片源：递增 token，取消上一个文件夹的在途人脸模糊检测，
        // 避免其结果污染新文件夹。同文件夹的 reload 不走本方法，不会递增。
        blurDetectToken += 1
        selectedPhotoIDs.removeAll()
        currentPhoto = nil

        guard id != nil else {
            monitor.stop()
            photos = []
            lastLoadedKey = nil
            photosAccessDenied = false
            return
        }
        guard let node = selectedNode else {
            // 节点已不在树中（如刚被移除）但 selectedNodeID 尚未清空：
            // 停止上一次的文件夹监控并复位加载状态，避免泄漏监控 fd 与残留空加载
            monitor.stop()
            isLoading = false
            photos = []
            lastLoadedKey = nil
            photosAccessDenied = false
            return
        }
        if node.isPhotosLibrary {
            // 照片库源不走文件夹监控
            monitor.stop()
            loadPhotosLibrary()
            return
        }
        guard let url = node.url else {
            monitor.stop()
            isLoading = false
            photos = []
            return
        }
        loadPhotos(from: url)
        monitor.startMonitoring(url: url)   // 内部会先停止上一次监控
    }

    /// 重新加载当前选中节点的内容（监控触发 / 手动刷新）
    func reloadCurrentFolder() {
        guard let node = selectedNode else { return }
        if node.isPhotosLibrary {
            loadPhotosLibrary()
            return
        }
        guard let url = node.url else { return }
        loadPhotos(from: url)
    }

    private func loadPhotos(from url: URL) {
        isLoading = true
        // 仅切换到不同文件夹时递增 token(取消在途的旧文件夹加载);
        // 同一文件夹的 reload 不递增,避免文件监控频繁触发时加载任务互相取消而永不更新
        if lastLoadedKey != url.path {
            loadToken += 1
            lastLoadedKey = url.path
        }
        let token = loadToken
        #if DEBUG
        dbg("[DBG] loadPhotos \(url.lastPathComponent) token=\(token)")
        #endif
        Task {
            let items = await loadService.loadPhotos(from: url)
            #if DEBUG
            self.dbg("[DBG] loadPhotos done \(url.lastPathComponent) items=\(items.count) match=\(token == loadToken)")
            #endif
            guard token == loadToken else { return }
            self.photos = items
            self.isLoading = false
        }
    }

    /// 加载系统照片库（Photos.framework，含 iCloud 同步到本机的照片）。
    /// 先确保鉴权（已授权/拒绝时幂等），再枚举全部图片资产。
    private func loadPhotosLibrary() {
        isLoading = true
        if lastLoadedKey != PhotosLibraryService.sidebarNodeID {
            loadToken += 1
            lastLoadedKey = PhotosLibraryService.sidebarNodeID
        }
        let token = loadToken
        Task {
            // 鉴权前原始状态：0=notDetermined 1=restricted 2=denied 3=authorized
            let rawBefore = PHPhotoLibrary.authorizationStatus(for: .readWrite).rawValue
            let status = await PhotosLibraryService.shared.requestAuthorization()
            #if DEBUG
            self.dbg("[DBG] photosLibrary auth before=\(rawBefore) after=\(status)")
            #endif
            guard token == loadToken else { return }
            guard status == .authorized else {
                self.photos = []
                self.isLoading = false
                self.photosAccessDenied = (status == .denied || status == .restricted)
                return
            }
            let items = await PhotosLibraryService.shared.loadAllPhotos()
            #if DEBUG
            self.dbg("[DBG] photosLibrary loaded items=\(items.count)")
            #endif
            guard token == loadToken else { return }
            self.photos = items
            self.isLoading = false
            self.photosAccessDenied = false
            // 授权成功：递增版本号，驱动侧边栏照片库节点重算计数
            self.photosAuthTick += 1
        }
    }

    // MARK: - 节点级数据（侧边栏行懒加载）

    /// 递归统计节点文件夹的图片数量（含下级目录）。照片库节点返回照片库全部图片资产数。
    /// 照片库节点未授权时返回 nil：fetchAssets 在未授权时静默返回 0，无法与"0 张"区分，
    /// 故用 nil 表示未知（侧边栏显示 "…"），授权后经 photosAuthTick 触发重算。
    func countImages(for node: FolderNode) async -> Int? {
        if node.isPhotosLibrary {
            return await Task.detached(priority: .utility) {
                guard PhotosLibraryService.shared.status == .authorized else { return nil }
                return PHAsset.fetchAssets(with: .image, options: nil).count
            }.value
        }
        guard let url = node.url else { return nil }
        return await Task.detached(priority: .utility) {
            PhotoLoadService.countImagesRecursively(in: url)
        }.value
    }

    /// 在 Finder 中显示某节点文件夹（照片库节点无对应文件，无操作）
    func revealFolderInFinder(_ node: FolderNode) {
        guard let url = node.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - 图片选择 / 详情

    func toggleSelection(_ photo: PhotoItem) {
        if selectedPhotoIDs.contains(photo.id) {
            selectedPhotoIDs.remove(photo.id)
        } else {
            selectedPhotoIDs.insert(photo.id)
        }
    }

    func selectSingle(_ photo: PhotoItem) {
        selectedPhotoIDs = [photo.id]
    }

    /// 选中并打开图片到详情窗口。
    /// 由调用方（视图，持有 openWindow 环境）负责随后 openWindow(id: "photo-detail")。
    func openPhoto(_ photo: PhotoItem) {
        selectSingle(photo)
        currentPhoto = photo
        showsInfoPanel = false
    }

    func nextPhoto() {
        guard let idx = currentPhotoIndex, idx + 1 < displayedPhotos.count else { return }
        currentPhoto = displayedPhotos[idx + 1]
    }

    func previousPhoto() {
        guard let idx = currentPhotoIndex, idx > 0 else { return }
        currentPhoto = displayedPhotos[idx - 1]
    }

    /// 在 Finder 中显示选中图片（仅文件夹源；照片库源无对应文件）
    func revealInFinder(_ photo: PhotoItem) {
        guard let url = photo.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// 加载图片元数据（详情面板调用；按 sourceKind 分派：folder->mdls，photoLibrary->PHAsset）
    func loadMetadata(for item: PhotoItem) async -> ImageMetadata {
        await PhotoLoader.metadata(for: item)
    }

    /// 删除选中图片到废纸篓（原生，可恢复）。
    /// folder 源：FileManager.trashItem；photoLibrary 源：PHAssetChangeRequest 删除到「最近删除」。
    func trashPhotos(_ ids: Set<String>) {
        let targets = photos.filter { ids.contains($0.id) }
        guard !targets.isEmpty else { return }
        // 若被删图片中有当前正在详情视图查看的，先清空 currentPhoto：
        // 触发 DetailWindowRoot 关闭详情窗口，避免显示已废纸篓的陈旧大图
        if let current = currentPhoto, ids.contains(current.id) {
            currentPhoto = nil
        }
        // 同步移出选择集合，避免残留无效 id
        selectedPhotoIDs.subtract(ids)
        let folderURLs = targets.filter { $0.sourceKind == .folder }.compactMap { $0.url }
        let photoIDs = targets.filter { $0.sourceKind == .photoLibrary }.compactMap { $0.assetIdentifier }
        guard !folderURLs.isEmpty || !photoIDs.isEmpty else { return }
        Task { [weak self] in
            var failed = 0
            // 文件夹源：逐张废纸篓
            for url in folderURLs {
                var resultingURL: NSURL?
                do { try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL) }
                catch { failed += 1 }
            }
            // Photos 源：批量删除到「最近删除」
            if !photoIDs.isEmpty {
                let ok = await PhotosLibraryService.shared.deleteAssets(localIdentifiers: photoIDs)
                if !ok { failed += photoIDs.count }
            }
            guard let self else { return }
            // 无论部分成功与否都刷新网格，使已删除的从界面移除
            self.reloadCurrentFolder()
            if failed > 0 {
                self.errorMessage = "有 \(failed) 张图片无法移到废纸篓"
            }
        }
    }

    // MARK: - 连拍整理（删除选中 / 保留选中）

    /// 删除当前选中的图片（移到废纸篓，可恢复）
    func trashSelectedPhotos() {
        guard !selectedPhotoIDs.isEmpty else { return }
        trashPhotos(selectedPhotoIDs)
    }

    /// 「保留选中」预删除的图片 id：
    /// 仅针对「本组内有被选中照片」的连拍组，删除组内未选中的；
    /// 若某连拍组没有任何被选中照片，则该组保持不动。
    private var keepSelectedTrashIDs: Set<String> {
        let selected = selectedPhotoIDs
        guard !selected.isEmpty else { return [] }
        var toTrash: Set<String> = []
        for segment in burstSegments {
            guard case .burst(let group) = segment else { continue }
            // 本组无任何被选中 -> 跳过，整组不删
            guard group.contains(where: { selected.contains($0.id) }) else { continue }
            for p in group where !selected.contains(p.id) {
                toTrash.insert(p.id)
            }
        }
        return toTrash
    }

    /// 「保留选中」将删除的连拍照片数量（供边栏按钮 / 确认框显示）
    var keepSelectedDeleteCount: Int {
        keepSelectedTrashIDs.count
    }

    /// 「保留选中」：对本组有被选中的连拍组，删除组内未选中的照片（保留选中）。
    func keepSelectedPhotos() {
        let toTrash = keepSelectedTrashIDs
        guard !toTrash.isEmpty else { return }
        trashPhotos(toTrash)
    }

    // MARK: - 发送 / 分享

    /// 当前选中的图片项（用于按源分派的操作）
    var selectedItems: [PhotoItem] {
        photos.filter { selectedPhotoIDs.contains($0.id) }
    }

    /// 当前选中图片的文件 URL（仅 folder 源；用于邮件附件等需文件 URL 的场景）
    var selectedURLs: [URL] {
        selectedItems.filter { $0.sourceKind == .folder }.compactMap { $0.url }
    }

    /// 导出到指定文件夹：弹出 NSOpenPanel 选择目标目录，复制/导出选中图片。
    /// folder 源：复制文件；photoLibrary 源：经 PHAssetResourceManager 导出原图数据。
    func exportSelectionToFolder() {
        let items = selectedItems
        guard !items.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "导出到此文件夹"
        panel.message = "将选中的 \(items.count) 张图片复制到该文件夹。"
        guard panel.runModal() == .OK, let dest = panel.url else { return }

        // 用户选择的目标目录需激活安全作用域以写入（安全作用域为进程级，跨线程有效）；
        // 在导出任务完成后于主线程停止，避免提前停止导致后续写入失败。
        let started = dest.startAccessingSecurityScopedResource()
        // 强捕获 self：导出期间保留 VM（@MainActor 类，Sendable），避免 weak-self 在 @Sendable 闭包中触发并发告警
        Task.detached { [self] in
            var successCount = 0
            var failedCount = 0
            var lastError: String?
            for item in items {
                let target = PhotoLibraryViewModel.uniqueDestinationURL(in: dest, for: item.name)
                let ok: Bool
                switch item.sourceKind {
                case .folder:
                    guard let src = item.url else { ok = false; break }
                    do {
                        try FileManager.default.copyItem(at: src, to: target)
                        ok = true
                    } catch {
                        lastError = error.localizedDescription
                        ok = false
                    }
                case .photoLibrary:
                    guard let id = item.assetIdentifier else { ok = false; break }
                    ok = await PhotosLibraryService.shared.exportAsset(localIdentifier: id, to: target)
                }
                if ok { successCount += 1 } else { failedCount += 1 }
            }
            // 计算结果消息（let，避免 MainActor 闭包捕获 var 触发并发告警）
            let msg: String? = failedCount > 0
                ? (successCount > 0
                    ? "已导出 \(successCount) 张，\(failedCount) 张失败：\(lastError ?? "")"
                    : "导出失败：\(lastError ?? "")")
                : nil
            await MainActor.run {
                if started { dest.stopAccessingSecurityScopedResource() }
                if let msg { self.errorMessage = msg }
            }
        }
    }

    /// 生成不冲突的目标路径（同名自动加序号）；保留原扩展名（Photos 项用 name 中的扩展名）。
    /// nonisolated：仅依赖 FileManager（线程安全），可被后台导出任务直接调用。
    private nonisolated static func uniqueDestinationURL(in dir: URL, for name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        let candidate = dir.appendingPathComponent(name)
        let fm = FileManager.default
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        // 序号上限 9999，超出则回退用 UUID 保证唯一，避免理论上的无限循环
        for i in 2...9999 {
            let n = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
            let c = dir.appendingPathComponent(n)
            if !fm.fileExists(atPath: c.path) { return c }
        }
        let fallback = ext.isEmpty ? "\(base) \(UUID().uuidString)" : "\(base) \(UUID().uuidString).\(ext)"
        return dir.appendingPathComponent(fallback)
    }

    /// 复制到剪贴板：folder 源复制文件 URL（单张额外复制图片）；photoLibrary 源复制图片数据。
    func copySelectionToClipboard() {
        let items = selectedItems
        guard !items.isEmpty else { return }
        Task.detached {
            let folderURLs = items.filter { $0.sourceKind == .folder }.compactMap { $0.url }
            // 单张时额外把图片本身放上剪贴板，便于粘贴到聊天/编辑器
            let single = items.count == 1 ? items.first : nil
            var fetched: NSImage?
            if let item = single {
                switch item.sourceKind {
                case .folder:
                    fetched = item.url.flatMap { NSImage(contentsOf: $0) }
                case .photoLibrary:
                    if let id = item.assetIdentifier {
                        fetched = await PhotosLibraryService.shared.image(for: id, maxPixel: 2048)
                    }
                }
            }
            // 拷贝为 let，避免 MainActor 闭包捕获 var 触发并发告警
            let singleImage = fetched
            await MainActor.run {
                let pb = NSPasteboard.general
                pb.clearContents()
                var writers: [NSPasteboardWriting] = folderURLs.map { $0 as NSURL }
                if let singleImage { writers.append(singleImage as NSPasteboardWriting) }
                pb.writeObjects(writers)
            }
        }
    }

    /// 作为邮件附件发送（folder 源附文件 URL；photoLibrary 源无文件 URL，提示先导出）
    func sendSelectionViaEmail() {
        let items = selectedItems
        guard !items.isEmpty else { return }
        let urls = items.filter { $0.sourceKind == .folder }.compactMap { $0.url }
        guard !urls.isEmpty else {
            errorMessage = "照片库图片需先「导出到指定文件夹」后再发送。"
            return
        }
        guard let service = NSSharingService(named: .composeEmail) else {
            errorMessage = "未找到邮件应用。"
            return
        }
        SharingServiceHelper.shared.perform(service, items: urls)
    }

    // MARK: - 排序

    /// 用于布局的连拍段：showsBurstOnly 时过滤掉单张段，仅保留连拍组
    var displayedBurstSegments: [BurstSegment] {
        guard showsBurstFilter else { return [] }
        if showsBurstOnly {
            return burstSegments.filter { segment in
                if case .burst = segment { return true }
                return false
            }
        }
        return burstSegments
    }

    /// 重算缓存的展示结果（在 photos / sortOption / sortOrder / 连拍分组 / 模糊过滤变化时由 didSet 调用）
    private func rebuildDisplayedPhotos() {
        let base: [PhotoItem]
        if showsBurstFilter && !burstSegments.isEmpty {
            // 连拍模式：按段扁平化（段内按时间升序，连拍组连续）；showsBurstOnly 时仅连拍组
            base = displayedBurstSegments.flatMap { seg -> [PhotoItem] in
                switch seg {
                case .single(let p): return [p]
                case .burst(let ps): return ps
                }
            }
        } else {
            base = sort(photos)
        }
        // showsBlurOnly：只留人脸模糊照片（红/黄都算；覆盖连拍分组布局，统一用普通 FlowLayout 展示）
        displayedPhotos = showsBlurOnly
            ? base.filter { blurryPhotoIDs.contains($0.id) || partialBlurryPhotoIDs.contains($0.id) }
            : base
    }

    // MARK: - 连拍识别

    /// photoID -> dHash 缓存（photos 变化时增量计算，阈值变化时复用，避免重取图）
    private var burstHashes: [String: UInt64] = [:]
    /// 串行化异步检测：仅采纳最新一次的结果，避免旧任务覆盖新结果
    private var burstDetectToken = 0

    /// 开启/照片变化时：后台并行取小图算 dHash，再分组
    private func detectBurstsIfNeeded() {
        guard showsBurstFilter else {
            applyBurstSegments([])
            return
        }
        burstDetectToken += 1
        let token = burstDetectToken
        isBurstDetecting = true
        let photos = self.photos
        let cached = self.burstHashes
        let toCompute = photos.filter { cached[$0.id] == nil }
        Task.detached(priority: .utility) { [weak self] in
            let newHashes: [String: UInt64] = await withTaskGroup(of: (String, UInt64?).self) { group in
                for photo in toCompute {
                    group.addTask {
                        let img = await ThumbnailCacheService.shared.thumbnail(for: photo, maxPixel: 32)
                        return (photo.id, img.flatMap { BurstDetectionService.dHash(of: $0) })
                    }
                }
                var result: [String: UInt64] = [:]
                for await (id, h) in group { if let h { result[id] = h } }
                return result
            }
            await MainActor.run {
                guard let self, token == self.burstDetectToken else { return }
                var hashes = cached
                for (id, h) in newHashes { hashes[id] = h }
                let liveIDs = Set(photos.map { $0.id })
                self.burstHashes = hashes.filter { liveIDs.contains($0.key) }
                self.applyBurstSegments(BurstDetectionService.group(
                    photos: photos,
                    hashes: self.burstHashes,
                    similarityThreshold: self.burstSimilarityThreshold
                ))
                self.isBurstDetecting = false
            }
        }
    }

    /// 阈值变化时：用已缓存哈希即时重新分组（不重取图，Stepper 流畅）
    private func regroupBursts() {
        guard showsBurstFilter else { return }
        applyBurstSegments(BurstDetectionService.group(
            photos: photos,
            hashes: burstHashes,
            similarityThreshold: burstSimilarityThreshold
        ))
    }

    /// 应用连拍分组：更新 burstSegments + 计算组内编号（从 1 开始），再重算展示
    private func applyBurstSegments(_ segments: [BurstSegment]) {
        burstSegments = segments
        var numbers: [String: Int] = [:]
        for segment in segments {
            if case .burst(let group) = segment {
                for (index, photo) in group.enumerated() {
                    numbers[photo.id] = index + 1
                }
            }
        }
        burstPhotoNumbers = numbers
        rebuildDisplayedPhotos()
    }

    // MARK: - 模糊识别

    /// photoID -> 人脸模糊判定结果缓存（阈值变化时复用，避免重取图）
    @Published private var blurScores: [String: FaceBlurScore] = [:]
    /// 已识别的照片数量（含无人脸的；每批落库时随 blurScores 变化，供边栏进度显示）
    var blurRecognizedCount: Int { blurScores.count }
    /// 仅在切换文件夹（源）时递增：取消旧文件夹的在途检测，避免其结果污染新文件夹。
    /// 同一文件夹的 reload（文件监控 / iCloud 增量下载）不递增——在途检测继续，仅补算未缓存的，
    /// 否则进度会被反复顶掉 token 而永远卡在「已识别 0」。
    private var blurDetectToken = 0
    /// 当前在途检测任务数；>0 即 isBlurDetecting。同文件夹增量补算会产生并发任务，共用计数。
    private var blurDetectInFlight = 0

    /// 开启/照片变化时：后台并行取缩略图检测人脸 + 算 Laplacian，流式分批落库并刷新标记。
    /// 优化点：缩略图降到 128px、优先级提到 .userInitiated、每 16 张增量刷新一次（不必等全部算完）。
    /// 注意：本方法不递增 token——同文件夹 reload 不取消在途检测；切换文件夹由 loadContent 递增。
    private func detectBlurryIfNeeded() {
        guard showsBlurFilter else {
            blurryPhotoIDs = []
            partialBlurryPhotoIDs = []
            rebuildDisplayedPhotos()
            return
        }
        let photos = self.photos
        // 清掉已不在列表里的陈旧分数/标记，避免集合无限增长
        let liveIDs = Set(photos.map { $0.id })
        self.blurScores = self.blurScores.filter { liveIDs.contains($0.key) }
        self.blurryPhotoIDs = self.blurryPhotoIDs.filter { liveIDs.contains($0) }
        self.partialBlurryPhotoIDs = self.partialBlurryPhotoIDs.filter { liveIDs.contains($0) }
        let cached = self.blurScores
        let toCompute = photos.filter { cached[$0.id] == nil }
        guard !toCompute.isEmpty else { return }
        let token = blurDetectToken
        blurDetectInFlight += 1
        isBlurDetecting = true
        #if DEBUG
        dbg("[BLUR] start toCompute=\(toCompute.count) token=\(token) src=\(toCompute.first?.sourceKind ?? .folder)")
        #endif
        Task.detached(priority: .userInitiated) { [weak self] in
            await withTaskGroup(of: (String, FaceBlurScore?).self) { group in
                for photo in toCompute {
                    group.addTask { [weak self] in
                        #if DEBUG
                        self?.dbg("[BLUR] + \(photo.name)")
                        #endif
                        let img = await ThumbnailCacheService.shared.thumbnail(for: photo, maxPixel: 128)
                        #if DEBUG
                        self?.dbg("[BLUR] thumb \(photo.name) ok=\(img != nil)")
                        #endif
                        let s = img.flatMap { BlurDetectionService.blurScore(of: $0) }
                        #if DEBUG
                        self?.dbg("[BLUR] score \(photo.name) ok=\(s != nil)")
                        #endif
                        return (photo.id, s)
                    }
                }
                // 流式收集：攒满 16 张就回主线程落库 + 刷新标记，用户早看到结果
                var batch: [(String, FaceBlurScore)] = []
                for await (id, s) in group {
                    if let s { batch.append((id, s)) }
                    if batch.count >= 16 {
                        let b = batch; batch = []
                        await MainActor.run { self?.mergeBlurryBatch(b, token: token) }
                    }
                }
                if !batch.isEmpty {
                    let b = batch
                    await MainActor.run { self?.mergeBlurryBatch(b, token: token) }
                }
            }
            // 任务结束：递减在途计数，归零才关进度。token 不匹配（已切文件夹）也照常递减，
            // 保证计数不会因切文件夹而卡住。
            await MainActor.run {
                guard let self else { return }
                self.blurDetectInFlight -= 1
                if self.blurDetectInFlight <= 0 {
                    self.blurDetectInFlight = 0
                    self.isBlurDetecting = false
                }
                #if DEBUG
                self.dbg("[BLUR] done inFlight=\(self.blurDetectInFlight)")
                #endif
            }
        }
    }

    /// 一批检测结果落库：只增量更新这批 id 的红/黄标记。
    /// 非“只显示模糊”模式下不重建列表（cell overlay 依赖 @Published 集合自动刷新），
    /// 仅在 showsBlurOnly 时才 rebuildDisplayedPhotos 做过滤。
    private func mergeBlurryBatch(_ batch: [(String, FaceBlurScore)], token: Int) {
        guard token == blurDetectToken else {
            #if DEBUG
            dbg("[BLUR] merge DROPPED token=\(token) cur=\(blurDetectToken) batch=\(batch.count)")
            #endif
            return
        }
        for (id, s) in batch {
            blurScores[id] = s
            classifyBlurry(id, s)
        }
        if showsBlurOnly { rebuildDisplayedPhotos() }
        #if DEBUG
        dbg("[BLUR] merge batch=\(batch.count) scores=\(blurScores.count)")
        #endif
    }

    /// 按当前阈值把单张分数归入红/黄集合（增量：先移除再按规则重插）
    private func classifyBlurry(_ id: String, _ s: FaceBlurScore) {
        blurryPhotoIDs.remove(id)
        partialBlurryPhotoIDs.remove(id)
        guard s.faceCount > 0 else { return }
        if s.maxScore < blurThreshold {
            blurryPhotoIDs.insert(id)
        } else if s.minScore < blurThreshold {
            partialBlurryPhotoIDs.insert(id)
        }
    }

    /// 阈值变化时：用已缓存分数即时重新分类（不重取图，Stepper 流畅）
    private func regroupBlurry() {
        guard showsBlurFilter else { return }
        applyBlurryScores()
    }

    /// 按阈值把缓存分数分类为红/黄集合：
    /// - 无人脸（faceCount == 0）-> 不标
    /// - maxScore < threshold -> 所有人脸都模糊 -> 红
    /// - maxScore >= threshold 且 minScore < threshold -> 有清晰也有模糊 -> 黄
    /// - 全清晰 -> 不标
    private func applyBlurryScores() {
        var red: Set<String> = []
        var yellow: Set<String> = []
        for (id, s) in blurScores {
            guard s.faceCount > 0 else { continue }
            if s.maxScore < blurThreshold {
                red.insert(id)
            } else if s.minScore < blurThreshold {
                yellow.insert(id)
            }
        }
        blurryPhotoIDs = red
        partialBlurryPhotoIDs = yellow
        rebuildDisplayedPhotos()
    }

    private func sort(_ items: [PhotoItem]) -> [PhotoItem] {
        let ascending = sortOrder == .ascending
        // 直接按目标方向比较，避免 sorted + reversed() 产生第二次 O(n) 数组分配
        return items.sorted { lhs, rhs in
            let cmp = baseCompare(lhs, rhs)
            return ascending ? (cmp == .orderedAscending) : (cmp == .orderedDescending)
        }
    }

    /// 升序比较基准（lhs 在 rhs 之前返回 .orderedAscending）
    private func baseCompare(_ lhs: PhotoItem, _ rhs: PhotoItem) -> ComparisonResult {
        switch sortOption {
        case .name:
            return lhs.name.localizedStandardCompare(rhs.name)
        case .size:
            if lhs.size < rhs.size { return .orderedAscending }
            if lhs.size > rhs.size { return .orderedDescending }
            return .orderedSame
        case .dateCreated:
            return Self.compareDates(lhs.creationDate, rhs.creationDate)
        case .dateModified:
            return Self.compareDates(lhs.modificationDate, rhs.modificationDate)
        }
    }

    private static func compareDates(_ lhs: Date?, _ rhs: Date?) -> ComparisonResult {
        let l = lhs ?? .distantPast, r = rhs ?? .distantPast
        if l < r { return .orderedAscending }
        if l > r { return .orderedDescending }
        return .orderedSame
    }

    // MARK: - 设置持久化

    private struct Settings: Codable {
        var sortOption: SortOption
        var sortOrder: SortOrder
        var thumbnailSize: ThumbnailSize
    }

    private func persistSettings() {
        let s = Settings(sortOption: sortOption, sortOrder: sortOrder, thumbnailSize: thumbnailSize)
        if let data = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(data, forKey: settingsKey)
        }
    }

    private func loadSettings() {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let s = try? JSONDecoder().decode(Settings.self, from: data) else { return }
        // 置位跳过 didSet 中的 persistSettings，避免刚读出的值又被写回
        isLoadingSettings = true
        defer { isLoadingSettings = false }
        sortOption = s.sortOption
        sortOrder = s.sortOrder
        thumbnailSize = s.thumbnailSize
    }

    /// 一次性迁移：旧版默认按「修改时间」排序，现改为按「创建时间」（照片库源即拍摄时间）。
    /// 仅当用户仍处于旧默认（.dateModified）时迁移；已自定义排序的不动。
    /// 迁移完成后置位，避免后续覆盖用户的显式选择。
    private func migrateSortDefaultIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: sortDefaultMigratedKey) else { return }
        UserDefaults.standard.set(true, forKey: sortDefaultMigratedKey)
        if sortOption == .dateModified {
            sortOption = .dateCreated   // 触发 didSet 持久化新默认
        }
    }

    // MARK: - 菜单命令订阅

    private func observeMenuCommands() {
        NotificationCenter.default.publisher(for: .addFolderRequested)
            .sink { [weak self] _ in self?.addFolder() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .refreshRequested)
            .sink { [weak self] _ in self?.reloadCurrentFolder() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .nextPhotoRequested)
            .sink { [weak self] _ in self?.nextPhoto() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .previousPhotoRequested)
            .sink { [weak self] _ in self?.previousPhoto() }
            .store(in: &cancellables)
    }
}
