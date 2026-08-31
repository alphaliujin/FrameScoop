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
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        // 2. 先校验源是否“可生成缩略图”，避免对非图片 / 不完整文件调用缩略图 API
        //    而触发 CGImageSourceCreateThumbnailAtIndex 的 -50（paramErr）错误日志。
        //    - type 为 nil：ImageIO 无法识别该文件为图片（如扩展名是图片但内容不是、0 字节文件）
        //    - count == 0：源中无任何图像帧
        //    - status 为 incomplete / invalidData / unexpectedEOF：数据不完整或损坏（如文件正在拷贝）
        let status = CGImageSourceGetStatus(source)
        guard CGImageSourceGetType(source) != nil,
              CGImageSourceGetCount(source) > 0,
              status != .statusIncomplete,
              status != .statusInvalidData,
              status != .statusUnexpectedEOF else {
            return nil
        }

        // 3. 配置缩略图降采样选项
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,   // 总是生成
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,         // 最长边像素上限
            kCGImageSourceShouldCacheImmediately: true,            // 立即解码
            kCGImageSourceCreateThumbnailWithTransform: true       // 应用 EXIF 方向
        ]

        if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) {
            let size = NSSize(width: cgImage.width, height: cgImage.height)
            return NSImage(cgImage: cgImage, size: size)
        }

        // 4. 回退：少数图片 CG 缩略图接口失败但仍可解码，复用同一 source 直读解码并缩放
        return nsImageFallback(source: source, maxPixel: maxPixel)
    }

    /// NSImage 回退缩略图：CGImageSource 缩略图接口失败时使用。
    /// 用 CGImageSourceCreateImageAtIndex 直读解码（而非 NSImage(contentsOf:)——后者会持有
    /// CGImage 与多份位图表示，内存约为像素数据的 2 倍），解码后立即绘制到缩小后的
    /// CGContext 并丢弃原图。CoreGraphics 绘制线程安全，可在后台任务中调用。
    /// 超大图（像素数 > 16MP）直接放弃回退：全量解码 RGBA 会超过 64MB，可能把整应用
    /// 内存峰值推出预算（目标 ≤200MB）；此类图片走主缩略图路径（JPEG 预览嵌入的 RAW
    /// 等可正常降采样），此处仅兜底少数损坏/占位文件。
    private static func nsImageFallback(source: CGImageSource, maxPixel: Int) -> NSImage? {
        // 超大图保护：全量解码前先读像素尺寸，超过 16MP 即放弃
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? Int,
           let h = props[kCGImagePropertyPixelHeight] as? Int,
           w > 0, h > 0,
           w * h > 16 * 1024 * 1024 {
            return nil
        }
        guard let cg = CGImageSourceCreateImageAtIndex(
            source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        ) else { return nil }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return nil }
        // 等比缩放，最长边不超过 maxPixel
        let scale = min(CGFloat(maxPixel) / CGFloat(w), CGFloat(maxPixel) / CGFloat(h), 1)
        let tw = max(1, Int((CGFloat(w) * scale).rounded()))
        let th = max(1, Int((CGFloat(h) * scale).rounded()))
        guard let ctx = CGContext(
            data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: tw, height: th))
        guard let out = ctx.makeImage() else { return nil }
        return NSImage(cgImage: out, size: NSSize(width: tw, height: th))
    }

}
