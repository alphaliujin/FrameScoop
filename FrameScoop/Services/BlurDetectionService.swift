//
//  BlurDetectionService.swift
//  FrameScoop
//
//  人脸模糊判断：先用 Vision 检测人脸，对每张人脸 crop 算拉普拉斯方差（清晰度分数），
//  返回所有人脸分数的「最大值（最清晰脸）」和「最小值（最模糊脸）」及人脸数。
//
//  ViewModel 按以下规则标色（threshold = blurThreshold）：
//  - 无人脸（faceCount == 0）-> 不标
//  - maxScore < threshold -> 所有人脸都模糊 -> 红色感叹号
//  - maxScore >= threshold 且 minScore < threshold -> 有清晰也有模糊 -> 黄色感叹号
//  - maxScore >= threshold 且 minScore >= threshold -> 全清晰 -> 不标
//
//  拉普拉斯方差：值越大越清晰（边缘越多）；平坦 crop（极低纹理）返回哨兵避免误判。
//

import Foundation
import AppKit
import CoreGraphics
import Vision

/// 一张照片的人脸模糊判定结果
struct FaceBlurScore: Sendable {
    /// 所有人脸中最清晰者的拉普拉斯方差（无人脸/无有效 crop 时为哨兵）
    let maxScore: Double
    /// 所有人脸中最模糊者的拉普拉斯方差（无人脸/无有效 crop 时为哨兵）
    let minScore: Double
    /// 检测到的有效人脸 crop 数（0 表示无人脸）
    let faceCount: Int
}

struct BlurDetectionService {

    /// FFT 尺寸（2 的幂）
    private static let n: Int = 128
    /// 平坦 crop 像素标准差阈值（8-bit）；低于此值视为低纹理，返回哨兵
    private static let flatStd: Double = 8
    /// 「不模糊」哨兵（无人脸 / 平坦 / 全零），远超任何阈值
    private static let notBlurrySentinel: Double = 1_000_000

    /// 人脸模糊判定：返回所有脸拉普拉斯方差的 max/min 与人脸数。返回 nil 表示取图失败。
    static func blurScore(of image: NSImage) -> FaceBlurScore? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let faceRects = detectFaces(in: cg)
        guard !faceRects.isEmpty else {
            return FaceBlurScore(maxScore: notBlurrySentinel, minScore: notBlurrySentinel, faceCount: 0)
        }

        var maxScore: Double = -1
        var minScore: Double = .infinity
        var validCount = 0
        let w = CGFloat(cg.width)
        let h = CGFloat(cg.height)
        for bbox in faceRects {
            // Vision bbox 归一化、origin 左下；转 CGImage 像素 rect（origin 左上）
            let rect = CGRect(
                x: bbox.origin.x * w,
                y: (1 - bbox.origin.y - bbox.height) * h,
                width: bbox.width * w,
                height: bbox.height * h
            )
            guard let crop = cg.cropping(to: rect), crop.width > 0, crop.height > 0 else { continue }
            let cropImg = NSImage(cgImage: crop, size: NSSize(width: crop.width, height: crop.height))
            guard let s = laplacianScore(of: cropImg) else { continue }
            validCount += 1
            if s > maxScore { maxScore = s }
            if s < minScore { minScore = s }
        }
        if validCount == 0 {
            return FaceBlurScore(maxScore: notBlurrySentinel, minScore: notBlurrySentinel, faceCount: 0)
        }
        return FaceBlurScore(maxScore: maxScore, minScore: minScore, faceCount: validCount)
    }

    /// 检测人脸，返回归一化 boundingBox 列表（Vision 坐标：origin 左下）
    private static func detectFaces(in cg: CGImage) -> [CGRect] {
        var faces: [CGRect] = []
        let request = VNDetectFaceRectanglesRequest { req, _ in
            if let results = req.results as? [VNFaceObservation] {
                faces = results.map { $0.boundingBox }
            }
        }
        let handler = VNImageRequestHandler(cgImage: cg)
        try? handler.perform([request])
        return faces
    }

    /// 单个人脸 crop 的拉普拉斯方差（清晰度分数）：值越大越清晰；平坦/全零返回哨兵。
    /// 灰度 -> 3×3 拉普拉斯核卷积 -> 响应方差。
    private static func laplacianScore(of image: NSImage) -> Double? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let N = n
        let colorSpace = CGColorSpaceCreateDeviceGray()
        var pixels = [UInt8](repeating: 0, count: N * N)
        guard let ctx = CGContext(
            data: &pixels,
            width: N,
            height: N,
            bitsPerComponent: 8,
            bytesPerRow: N,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(N), height: CGFloat(N)))

        // 平坦排除：像素标准差极低（低纹理）直接判不模糊
        var pSum: Double = 0
        var pSumSq: Double = 0
        for v in pixels {
            let d = Double(v)
            pSum += d
            pSumSq += d * d
        }
        let pN = Double(pixels.count)
        let pMean = pSum / pN
        let pStd = (pSumSq / pN - pMean * pMean).squareRoot()
        if pStd < flatStd { return notBlurrySentinel }

        // 拉普拉斯核 [0,1,0; 1,-4,1; 0,1,0]，累加响应的 sum 与 sumSq 算方差
        var sum: Double = 0
        var sumSq: Double = 0
        var count = 0
        for y in 1..<(N - 1) {
            for x in 1..<(N - 1) {
                let i = y * N + x
                let val = Int(pixels[i - N])
                        + Int(pixels[i - 1])
                        - 4 * Int(pixels[i])
                        + Int(pixels[i + 1])
                        + Int(pixels[i + N])
                let d = Double(val)
                sum += d
                sumSq += d * d
                count += 1
            }
        }
        guard count > 0 else { return notBlurrySentinel }
        let mean = sum / Double(count)
        return sumSq / Double(count) - mean * mean
    }
}
