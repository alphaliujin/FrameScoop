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
            return ThumbnailGenerator.generate(url: url, maxPixel: maxPixel)
        case .photoLibrary:
            guard let id = item.assetIdentifier else { return nil }
            return await PhotosLibraryService.shared.image(for: id, maxPixel: maxPixel)
        }
    }

    /// 全尺寸大图（详情视图，最长边 2560px）
    static func fullImage(for item: PhotoItem) async -> NSImage? {
        switch item.sourceKind {
        case .folder:
            guard let url = item.url else { return nil }
            return ThumbnailGenerator.generate(url: url, maxPixel: 2560)
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
