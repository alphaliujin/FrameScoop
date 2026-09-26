//
//  ScreenshotDetectionService.swift
//  FrameScoop
//
//  截屏判定：两条独立判据取或。
//  - 文件名前缀：零 I/O，覆盖不写标记的第三方工具（微信/QQ/Snipaste 等）。
//  - 文件头 EXIF UserComment：macOS 系统截屏写死的标记。
//  照片库来源由 PHAsset.mediaSubtypes 判定，不走本服务。
//

import Foundation

enum ScreenshotDetectionService {

    /// 文件名前缀特征。用前缀而非子串：子串会让「我的截图旅行.jpg」误命中。
    /// 注意「微信截图」「企业微信截图」「QQ截图」须整体入列：它们的文件名
    /// 以品牌名开头，只列「截图」前缀是匹配不到的。
    static let filenamePrefixes = [
        "截屏", "屏幕截图", "截图", "微信截图", "企业微信截图", "QQ截图",
        "Screenshot", "Screen Shot",
        "Snipaste", "CleanShot", "Shottr",
    ]

    /// 文件名前缀判据（大小写不敏感，零 I/O，纯函数）
    static func matchesFilename(_ name: String) -> Bool {
        let lower = name.lowercased()
        return filenamePrefixes.contains { lower.hasPrefix($0.lowercased()) }
    }
}
