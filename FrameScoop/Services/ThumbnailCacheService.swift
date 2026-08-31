//
//  ThumbnailCacheService.swift
//  FrameScoop
//
//  缩略图缓存服务。
//  - 内存缓存：NSCache（系统内存紧张时自动回收）
//  - 磁盘缓存：~/Library/Caches/FrameScoop/Thumbnails，避免重复解码
//  - 生成：后台并发，使用 actor 去重防止对同一图片重复生成
//
//  性能优化：
//  - 磁盘写入用 CGImageDestination 直接 CGImage -> JPEG，跳过 tiffRepresentation
//    的未压缩 TIFF 中间缓冲（512px 图省 ~2MB 临时内存）和 NSBitmapImageRep 二次解码。
//  - 磁盘清理（pruneDiskCache）按写入计数节流：每 50 次写入才扫描一次目录，
//    避免每张缩略图落盘都触发 O(n log n) 全目录排序。
//

import Foundation
import AppKit
import ImageIO

final class ThumbnailCacheService {

    static let shared = ThumbnailCacheService()

    /// 内存缓存：key 为 "URL|size|meta" 的稳定字符串。
    /// 内存预算：48MB（countLimit 200 为次上限）。整应用内存目标 ≤200MB，
    /// 实测 4.5K Retina 下窗口合成（CG raster + IOSurface）约 90MB、AppKit/SwiftUI
    /// 堆基线约 70-100MB，缓存只能留 48MB；滚动时超出部分由磁盘缓存（JPEG 解码
    /// 数毫秒/张）兜底，换回约 30MB 的稳定内存盈余。
    private let memoryCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 200
        cache.totalCostLimit = 48 * 1024 * 1024  // 48MB
        return cache
    }()

    /// 磁盘缓存目录
    private let diskCacheDir: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = caches.appendingPathComponent("FrameScoop/Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// 在途任务去重器（actor 保证并发安全，无需手动加锁）
    private let inFlight = InFlightTracker()

    /// 清空缓存的代际号：clearCache 递增，在途生成任务据此丢弃过期写回（避免清空后被在途任务回填）。
    private let epochLock = NSLock()
    private var generationEpoch = 0

    private func currentEpoch() -> Int {
        epochLock.lock(); defer { epochLock.unlock() }
        return generationEpoch
    }

    /// 把图片放入内存缓存，按解码后像素数估算 cost（让 totalCostLimit 真正生效）。
    private func cache(_ image: NSImage, forKey key: String) {
        let pixels: Int
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            pixels = cg.width * cg.height
        } else {
            pixels = Int(image.size.width * image.size.height)
        }
        memoryCache.setObject(image, forKey: key as NSString, cost: max(1, pixels * 4))
    }

    /// 磁盘清理节流计数器：每 pruneThreshold 次写入才触发一次 pruneDiskCache
    private static let pruneCounterQueue = DispatchQueue(label: "framescoop.prune-counter")
    private nonisolated(unsafe) static var writesSincePrune = 0
    private static let pruneThreshold = 50

    private init() {}

    /// 获取缩略图：命中缓存立即返回，否则后台生成后返回。
    /// 按 item.sourceKind 分派生成（folder->ImageIO 降采样，photoLibrary->PHImageManager）。
    func thumbnail(for item: PhotoItem, maxPixel: Int) async -> NSImage? {
        // 1. 后台：计算 key 并检查内存/磁盘缓存（stat/磁盘读/JPEG 解码移出主线程，避免快速滚动阻塞 UI）
        let (key, hit): (String, NSImage?) = await Task.detached(priority: .userInitiated) { [self] in
            let key = self.cacheKey(for: item, maxPixel: maxPixel)
            if let cached = self.memoryCache.object(forKey: key as NSString) {
                return (key, cached)
            }
            if let disk = self.readFromDisk(key: key, dir: self.diskCacheDir) {
                self.cache(disk, forKey: key)
                return (key, disk)
            }
            return (key, nil)
        }.value
        if let hit { return hit }

        // 2. 未命中：去重 + 后台生成（原子 get-or-create，避免并发重复生成）
        let task = await inFlight.getOrCreate(key) { [diskCacheDir] in
            Task.detached(priority: .userInitiated) { [weak self] in
                let epoch = self?.currentEpoch() ?? 0
                let image = await PhotoLoader.thumbnail(for: item, maxPixel: maxPixel)
                // 仍把图返回给调用方（cell 能显示）；但若期间用户清了缓存（代际号变了），
                // 不回填内存/磁盘，避免「清除缓存」后被在途生成任务写回。
                if let image, let self, epoch == self.currentEpoch() {
                    self.cache(image, forKey: key)
                    self.writeToDisk(image: image, key: key, dir: diskCacheDir)
                }
                return image
            }
        }

        let result = await task.value
        await inFlight.clear(key)
        return result
    }

    /// 清空所有缓存（设置中可调用）
    func clearCache() {
        // 递增代际号：在途生成任务据此丢弃过期写回，避免清空后被回填。
        epochLock.lock(); generationEpoch += 1; epochLock.unlock()
        memoryCache.removeAllObjects()
        try? FileManager.default.removeItem(at: diskCacheDir)
        try? FileManager.default.createDirectory(at: diskCacheDir, withIntermediateDirectories: true)
    }

    // MARK: - Private

    private func cacheKey(for item: PhotoItem, maxPixel: Int) -> String {
        switch item.sourceKind {
        case .folder:
            // 文件夹源：用文件大小 + 修改时间 + 尺寸生成稳定 key，文件改动即失效
            let url = item.url ?? URL(fileURLWithPath: "/unknown")
            let attrs = (try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]))
            let size = attrs?.fileSize ?? 0
            let mtime = (attrs?.contentModificationDate?.timeIntervalSince1970).map { String($0) } ?? "0"
            return "\(url.path)|\(size)|\(mtime)|\(maxPixel)"
        case .photoLibrary:
            // 照片库源：以 localIdentifier + 尺寸为 key（PHAsset 编辑后 localIdentifier 不变，
            // 可能命中陈旧缓存；接受该权衡以换取滚动时的命中性能）
            return "ph|\(item.assetIdentifier ?? "")|\(maxPixel)"
        }
    }

    private func diskFileURL(key: String, dir: URL) -> URL {
        // 用 key 的哈希作为文件名，避免非法字符
        return dir.appendingPathComponent(key.fnv1a() + ".jpg")
    }

    private func readFromDisk(key: String, dir: URL) -> NSImage? {
        let file = diskFileURL(key: key, dir: dir)
        guard FileManager.default.fileExists(atPath: file.path),
              let data = try? Data(contentsOf: file),
              let image = NSImage(data: data) else {
            return nil
        }
        return image
    }

    private func writeToDisk(image: NSImage, key: String, dir: URL) {
        // 用 CGImageDestination 直接 CGImage -> JPEG，跳过 tiffRepresentation 的未压缩
        // TIFF 中间缓冲 + NSBitmapImageRep 二次解码，减少 ~2x 内存和 CPU 开销。
        // JPEG 质量 0.85，与之前 NSBitmapImageRep 的 compressionFactor 一致。
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutableData, "public.jpeg" as CFString, 1, nil
        ) else { return }
        CGImageDestinationAddImage(
            dest, cg,
            [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary
        )
        guard CGImageDestinationFinalize(dest) else { return }
        let data = mutableData as Data
        let file = diskFileURL(key: key, dir: dir)
        try? data.write(to: file, options: .atomic)
        // 写入后按计数节流裁剪磁盘缓存上限：切换缩略图尺寸会产生新 key 的文件，
        // 旧尺寸文件不再命中，需按数量上限回收，避免缓存目录无限膨胀。
        // 每 pruneThreshold 次写入才扫描一次目录，避免每次落盘都做 O(n log n) 排序。
        var shouldPrune = false
        Self.pruneCounterQueue.sync {
            Self.writesSincePrune += 1
            if Self.writesSincePrune >= Self.pruneThreshold {
                Self.writesSincePrune = 0
                shouldPrune = true
            }
        }
        if shouldPrune {
            Task.detached(priority: .background) { [dir] in
                Self.pruneDiskCache(dir: dir, maxFiles: 20000)
            }
        }
    }

    /// 磁盘缓存文件数超限时，按最后修改时间删除最旧的文件
    private static func pruneDiskCache(dir: URL, maxFiles: Int) {
        let fm = FileManager.default
        guard
            let files = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ),
            files.count > maxFiles
        else { return }
        let sorted = files.sorted { a, b in
            let ta = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let tb = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return ta < tb
        }
        for url in sorted.prefix(files.count - maxFiles) {
            try? fm.removeItem(at: url)
        }
    }
}

/// 在途缩略图任务的并发安全去重器。
actor InFlightTracker {
    private var tasks: [String: Task<NSImage?, Never>] = [:]

    /// 原子地获取或创建某 key 对应的生成任务
    func getOrCreate(_ key: String, make: () -> Task<NSImage?, Never>) -> Task<NSImage?, Never> {
        if let existing = tasks[key] { return existing }
        let task = make()
        tasks[key] = task
        return task
    }

    /// 任务完成后清除
    func clear(_ key: String) {
        tasks[key] = nil
    }
}

private extension String {
    /// FNV-1a 哈希：用于生成稳定的缓存文件名
    func fnv1a() -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in self.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}
