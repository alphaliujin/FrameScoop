//
//  MetadataService.swift
//  FrameScoop
//
//  图片元数据服务。
//
//  策略：
//  - 像素尺寸/色彩空间：使用原生 CGImageSource 读取（可靠、快）。
//  - 拍摄设备/EXIF（相机型号、光圈、ISO、焦距等）：调用系统命令 `mdls`（Spotlight 元数据）读取，
//    全程通过 ShellExecutor 做异常捕获与超时保护，任何失败都静默降级为空值，绝不崩溃。
//

import Foundation
import ImageIO

struct MetadataService {

    private let shell = ShellExecutor.shared

    /// 加载某图片的完整元数据
    func loadMetadata(for url: URL) async -> ImageMetadata {
        var meta = ImageMetadata()

        // 1) 原生 CGImageSource：像素尺寸、色彩空间、位深、DPI
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            // 使用字符串键（CGImage 属性字典的键即这些字符串），避免不同 SDK 的常量符号差异
            if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
                meta.pixelWidth = props["PixelWidth"] as? Int
                meta.pixelHeight = props["PixelHeight"] as? Int
                meta.colorSpace = props["ColorSpace"] as? String
                meta.depth = props["Depth"] as? Int
                if let dpi = props["DPIWidth"] as? Int { meta.dpi = dpi }
            }
        }

        // 2) 系统命令 mdls：读取 Spotlight 富元数据（含 EXIF）
        //    ShellExecutor 全程异常捕获 + 超时 8s 自动终止；
        //    像素尺寸已由上方 CGImageSource 取得，故不再向 mdls 请求 kMDItemPixelWidth/Height。
        //    在 GCD 全局队列执行阻塞调用（而非 Task.detached 协作线程池）：
        //    waitUntilExit 最长阻塞 8s，占用协作 worker 会饿死协作任务；GCD 队列可独立扩容线程，
        //    通过 continuation 桥接回 async。
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<ShellResult, Never>) in
            DispatchQueue.global(qos: .utility).async { [shell] in
                let res = shell.run(
                    "/usr/bin/mdls",
                    arguments: [
                        "-name", "kMDItemAcquisitionMake",
                        "-name", "kMDItemAcquisitionModel",
                        "-name", "kMDItemFocalLength",
                        "-name", "kMDItemFNumber",
                        "-name", "kMDItemISOSpeed",
                        "-name", "kMDItemExposureTimeSeconds",
                        "-name", "kMDItemContentCreationDate",
                        "-raw",
                        url.path
                    ],
                    timeout: 8
                )
                continuation.resume(returning: res)
            }
        }

        guard result.isSuccess else {
            #if DEBUG
            print("[MetadataService] mdls 失败/超时: \(result.stderr)")
            #endif
            return meta
        }

        // mdls -raw 多属性时按行输出，按请求顺序对应
        let lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: false)
        func line(_ i: Int) -> String? {
            guard i < lines.count else { return nil }
            let s = String(lines[i]).trimmingCharacters(in: .whitespaces)
            return (s.isEmpty || s == "(null)") ? nil : s
        }

        meta.cameraMake = line(0)
        meta.cameraModel = line(1)
        meta.focalLength = line(2).flatMap { Double($0) }
        meta.fNumber = line(3).flatMap { Double($0) }
        meta.isoSpeed = line(4).flatMap { Int($0) }
        if let expSec = line(5).flatMap({ Double($0) }) {
            // 把秒数格式化为 “1/250 s” 或 “0.5 s”
            meta.exposureTime = formatExposureTime(seconds: expSec)
        }
        meta.takenDate = line(6)

        return meta
    }

    /// 把曝光秒数格式化为人类可读的快门速度
    private func formatExposureTime(seconds: Double) -> String {
        if seconds >= 1 {
            return String(format: "%.1f s", seconds)
        }
        // 短于 1 秒，优先用分数表示（标准快门档位如 1/125、1/250）
        let reciprocal = 1.0 / seconds
        let denom = Int(reciprocal.rounded())
        // 仅当倒数接近整数且 ≥ 2 时用分数，避免 0.75s 被错写成 "1/1 s"
        if denom >= 2 && abs(reciprocal - Double(denom)) < 0.1 {
            return "1/\(denom) s"
        }
        return String(format: "%.3f s", seconds)
    }
}
