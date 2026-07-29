//
//  ThumbnailGenerator.swift
//  FrameScoop
//
//  基于 ImageIO 的原生缩略图生成器。
//  使用 CGImageSource 的降采样能力，避免将整张大图载入内存，内存占用低、速度快。
//  支持 M 系列 / Intel 芯片（纯 CoreGraphics API，无架构差异代码）。
//

import Foundation
import ImageIO
import AppKit

enum ThumbnailGenerator {

    /// 为指定图片生成缩略图。
    /// - Parameters:
    ///   - url: 图片文件 URL
    ///   - maxPixel: 最长边的最大像素数
    /// - Returns: 生成的 NSImage；失败返回 nil（调用方应降级展示占位图）
    static func generate(url: URL, maxPixel: Int) -> NSImage? {
        // 1. 创建图片源（不立即解码整张图）
        let sourceOptions = [CFString: Any]()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
            return nil
        }

        // 2. 配置缩略图降采样选项
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,   // 总是生成
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,         // 最长边像素上限
            kCGImageSourceShouldCacheImmediately: true,            // 立即解码
            kCGImageSourceCreateThumbnailWithTransform: true       // 应用 EXIF 方向
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            return nil
        }

        let size = NSSize(width: cgImage.width, height: cgImage.height)
        return NSImage(cgImage: cgImage, size: size)
    }

    /// 仅读取图片像素尺寸，不做完整解码（开销极小）
    static func pixelDimensions(of url: URL) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        guard let w = props?[kCGImagePropertyPixelWidth] as? Int,
              let h = props?[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return (w, h)
    }
}
