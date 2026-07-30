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

    /// 多选中的图片 id
    @Published var selectedPhotoIDs: Set<UUID> = []

    /// 详情视图当前展示的图片
    @Published var currentPhoto: PhotoItem?

    /// 加载中状态
    @Published var isLoading: Bool = false

    /// 排序维度 / 方向
    @Published var sortOption: SortOption = .dateModified {
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

    // MARK: - 私有依赖与状态

    private let loadService = PhotoLoadService()
    private let metadataService = MetadataService()
    private let bookmarkStore = BookmarkStore()
    private let monitor = FolderMonitorService()
    private var cancellables = Set<AnyCancellable>()

    /// 用户添加的根文件夹（含书签，持久化）
    private var roots: [PhotoFolder] = []

    /// 已激活安全作用域的根 URL，与 roots 按索引一一对应；书签解析失败时为 nil（仍占位以保持对齐）
    private var activeRootURLs: [URL?] = []

    /// 文件夹内容加载的版本号：切换到不同文件夹时递增，回调时校验丢弃过期结果
    private var loadToken = 0
    /// 最近一次加载的 URL：同 URL 的 reload 不递增 token，避免文件监控频繁触发时互相取消
    private var lastLoadedURL: URL?

    private let settingsKey = "FrameScoop.settings"
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
        roots = bookmarkStore.loadAll()
        startAllRootScopes()
        rebuildTree()
        if selectedNodeID == nil {
            // 默认选中首个根文件夹（展示其下含子目录的全部图片）
            selectedNodeID = folderTree.first?.id
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
            rebuildTree()
            selectedNodeID = resolvedPath ?? url.path   // 触发 onChange -> loadContent
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
        rebuildTree()
        // 若移除的是当前选中，切到首个根
        if let sel = selectedNodeID, findNode(id: sel, in: folderTree) == nil {
            selectedNodeID = folderTree.first?.id
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

    /// 由 roots（已激活作用域）构建文件夹树
    private func rebuildTree() {
        var tree: [FolderNode] = []
        for (index, root) in roots.enumerated() {
            guard index < activeRootURLs.count else { continue }
            // 书签解析失败的根（activeRootURLs[index] 为 nil）跳过，
            // 避免名字与 URL 错配（张冠李戴）
            guard let resolved = activeRootURLs[index] else { continue }
            let children = PhotoLoadService.buildFolderTree(url: resolved)
            tree.append(FolderNode(
                id: resolved.path,
                name: root.name,
                url: resolved,
                children: children.isEmpty ? nil : children,
                isRoot: true,
                rootID: root.id
            ))
        }
        folderTree = tree
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
            lastLoadedURL = nil
            return
        }
        // 使用 selectedNode?.url 而非 URL(fileURLWithPath: id)，
        // 确保与 reloadCurrentFolder 使用同一 URL 对象，
        // 避免 URL 表示差异导致 lastLoadedURL 比对失败、token 被误增。
        guard let url = selectedNode?.url else {
            isLoading = false
            photos = []
            return
        }
        loadPhotos(from: url)
        monitor.startMonitoring(url: url)   // 内部会先停止上一次监控
    }

    /// 重新加载当前选中文件夹（监控触发 / 手动刷新）
    func reloadCurrentFolder() {
        guard let url = selectedNode?.url else { return }
        loadPhotos(from: url)
    }

    private func loadPhotos(from url: URL) {
        isLoading = true
        // 仅切换到不同文件夹时递增 token(取消在途的旧文件夹加载);
        // 同一文件夹的 reload 不递增,避免文件监控频繁触发时加载任务互相取消而永不更新
        if lastLoadedURL != url {
            loadToken += 1
            lastLoadedURL = url
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

    // MARK: - 节点级数据（侧边栏行懒加载）

    /// 递归统计节点文件夹的图片数量（含下级目录）。根作用域已激活，无需额外处理。
    func countImages(for node: FolderNode) async -> Int {
        let url = node.url
        return await Task.detached(priority: .utility) {
            PhotoLoadService.countImagesRecursively(in: url)
        }.value
    }

    /// 获取节点的预览缩略图（取该文件夹首图）。
    func previewThumbnail(for node: FolderNode) async -> NSImage? {
        let url = node.url
        // firstImageURL 是递归目录枚举，放到后台线程避免阻塞 UI（与 countImages 一致）
        let firstImage = await Task.detached(priority: .utility) {
            PhotoLoadService.firstImageURL(in: url)
        }.value
        guard let firstImage else { return nil }
        return await ThumbnailCacheService.shared.thumbnail(for: firstImage, maxPixel: 96)
    }

    /// 在 Finder 中显示某节点文件夹
    func revealFolderInFinder(_ node: FolderNode) {
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
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

    /// 在 Finder 中显示选中图片
    func revealInFinder(_ photo: PhotoItem) {
        NSWorkspace.shared.activateFileViewerSelecting([photo.url])
    }

    /// 加载图片元数据（详情面板调用，内部使用 mdls，全程异常安全）
    func loadMetadata(for url: URL) async -> ImageMetadata {
        await metadataService.loadMetadata(for: url)
    }

    /// 删除选中图片到废纸篓（原生，可恢复）
    func trashPhotos(_ ids: Set<UUID>) {
        let urls = photos.filter { ids.contains($0.id) }.map { $0.url }
        guard !urls.isEmpty else { return }
        var failedCount = 0
        for url in urls {
            var resultingURL: NSURL?
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
            } catch {
                failedCount += 1
            }
        }
        // 无论部分成功与否都刷新网格，使已删除的从界面移除
        reloadCurrentFolder()
        if failedCount > 0 {
            errorMessage = "有 \(failedCount) 张图片无法移到废纸篓"
        }
    }

    // MARK: - 发送 / 分享

    /// 当前选中图片的文件 URL
    var selectedURLs: [URL] {
        photos.filter { selectedPhotoIDs.contains($0.id) }.map { $0.url }
    }

    /// 导出到指定文件夹：弹出 NSOpenPanel 选择目标目录，复制选中图片。
    func exportSelectionToFolder() {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "导出到此文件夹"
        panel.message = "将选中的 \(urls.count) 张图片复制到该文件夹。"
        guard panel.runModal() == .OK, let dest = panel.url else { return }

        // 用户选择的目标目录需激活安全作用域以写入
        let started = dest.startAccessingSecurityScopedResource()
        defer { if started { dest.stopAccessingSecurityScopedResource() } }

        // 逐张复制：单张失败不影响其余，并统计成功/失败数向用户反馈
        var successCount = 0
        var failedCount = 0
        var lastError: String?
        for src in urls {
            let target = uniqueDestinationURL(in: dest, for: src)
            do {
                try FileManager.default.copyItem(at: src, to: target)
                successCount += 1
            } catch {
                failedCount += 1
                lastError = error.localizedDescription
            }
        }
        if failedCount > 0 {
            errorMessage = successCount > 0
                ? "已导出 \(successCount) 张，\(failedCount) 张失败：\(lastError ?? "")"
                : "导出失败：\(lastError ?? "")"
        }
    }

    /// 生成不冲突的目标路径（同名自动加序号）
    private func uniqueDestinationURL(in dir: URL, for src: URL) -> URL {
        let candidate = dir.appendingPathComponent(src.lastPathComponent)
        let fm = FileManager.default
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let base = src.deletingPathExtension().lastPathComponent
        let ext = src.pathExtension
        // 序号上限 9999，超出则回退用 UUID 保证唯一，避免理论上的无限循环
        for i in 2...9999 {
            let name = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
            let c = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: c.path) { return c }
        }
        let fallback = ext.isEmpty ? "\(base) \(UUID().uuidString)" : "\(base) \(UUID().uuidString).\(ext)"
        return dir.appendingPathComponent(fallback)
    }

    /// 复制到剪贴板：复制文件 URL；单张时额外复制图片，便于粘贴到聊天/编辑器。
    func copySelectionToClipboard() {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        let single = urls.count == 1 ? urls.first : nil
        Task.detached {
            let image = single.flatMap { NSImage(contentsOf: $0) }
            await MainActor.run {
                let pb = NSPasteboard.general
                pb.clearContents()
                var writers: [NSPasteboardWriting] = urls.map { $0 as NSURL }
                if let image { writers.append(image as NSPasteboardWriting) }
                pb.writeObjects(writers)
            }
        }
    }

    /// 作为邮件附件发送
    func sendSelectionViaEmail() {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
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
