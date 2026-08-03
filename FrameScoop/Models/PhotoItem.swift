//
//  PhotoItem.swift
//  FrameScoop
//
//  单张图片的数据模型 -- 视图层与数据层之间传递的不可变值类型。
//

import Foundation

/// 图片项：对应磁盘上的一个图片文件。
/// 遵循 `Identifiable` 以便在 SwiftUI 列表/网格中渲染；
/// 遵循 `Hashable` 以支持选择与导航；
/// 遵循 `Codable` 以备未来持久化浏览记录（当前未持久化）。
struct PhotoItem: Identifiable, Hashable, Codable {

    /// 唯一标识：基于文件 URL 路径，跨会话与跨 reload 稳定。
    /// 同一文件在 photos / displayedPhotos / currentPhoto / selectedPhotoIDs 中 id 始终一致，
    /// 故文件监控触发的 reload 不会让导航索引、选择高亮、胶片条当前格失配。
    let id: String

    /// 图片文件在磁盘上的 URL（沙盒内已通过安全作用域书签授权）
    let url: URL

    /// 文件名（不含路径），用于界面展示
    var name: String

    /// 文件大小（字节）
    var size: Int64

    /// 文件创建时间
    var creationDate: Date?

    /// 文件最后修改时间
    var modificationDate: Date?

    /// 图片像素宽度（用于网格按比例排版）
    var pixelWidth: Int

    /// 图片像素高度（用于网格按比例排版）
    var pixelHeight: Int

    /// 便捷构造：从 URL 与资源属性构造
    init(url: URL,
         name: String,
         size: Int64,
         creationDate: Date?,
         modificationDate: Date?,
         pixelWidth: Int = 0,
         pixelHeight: Int = 0) {
        self.id = url.path
        self.url = url
        self.name = name
        self.size = size
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

    /// 人类可读的文件尺寸（如 “2.3 MB”）
    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    /// 排序/分组用的日期：优先修改时间，其次创建时间
    var effectiveDate: Date {
        modificationDate ?? creationDate ?? .distantPast
    }
}
