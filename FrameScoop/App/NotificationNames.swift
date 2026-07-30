//
//  NotificationNames.swift
//  FrameScoop
//
//  自定义通知名称集中声明。
//

import Foundation

extension Notification.Name {
    /// 用户点击 “添加文件夹” 菜单或工具栏按钮时发出。
    /// 由 App 层的菜单命令发出，视图模型订阅后弹出 NSOpenPanel。
    static let addFolderRequested = Notification.Name("FrameScoop.addFolderRequested")
    /// 请求刷新当前文件夹
    static let refreshRequested = Notification.Name("FrameScoop.refreshRequested")
    /// 请求查看下一张（详情视图中）
    static let nextPhotoRequested = Notification.Name("FrameScoop.nextPhotoRequested")
    /// 请求查看上一张（详情视图中）
    static let previousPhotoRequested = Notification.Name("FrameScoop.previousPhotoRequested")
}
