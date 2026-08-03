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

@MainActor
final class PhotoLibraryViewModel: ObservableObject {

    // MARK: - 发布状态（驱动 UI）

    /// 侧边栏文件夹树（根节点 = 用户添加的文件夹，可逐级展开）
    @Published var folderTree: [FolderNode] = []

    /// 当前选中节点的 id（文件夹路径）
    @Published var selectedNodeID: String?

    /// 当前选中文件夹的图片（未排序原始顺序，含下级目录）
    @Published var photos: [PhotoItem] = [] {
        didSet { rebuildDisplayedPhotos() }
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

    /// 用户可关闭的错误提示（非空时弹窗）
    @Published var errorMessage: String?

    /// 照片库访问被拒绝/受限（选中「照片图库」节点且未授权时为 true，驱动空状态提示）
    @Published var photosAccessDenied: Bool = false

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
    /// 调试输出到 stderr(无缓冲,重定向到文件立即可见;print 到 stdout 重定向时被缓冲不可见)
    private func dbg(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }
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
            let status = await PhotosLibraryService.shared.requestAuthorization()
            guard token == loadToken else { return }
            guard status == .authorized else {
                self.photos = []
                self.isLoading = false
                self.photosAccessDenied = (status == .denied || status == .restricted)
                return
            }
            let items = await PhotosLibraryService.shared.loadAllPhotos()
            guard token == loadToken else { return }
            self.photos = items
            self.isLoading = false
            self.photosAccessDenied = false
        }
    }

    // MARK: - 节点级数据（侧边栏行懒加载）

    /// 递归统计节点文件夹的图片数量（含下级目录）。照片库节点返回照片库全部图片资产数。
    func countImages(for node: FolderNode) async -> Int {
        if node.isPhotosLibrary {
            return await Task.detached(priority: .utility) {
                PHAsset.fetchAssets(with: .image, options: nil).count
            }.value
        }
        guard let url = node.url else { return 0 }
        return await Task.detached(priority: .utility) {
            PhotoLoadService.countImagesRecursively(in: url)
        }.value
    }

    /// 获取节点的预览缩略图（取该文件夹/照片库首图）。
    func previewThumbnail(for node: FolderNode) async -> NSImage? {
        if node.isPhotosLibrary {
            let id = await Task.detached(priority: .utility) { () -> String? in
                PHAsset.fetchAssets(with: .image, options: nil).firstObject?.localIdentifier
            }.value
            guard let id else { return nil }
            return await PhotosLibraryService.shared.image(for: id, maxPixel: 96)
        }
        guard let url = node.url else { return nil }
        // firstImageURL 是递归目录枚举，放到后台线程避免阻塞 UI（与 countImages 一致）
        let firstImage = await Task.detached(priority: .utility) {
            PhotoLoadService.firstImageURL(in: url)
        }.value
        guard let firstImage else { return nil }
        let item = PhotoItem(url: firstImage, name: "", size: 0,
                             creationDate: nil, modificationDate: nil)
        return await ThumbnailCacheService.shared.thumbnail(for: item, maxPixel: 96)
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

    /// 重算缓存的排序结果（在 photos / sortOption / sortOrder 变化时由 didSet 调用）
    private func rebuildDisplayedPhotos() {
        displayedPhotos = sort(photos)
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
