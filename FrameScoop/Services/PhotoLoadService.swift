//
//  PhotoLoadService.swift
//  FrameScoop
//
//  从文件夹加载图片项的服务。
//  使用 FileManager 枚举器递归扫描所有下级目录（“按文件夹看图”含子目录），
//  支持常见图片格式（含 HEIC/RAW）。所有 IO 操作在后台线程执行。
//

import Foundation
import ImageIO

struct PhotoLoadService {

    /// 支持的图片扩展名（小写）
    static let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif",
        "gif", "tiff", "tif", "bmp", "webp",
        "raw", "cr2", "cr3", "nef", "arw", "dng", "raf", "orf"
    ]

    /// 加载某文件夹下（含所有下级目录）的全部图片项。
    /// - Parameter url: 已授权（安全作用域已激活）的文件夹 URL
    /// - Returns: 图片项数组（未排序，含子目录中的图片）
    func loadPhotos(from url: URL) async -> [PhotoItem] {
        // 在后台优先级线程执行文件枚举，避免阻塞 UI
        await Task.detached(priority: .userInitiated) { [url] in
            let fm = FileManager.default
            let resourceKeys: Set<URLResourceKey> = [
                .creationDateKey,
                .contentModificationDateKey,
                .fileSizeKey,
                .isDirectoryKey,
                .isHiddenKey
            ]

            // 注意：不带 .skipsSubdirectoryDescendants，递归进入所有下级目录
            guard let enumerator = fm.enumerator(
                at: url,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles]
            ) else {
                return [PhotoItem]()
            }

            var items: [PhotoItem] = []
            items.reserveCapacity(256)
            // 使用 nextObject() 而非 for-in，避免在异步上下文中使用同步迭代器（Swift 6 兼容）
            while let fileURL = enumerator.nextObject() as? URL {
                // 异常隔离：单个文件读取失败不应中断整个枚举
                guard let values = try? fileURL.resourceValues(forKeys: resourceKeys) else { continue }
                guard values.isDirectory == false else { continue }

                let ext = fileURL.pathExtension.lowercased()
                guard Self.supportedExtensions.contains(ext) else { continue }

                // 校验文件是否为有效图片：CGImageSource 无法识别类型或无图像帧的文件跳过
                // （扩展名是图片但内容损坏/不匹配的文件不会进入列表）
                guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
                      CGImageSourceGetType(source) != nil,
                      CGImageSourceGetCount(source) > 0 else { continue }

                // 读取图片像素尺寸用于网格按比例排版（仅读元数据，不解码全图）
                var pxW = 0, pxH = 0
                if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                    pxW = props[kCGImagePropertyPixelWidth] as? Int ?? 0
                    pxH = props[kCGImagePropertyPixelHeight] as? Int ?? 0
                }

                let item = PhotoItem(
                    url: fileURL,
                    name: fileURL.deletingPathExtension().lastPathComponent,
                    size: Int64(values.fileSize ?? 0),
                    creationDate: values.creationDate,
                    modificationDate: values.contentModificationDate,
                    pixelWidth: pxW,
                    pixelHeight: pxH
                )
                items.append(item)
            }
            return items
        }.value
    }

    /// 递归统计文件夹下（含所有下级目录）的图片总数。
    /// 仅按扩展名计数，不读取资源属性，开销小于完整枚举。用于侧边栏计数。
    /// - Parameter url: 已激活安全作用域的文件夹 URL
    /// - Returns: 图片文件数量
    static func countImagesRecursively(in url: URL) -> Int {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]   // 递归
        ) else {
            return 0
        }
        var count = 0
        while let fileURL = enumerator.nextObject() as? URL {
            if Self.supportedExtensions.contains(fileURL.pathExtension.lowercased()) {
                count += 1
            }
        }
        return count
    }

    /// 在文件夹中（含所有下级目录）查找第一张图片的 URL。
    /// 用于侧边栏相簿风格的缩略图预览，开销远小于枚举全部文件。
    /// - Parameter url: 已激活安全作用域的文件夹 URL
    /// - Returns: 第一张图片的 URL；无图片时返回 nil
    static func firstImageURL(in url: URL) -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]   // 递归
        ) else {
            return nil
        }
        while let fileURL = enumerator.nextObject() as? URL {
            let ext = fileURL.pathExtension.lowercased()
            if Self.supportedExtensions.contains(ext) {
                return fileURL
            }
        }
        return nil
    }

    /// 递归构建文件夹的子目录树（仅目录，不枚举图片文件，速度快）。
    /// 用于侧边栏「逐级展开」。调用前须确保该文件夹的安全作用域已激活。
    /// - Parameters:
    ///   - url: 已激活安全作用域的文件夹 URL
    ///   - depth: 当前递归深度，用于防止极深目录树导致栈溢出
    /// - Returns: 子目录节点数组（按名称排序）；无子目录返回空数组
    static func buildFolderTree(url: URL, depth: Int = 0) -> [FolderNode] {
        // 深度上限：防止异常深度目录树（或符号链接环）造成递归过深
        guard depth < 32 else { return [] }
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let subdirs = contents.filter { entry in
            let rv = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            // 仅进入真实子目录，跳过符号链接，避免链接环导致无限递归
            return rv?.isSymbolicLink == false && rv?.isDirectory == true
        }.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        return subdirs.map { sub in
            let childTree = buildFolderTree(url: sub, depth: depth + 1)
            return FolderNode(
                id: sub.path,
                name: sub.lastPathComponent,
                url: sub,
                children: childTree.isEmpty ? nil : childTree,
                isRoot: false,
                rootID: nil
            )
        }
    }
}
