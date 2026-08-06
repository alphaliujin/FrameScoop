//
//  PhotoItem.swift
//  FrameScoop
//
//  单张图片的数据模型 -- 视图层与数据层之间传递的不可变值类型。
//

import Foundation

/// 图片来源类型：文件系统文件夹 或 系统照片库（Photos.framework，含 iCloud 同步照片）。
enum PhotoSourceKind: String, Codable, Sendable {
    case folder
    case photoLibrary
}

/// 图片项：对应一张图片。
/// - folder 源：磁盘文件，url 有值，经 ThumbnailGenerator / mdls 读取。
/// - photoLibrary 源：Photos 资产，assetIdentifier 有值、url 为 nil，
///   图片经 PHImageManager 获取、元数据来自 PHAsset。
/// 遵循 Sendable（值类型，成员均为 Sendable），可跨 actor 传递（后台取图任务捕获）。
struct PhotoItem: Identifiable, Hashable, Codable, Sendable {

    /// 唯一标识：folder 为 url.path；photoLibrary 为 "ph:" + localIdentifier。跨 reload 稳定。
    let id: String

    /// 文件 URL（folder 源有值；photoLibrary 源为 nil，图片经 PHImageManager 获取）
    let url: URL?

    /// Photos 资源 localIdentifier（photoLibrary 源有值；folder 源为 nil）
    let assetIdentifier: String?

    /// 来源类型
    var sourceKind: PhotoSourceKind

    /// 展示名称（不含路径）
    var name: String

    /// 文件大小（字节）；photoLibrary 源暂不取（留 0，界面显示 "—"）
    var size: Int64

    /// 文件创建时间
    var creationDate: Date?

    /// 文件最后修改时间
    var modificationDate: Date?

    /// 图片像素宽度
    var pixelWidth: Int

    /// 图片像素高度
    var pixelHeight: Int

    /// 文件夹源便捷构造
    init(url: URL,
         name: String,
         size: Int64,
         creationDate: Date?,
         modificationDate: Date?,
         pixelWidth: Int = 0,
         pixelHeight: Int = 0) {
        self.id = url.path
        self.url = url
        self.assetIdentifier = nil
        self.sourceKind = .folder
        self.name = name
        self.size = size
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    /// Photos 照片库源便捷构造
    init(assetIdentifier: String,
         name: String,
         creationDate: Date?,
         modificationDate: Date?,
         pixelWidth: Int,
         pixelHeight: Int) {
        self.id = "ph:" + assetIdentifier
        self.url = nil
        self.assetIdentifier = assetIdentifier
        self.sourceKind = .photoLibrary
        self.name = name
        self.size = 0
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    /// 图片宽高比；无尺寸信息时回退为 1（正方形）
    var aspectRatio: CGFloat {
        guard pixelHeight > 0 else { return 1 }
        return CGFloat(pixelWidth) / CGFloat(pixelHeight)
    }

    /// 人类可读的文件尺寸（如 "2.3 MB"）；无尺寸显示 "—"
    var formattedSize: String {
        size > 0 ? ByteCountFormatter.string(fromByteCount: size, countStyle: .file) : "—"
    }
}
