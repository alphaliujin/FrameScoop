//
//  FrameScoopApp.swift
//  FrameScoop
//
//  应用入口。声明主窗口场景与全局命令菜单。
//  FrameScoop 是一款纯原生 macOS 图片浏览器：按文件夹浏览，界面模仿“照片”App。
//

import SwiftUI

@main
struct FrameScoopApp: App {

    /// 应用级共享状态：图片库视图模型（全局唯一，注入到整个视图树）
    @StateObject private var library = PhotoLibraryViewModel()

    init() {
        AppearanceConfigurator.configure()
    }

    var body: some Scene {
        // 主窗口：侧边栏 + 图片网格，双击进入沉浸式查看
        WindowGroup {
            ContentView()
                .environmentObject(library)
                .frame(minWidth: 960, minHeight: 620)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            // 用 “添加文件夹” 替换默认 “New” 菜单项
            CommandGroup(replacing: .newItem) {
                Button("添加文件夹…") {
                    NotificationCenter.default.post(name: .addFolderRequested, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button("刷新当前文件夹") {
                    NotificationCenter.default.post(name: .refreshRequested, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
            // 文件菜单加入 “在 Finder 中显示” 与 “在信息面板切换”
            CommandGroup(after: .toolbar) {
                Divider()
                Button("下一张") {
                    NotificationCenter.default.post(name: .nextPhotoRequested, object: nil)
                }
                .keyboardShortcut(.rightArrow, modifiers: [])

                Button("上一张") {
                    NotificationCenter.default.post(name: .previousPhotoRequested, object: nil)
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
            }
        }

        // 设置窗口（模仿“照片”偏好设置）
        Settings {
            SettingsView()
                .environmentObject(library)
        }
    }
}

extension Notification.Name {
    /// 请求刷新当前文件夹
    static let refreshRequested = Notification.Name("FrameScoop.refreshRequested")
    /// 请求查看下一张（详情视图中）
    static let nextPhotoRequested = Notification.Name("FrameScoop.nextPhotoRequested")
    /// 请求查看上一张（详情视图中）
    static let previousPhotoRequested = Notification.Name("FrameScoop.previousPhotoRequested")
}
