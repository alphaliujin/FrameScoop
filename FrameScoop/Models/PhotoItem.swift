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

    /// 唯一标识（每次加载随机生成；同一文件跨会话 id 不同，
    /// 但同一会话内 photos / displayedPhotos / currentPhoto 共用同一批 id，导航与选择一致）
    let id: UUID

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

    /// 便捷构造：从 URL 与资源属性构造
    init(url: URL,
         name: String,
         size: Int64,
         creationDate: Date?,
         modificationDate: Date?) {
        self.id = UUID()
        self.url = url
        self.name = name
        self.size = size
        self.creationDate = creationDate
        self.modificationDate = modificationDate
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
