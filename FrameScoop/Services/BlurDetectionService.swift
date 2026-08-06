//
//  BlurDetectionService.swift
//  FrameScoop
//
//  人脸分析（一次 Vision 同时输出「人脸模糊」+「闭眼」）：
//  用 VNDetectFaceLandmarksRequest（constellation76Points = iBUG 68 点 + 虹膜 8 点）
//  一次取人脸 boundingBox + landmark，对每张人脸同时算：
//  - 模糊：crop 拉普拉斯方差（清晰度分数），取所有脸的 max（最清晰）/ min（最模糊）
//  - 闭眼：左右眼 6 点 iBUG 轮廓算 EAR（眼睛纵横比），取所有脸平均 EAR 的 max/min
//
//  ViewModel 按以下规则标色（threshold = blurThreshold / eyeClosedThreshold）：
//  模糊：
//  - 无人脸（faceCount == 0）-> 不标
//  - maxScore < threshold -> 所有人脸都模糊 -> 红色 face.dashed
//  - maxScore >= threshold 且 minScore < threshold -> 有清晰也有模糊 -> 黄色 face.dashed
//  - maxScore >= threshold 且 minScore >= threshold -> 全清晰 -> 不标
//  闭眼：
//  - 无眼 landmark 人脸（faceCountWithEyes == 0）-> 不标
//  - maxEAR < threshold -> 所有人脸都闭眼 -> 红色 eye.slash
//  - maxEAR >= threshold 且 minEAR < threshold -> 有睁有闭 -> 黄色 eye.slash
//  - minEAR >= threshold -> 全睁 -> 不标
//
//  拉普拉斯方差：值越大越清晰（边缘越多）；平坦 crop（极低纹理）返回哨兵避免误判。
//  EAR = (||p2-p6|| + ||p3-p5||) / (2·||p1-p4||)；闭眼时眼睑垂直距离变小、EAR 下降。
//

import Foundation
import AppKit
import CoreGraphics
import Vision

/// 一张照片的人脸模糊判定结果（同时携带闭眼分析；一次 Vision 算出）
struct FaceBlurScore: Sendable, Codable {
    /// 所有人脸中最清晰者的拉普拉斯方差（无人脸/无有效 crop 时为哨兵）
    let maxScore: Double
    /// 所有人脸中最模糊者的拉普拉斯方差（无人脸/无有效 crop 时为哨兵）
    let minScore: Double
    /// 检测到的有效人脸 crop 数（0 表示无人脸）
    let faceCount: Int
    /// 最大人脸 crop 在缩略图中的像素宽（诊断用：小脸被放大成糊的关键信号）
    let maxFaceWidthPx: Double
    /// 闭眼分析（与人脸模糊同一次 Vision 算出）。nil = 无人脸；faceCountWithEyes==0 = 有脸但无可用眼 landmark
    let eyeState: FaceEyeState?
}

/// 闭眼分析（EAR）：一次 Vision 中随人脸 landmark 一并算出，阈值变化时复用、不重取图。
struct FaceEyeState: Sendable, Codable {
    /// 能算出 EAR 的人脸数（双眼或单眼 6 点 landmark 齐全且人脸足够大）；0 表示无人脸眼可用
    let faceCountWithEyes: Int
    /// 所有人脸（平均 EAR）中最小者（最闭合）；无人脸眼时为「全睁」哨兵 1.0
    let minEAR: Double
    /// 所有人脸（平均 EAR）中最大者（最睁开）；无人脸眼时为「全睁」哨兵 1.0
    let maxEAR: Double
}

struct BlurDetectionService {

    /// FFT 尺寸（2 的幂）
    private static let n: Int = 128
    /// 平坦 crop 像素标准差阈值（8-bit）；低于此值视为低纹理，返回哨兵
    private static let flatStd: Double = 8
    /// 「不模糊」哨兵（无人脸 / 平坦 / 全零），远超任何阈值
    private static let notBlurrySentinel: Double = 1_000_000

    /// 人脸分析（一次 Vision）：返回所有脸拉普拉斯方差的 max/min 与人脸数，
    /// 以及所有脸平均 EAR 的 max/min（闭眼）。返回 nil 表示取图失败。
    static func blurScore(of image: NSImage) -> FaceBlurScore? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let observations = detectFacesWithLandmarks(in: cg)
        guard !observations.isEmpty else {
            // 无人脸：eyeState 用非空「无眼」哨兵(1.0)而非 nil，避免被缓存复用判定为「未算闭眼」
            // 而每次重跑 Vision；nil 仅留给旧版缓存条目（升级后首次重算补齐）。
            let noEyes = FaceEyeState(faceCountWithEyes: 0, minEAR: 1, maxEAR: 1)
            return FaceBlurScore(maxScore: notBlurrySentinel, minScore: notBlurrySentinel,
                                 faceCount: 0, maxFaceWidthPx: 0, eyeState: noEyes)
        }

        var maxScore: Double = -1
        var minScore: Double = .infinity
        var validCount = 0
        var maxFaceW: Double = 0
        let w = CGFloat(cg.width)
        let h = CGFloat(cg.height)
        let imageSize = CGSize(width: w, height: h)

        var earMin: Double = .infinity
        var earMax: Double = -1
        var eyeFaceCount = 0

        for obs in observations {
            // Vision bbox 归一化、origin 左下；转 CGImage 像素 rect（origin 左上）
            let bbox = obs.boundingBox
            let rect = CGRect(
                x: bbox.origin.x * w,
                y: (1 - bbox.origin.y - bbox.height) * h,
                width: bbox.width * w,
                height: bbox.height * h
            )
            guard let crop = cg.cropping(to: rect), crop.width > 0, crop.height > 0 else { continue }
            if Double(crop.width) > maxFaceW { maxFaceW = Double(crop.width) }
            // 小脸（crop < 32px）跳过：放大到 128×128 算拉普拉斯不可靠，眼 landmark 也太密不可信。
            guard crop.width >= 32, crop.height >= 32 else { continue }

            // 模糊分：拉普拉斯方差（与原算法一致）
            let cropImg = NSImage(cgImage: crop, size: NSSize(width: crop.width, height: crop.height))
            if let s = laplacianScore(of: cropImg) {
                validCount += 1
                if s > maxScore { maxScore = s }
                if s < minScore { minScore = s }
            }

            // 闭眼分：同一次 Vision 的 landmark 算 EAR（左右眼各 6 点 iBUG 轮廓）
            if let landmarks = obs.landmarks {
                let leftEAR = ear(of: landmarks.leftEye, imageSize: imageSize)
                let rightEAR = ear(of: landmarks.rightEye, imageSize: imageSize)
                let ears = [leftEAR, rightEAR].compactMap { $0 }
                if !ears.isEmpty {
                    let avg = ears.reduce(0, +) / Double(ears.count)
                    eyeFaceCount += 1
                    if avg < earMin { earMin = avg }
                    if avg > earMax { earMax = avg }
                }
            }
        }
        let blurMax = validCount == 0 ? notBlurrySentinel : maxScore
        let blurMin = validCount == 0 ? notBlurrySentinel : minScore
        // 闭眼汇总：有脸但无可用眼 landmark 时用「全睁」哨兵(1.0)，分类时 faceCountWithEyes==0 不标
        let eyeState = FaceEyeState(faceCountWithEyes: eyeFaceCount,
                                    minEAR: eyeFaceCount == 0 ? 1 : earMin,
                                    maxEAR: eyeFaceCount == 0 ? 1 : earMax)
        return FaceBlurScore(maxScore: blurMax, minScore: blurMin,
                             faceCount: validCount, maxFaceWidthPx: maxFaceW, eyeState: eyeState)
    }

    /// 异步 off-pool 版本：Vision perform / CGContext draw 是同步阻塞调用，若在协作线程池
    /// 上并发 fan-out（人脸模糊检测一次数百张），会占满协作池线程导致死锁、score 永不返回。
    /// 挪到 GCD 线程执行，协作池保持空闲承接 await 续体。结果与同步版完全一致。
    ///
    /// QoS 用 .utility 而非 .userInitiated：VNImageRequestHandler.perform 是同步阻塞调用，
    /// 内部由 Vision 的无 QoS（base priority 0）工作线程完成推理，调用线程会在其上阻塞等待。
    /// 若调用线程为 .userInitiated，即高优先级线程等待低/无优先级线程 -> QoS 优先级反转
    /// （运行时告警 "User-initiated QoS waiting on a thread without a QoS class"）。
    /// .utility 是后台图片索引的语义正确 QoS（用户可见进度但非前台阻塞），且不高于 Vision
    /// 内部线程优先级，避免反转告警；协作池仍因 continuation 挂起而不被阻塞。
    static func blurScoreAsync(of image: NSImage) async -> FaceBlurScore? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                cont.resume(returning: blurScore(of: image))
            }
        }
    }

    /// 检测人脸 + landmark（一次 VNDetectFaceLandmarksRequest）。
    /// constellation76Points = iBUG 68 点轮廓 + 虹膜 8 点；boundingBox 同 FaceRectangles，
    /// 另附 landmarks（眼睛轮廓取 leftEye/rightEye 各 6 点算 EAR）。一次 Vision 同时供模糊与闭眼。
    private static func detectFacesWithLandmarks(in cg: CGImage) -> [VNFaceObservation] {
        var faces: [VNFaceObservation] = []
        let request = VNDetectFaceLandmarksRequest { req, _ in
            if let results = req.results as? [VNFaceObservation] {
                faces = results
            }
        }
        request.constellation = .constellation76Points
        let handler = VNImageRequestHandler(cgImage: cg)
        try? handler.perform([request])
        return faces
    }

    /// 单只眼睛的 EAR（眼睛纵横比）= (||p2-p6|| + ||p3-p5||) / (2·||p1-p4||)。
    /// iBUG 68 点眼轮廓为 6 点：[0]=外角 [1][2]=上睑 [3]=内角 [4][5]=下睑。
    /// 闭眼时上下睑垂直距离收敛、EAR 下降。点数非 6（罕见）返回 nil 跳过该眼。
    /// 用 pointsInImage(imageSize:) 取像素坐标（x/y 同尺度），EAR 为距离比值、与坐标系原点朝向无关。
    /// region 取可选：legacy VNFaceLandmarks2D 的 leftEye/rightEye 为 nullable。
    private static func ear(of region: VNFaceLandmarkRegion2D?, imageSize: CGSize) -> Double? {
        guard let region else { return nil }
        let pts = region.pointsInImage(imageSize: imageSize)
        guard pts.count == 6 else { return nil }
        let p1 = pts[0], p2 = pts[1], p3 = pts[2], p4 = pts[3], p5 = pts[4], p6 = pts[5]
        let horizontal = distance(p1, p4)
        guard horizontal > 0 else { return nil }
        let vertical = distance(p2, p6) + distance(p3, p5)
        return vertical / (2 * horizontal)
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = Double(a.x - b.x)
        let dy = Double(a.y - b.y)
        return (dx * dx + dy * dy).squareRoot()
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

        // 对比度归一化：把像素标准差拉到固定 targetStd，消除肤色/光照对比度偏差。
        // 拉普拉斯方差 ∝ 对比度²，白皮肤+浅眉/浅睫局部对比度低 => 边缘响应弱 => 清晰
        // 侧脸也被误判模糊。归一化后所有脸在同一对比度基线上比「边缘结构」，与肤色无关。
        let targetStd: Double = 50
        let cScale = targetStd / pStd
        for i in 0..<(N * N) {
            let r = (Double(pixels[i]) - pMean) * cScale + pMean
            pixels[i] = r <= 0 ? 0 : (r >= 255 ? 255 : UInt8(r))
        }

        // 拉普拉斯响应：先算每个像素的 3×3 核响应存入 resp
        var resp = [Double](repeating: 0, count: N * N)
        for y in 1..<(N - 1) {
            for x in 1..<(N - 1) {
                let i = y * N + x
                let val = Int(pixels[i - N])
                        + Int(pixels[i - 1])
                        - 4 * Int(pixels[i])
                        + Int(pixels[i + 1])
                        + Int(pixels[i + N])
                resp[i] = Double(val)
            }
        }
        // 取「最清晰子块」的拉普拉斯方差：整块方差会被侧脸 crop 里的大片平坦
        // （脸颊/头发/背景）拉低，把清晰的侧脸误判成模糊；取最清晰的 4×4 子块衡量
        // 「是否存在清晰细节」，对人脸姿态更鲁棒（正脸/侧脸都能取到眼睛等高频区）。
        let blocks = 4
        let bs = N / blocks
        var maxVar: Double = 0
        for by in 0..<blocks {
            for bx in 0..<blocks {
                var sSum: Double = 0, sSumSq: Double = 0, sCount = 0
                let y0 = by * bs + 1, y1 = Swift.min((by + 1) * bs, N - 1)
                let x0 = bx * bs + 1, x1 = Swift.min((bx + 1) * bs, N - 1)
                for y in y0..<y1 {
                    for x in x0..<x1 {
                        let d = resp[y * N + x]
                        sSum += d; sSumSq += d * d; sCount += 1
                    }
                }
                guard sCount > 0 else { continue }
                let sMean = sSum / Double(sCount)
                let sVar = sSumSq / Double(sCount) - sMean * sMean
                if sVar > maxVar { maxVar = sVar }
            }
        }
        guard maxVar > 0 else { return notBlurrySentinel }
        return maxVar
    }
}
