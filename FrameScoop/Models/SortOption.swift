//
//  SortOption.swift
//  FrameScoop
//
//  排序选项与排序方向的枚举定义。
//

import Foundation

/// 图片排序维度
enum SortOption: String, CaseIterable, Codable {
    /// 按添加到库的时间（即文件修改时间）
    case dateModified
    /// 按文件创建时间
    case dateCreated
    /// 按文件名
    case name
    /// 按文件大小
    case size

    /// 菜单展示文案
    var label: String {
        switch self {
        case .dateModified: return "修改时间"
        case .dateCreated:  return "创建时间"
        case .name:         return "名称"
        case .size:         return "大小"
        }
    }

    /// 系统 SF Symbol 图标
    var systemImage: String {
        switch self {
        case .dateModified: return "calendar.badge.clock"
        case .dateCreated:  return "calendar"
        case .name:         return "textformat"
        case .size:         return "arrow.up.and.down.and.sparkles"
        }
    }
}

/// 排序方向
enum SortOrder: String, CaseIterable, Codable {
    case ascending
    case descending

    var label: String {
        switch self {
        case .ascending:  return "升序"
        case .descending: return "降序"
        }
    }

    var systemImage: String {
        switch self {
        case .ascending:  return "arrow.up"
        case .descending: return "arrow.down"
        }
    }
}

/// 缩略图尺寸档位：同时控制网格列宽与生成的缩略图分辨率
enum ThumbnailSize: String, CaseIterable, Codable {
    case small
    case medium
    case large
    case extraLarge

    /// 网格单元格最小尺寸（点）
    var cellSize: CGFloat {
        switch self {
        case .small:       return 92
        case .medium:      return 132
        case .large:       return 184
        case .extraLarge:  return 240
        }
    }

    /// 生成缩略图的最大像素边（@2x 友好）
    var maxPixel: Int {
        switch self {
        case .small:       return 256
        case .medium:      return 384
        case .large:       return 512
        case .extraLarge:  return 720
        }
    }

    var label: String {
        switch self {
        case .small:       return "小"
        case .medium:      return "中"
        case .large:       return "大"
        case .extraLarge:  return "特大"
        }
    }
}
