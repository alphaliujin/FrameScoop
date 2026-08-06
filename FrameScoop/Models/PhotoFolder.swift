//
//  PhotoFolder.swift
//  FrameScoop
//
//  图片文件夹模型：封装一个用户添加的文件夹及其安全作用域书签。
//

import Foundation

/// 一个被添加到侧边栏的图片文件夹。
/// `bookmarkData` 是 macOS 安全作用域书签（Security-Scoped Bookmark），
/// 即使应用退出重启后，仍可在 App Sandbox 下重新访问该文件夹。
struct PhotoFolder: Identifiable, Hashable, Codable {

    /// 唯一标识
    let id: UUID

    /// 文件夹展示名称（取自目录名，用户可改名）
    var name: String

    /// 添加书签时记录的原始 URL（仅作展示/调试用途，实际访问须用书签解析）
    var url: URL

    /// 安全作用域书签数据，用于跨会话恢复访问权限
    var bookmarkData: Data

    init(id: UUID = UUID(),
         name: String,
         url: URL,
         bookmarkData: Data) {
        self.id = id
        self.name = name
        self.url = url
        self.bookmarkData = bookmarkData
    }
}
