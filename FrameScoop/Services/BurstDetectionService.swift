//
//  BurstDetectionService.swift
//  FrameScoop
//
//  连拍识别：按拍摄时间排序后，对相邻照片比较画面相似度（dHash Hamming 距离 <= 阈值）判定连拍。
//  连拍是连续拍摄，时间排序后必然相邻，故只比较相邻照片，整体 O(n)。
//  哈希计算与分组解耦：调用方负责取图算哈希（可并行 + 缓存），本服务只做纯分组逻辑 + dHash 工具。
//

import Foundation
import AppKit
import CoreGraphics

/// 连拍分组后的展示段：单张 或 连拍组（>=2 张，按时间升序）。
/// 连拍模式下，网格按段分行：连拍段独占行，单张段流式排列。
enum BurstSegment: Sendable {
    case single(PhotoItem)
    case burst([PhotoItem])   // count >= 2
}

struct BurstDetectionService {

    /// 按拍摄时间排序后，对相邻照片做「dHash 相似度」判定，分组为连拍段。
    /// - photos: 原始照片（内部按 creationDate 升序排序）
    /// - hashes: photoID -> dHash（调用方预计算）；缺失哈希的照片视为与任何照片都不相似
    /// - similarityThreshold: dHash Hamming 距离上限（越小越严格）
    static func group(
        photos: [PhotoItem],
        hashes: [String: UInt64],
        similarityThreshold: Int
    ) -> [BurstSegment] {
        // 按拍摄时间排序，保证连拍照片在序列中相邻
        let sorted = photos.sorted {
            ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast)
        }
        var segments: [BurstSegment] = []
        var current: [PhotoItem] = []
        for photo in sorted {
            if let last = current.last,
               let lh = hashes[last.id],
               let ch = hashes[photo.id] {
                let dh = (lh ^ ch).nonzeroBitCount
                if dh <= similarityThreshold {
                    current.append(photo)
                    continue
                }
            }
            // 与上一张不相似：结束当前组
            flush(current, into: &segments)
            current = [photo]
        }
        flush(current, into: &segments)
        return segments
    }

    private static func flush(_ group: [PhotoItem], into segments: inout [BurstSegment]) {
        guard !group.isEmpty else { return }
        if group.count >= 2 {
            segments.append(.burst(group))
        } else {
            segments.append(.single(group[0]))
        }
    }

    // MARK: - dHash

    /// 差值哈希（64 bit）：缩到 9×8 灰度，比较水平相邻像素（左>右 置 1）。
    /// 对连拍（同场景、小幅差异）区分度好，计算极快（32px 缩略图即可）。
    static func dHash(of image: NSImage) -> UInt64? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = 9, h = 8
        let colorSpace = CGColorSpaceCreateDeviceGray()
        var pixels = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(
            data: &pixels,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        var hash: UInt64 = 0
        var bit: UInt64 = 1
        for y in 0..<h {
            for x in 0..<(w - 1) {
                if pixels[y * w + x] > pixels[y * w + x + 1] { hash |= bit }
                bit <<= 1
            }
        }
        return hash
    }
}
