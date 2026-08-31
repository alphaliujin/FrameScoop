//
//  PhotoLoader.swift
//  FrameScoop
//
//  按 PhotoItem.sourceKind 分派图片/元数据加载：
//  - folder 源：ThumbnailGenerator（ImageIO 降采样）+ MetadataService（mdls）
//  - photoLibrary 源：PhotosLibraryService（PHImageManager / PHAsset）
//
//  视图层与服务层均通过此处统一取图/取元数据，新增源类型时只需在此扩展。
//

import Foundation
import AppKit

enum PhotoLoader {

    /// 缩略图（网格 / 胶片条 / 侧边栏预览）
    static func thumbnail(for item: PhotoItem, maxPixel: Int) async -> NSImage? {
        switch item.sourceKind {
        case .folder:
            guard let url = item.url else { return nil }
            // ImageIO 降采样是同步阻塞调用。若在协作线程池上执行，人脸模糊检测并发取数百张
            // 缩略图时，个别图（iCloud 占位 / 大 RAW 等）在 ImageIO 中卡住会占满协作池线程，
            // 导致 withTaskGroup 的 for await 永远调度不上来、进度死锁卡在 0。挪到 GCD 线程执行，
            // 协作池保持空闲承接 await 续体；结果不变。
            return await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(returning: ThumbnailGenerator.generate(url: url, maxPixel: maxPixel))
                }
            }
        case .photoLibrary:
            guard let id = item.assetIdentifier else { return nil }
            return await PhotosLibraryService.shared.image(for: id, maxPixel: maxPixel)
        }
    }

    /// 全尺寸大图（详情视图，最长边 2560px）
    static func fullImage(for item: PhotoItem) async -> NSImage? {
        // 串行化大图解码：详情页快速翻页/幻灯片播放时，旧任务的 GCD 解码块不可取消，
        // 并发解码多张 2560px 大图会叠加出 150-200MB 内存峰值。这里限制同时在途
        // 最多 1 张（约 20MB 解码缓冲），把峰值控制在预算内。
        await FullImageLimiter.shared.acquire()
        defer { Task { await FullImageLimiter.shared.release() } }
        // 等待槽位期间任务可能已被取消（用户已切走），不再占用解码资源
        guard !Task.isCancelled else { return nil }
        switch item.sourceKind {
        case .folder:
            guard let url = item.url else { return nil }
            // 同 thumbnail：ImageIO 降采样是同步阻塞调用，挪到 GCD 线程执行，
            // 避免占满协作池线程（详见 thumbnail 的注释）。
            return await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(returning: ThumbnailGenerator.generate(url: url, maxPixel: 2560))
                }
            }
        case .photoLibrary:
            guard let id = item.assetIdentifier else { return nil }
            return await PhotosLibraryService.shared.image(for: id, maxPixel: 2560)
        }
    }

    /// 元数据（详情面板）
    static func metadata(for item: PhotoItem) async -> ImageMetadata {
        switch item.sourceKind {
        case .folder:
            guard let url = item.url else { return .empty }
            return await MetadataService().loadMetadata(for: url)
        case .photoLibrary:
            guard let id = item.assetIdentifier else { return .empty }
            return PhotosLibraryService.shared.metadata(for: id)
        }
    }
}

/// 全尺寸大图解码并发限制器。
/// 详情页快速翻页时，`.task(id:)` 取消的只是 Swift 协作任务，已提交到 GCD 的
/// ImageIO 解码块不可取消；若不限流，GCD 会同时解码多张 2560px 大图（每张约 20MB），
/// 叠加出 150-200MB 内存峰值。本限制器让大图解码串行化（最多 1 张在途）。
actor FullImageLimiter {
    static let shared = FullImageLimiter(maxConcurrent: 1)

    private var slots: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maxConcurrent: Int) {
        slots = maxConcurrent
    }

    /// 获取一个解码槽位；无空位时挂起，等待前一个解码者归还。
    func acquire() async {
        if slots > 0 {
            slots -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    /// 归还槽位：优先交给最早等待者（槽位接力，数量不变），无等待者时直接释放。
    func release() {
        if waiters.isEmpty {
            slots += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
