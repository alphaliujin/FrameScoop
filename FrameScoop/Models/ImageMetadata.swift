//
//  ImageMetadata.swift
//  FrameScoop
//
//  图片扩展元数据模型：尺寸、拍摄设备、EXIF 等信息，用于详情面板展示。
//

import Foundation

/// 图片的富元数据。
/// 尺寸字段通过 CGImageSource（原生 API）可靠获取；
/// 拍摄信息等字段通过 `mdls`（Spotlight 命令行）安全读取，读取失败时留空。
struct ImageMetadata: Hashable {
    var pixelWidth: Int?
    var pixelHeight: Int?
    var colorSpace: String?
    var depth: Int?                    // 色彩位深
    var dpi: Int?
    var cameraMake: String?           // 厂商
    var cameraModel: String?           // 相机型号
    var lensModel: String?             // 镜头
    var focalLength: Double?           // 焦距 mm
    var fNumber: Double?               // 光圈
    var isoSpeed: Int?                 // ISO
    var exposureTime: String?           // 快门速度（文本，如 "1/250 s"）
    var takenDate: String?             // 拍摄时间（原始字符串）
    var gpsLatitude: Double?
    var gpsLongitude: Double?

    /// 是否含任何拍摄设备信息
    var hasCameraInfo: Bool {
        cameraMake != nil || cameraModel != nil || lensModel != nil
    }

    /// 空对象（加载失败时使用）
    static let empty = ImageMetadata()
}
