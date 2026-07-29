//
//  BookmarkStore.swift
//  FrameScoop
//
//  安全作用域书签的持久化与解析工具。
//
//  在 App Sandbox 下，用户通过 NSOpenPanel 选择的文件夹仅在当前会话可访问；
//  将其保存为 “应用级安全作用域书签” 后，应用重启仍可恢复访问权限。
//  这是 macOS 推荐的原生方案，不涉及任何内核扩展或特殊权限。
//

import Foundation

/// 负责文件夹书签的存取与解析。
final class BookmarkStore {

    /// 持久化文件位置：~/Library/Application Support/FrameScoop/folders.json
    private let fileURL: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("FrameScoop", isDirectory: true)
        // 目录不存在则创建（异常忽略，避免崩溃；读取时再处理）
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("folders.json")
    }()

    /// 读取所有已保存的文件夹
    func loadAll() -> [PhotoFolder] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        return (try? decoder.decode([PhotoFolder].self, from: data)) ?? []
    }

    /// 保存全部文件夹（覆盖写）
    func saveAll(_ folders: [PhotoFolder]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(folders) else { return }
        // 原子写，防止中途崩溃损坏文件
        try? data.write(to: fileURL, options: .atomic)
    }

    /// 解析书签为可访问的 URL。
    /// - Important: 调用方获得 URL 后须 `startAccessingSecurityScopedResource()`，
    ///   使用完毕后调用 `stopAccessingSecurityScopedResource()`。
    /// - Returns: 解析后的 URL；书签失效返回 nil（上层可提示用户重新添加）
    func resolveURL(for folder: PhotoFolder) -> URL? {
        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: folder.bookmarkData,
                              options: [.withSecurityScope],
                              relativeTo: nil,
                              bookmarkDataIsStale: &stale)
            return url
        } catch {
            #if DEBUG
            print("[BookmarkStore] 解析书签失败: \(error.localizedDescription)")
            #endif
            return nil
        }
    }

    /// 为给定 URL 创建安全作用域书签数据
    func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope],
                             includingResourceValuesForKeys: nil,
                             relativeTo: nil)
    }
}
