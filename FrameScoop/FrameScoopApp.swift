//
//  FrameScoopApp.swift
//  FrameScoop
//
//  应用入口。声明主窗口场景与全局命令菜单。
//  FrameScoop 是一款纯原生 macOS 图片浏览器：按文件夹浏览，界面模仿"照片"App。
//

import SwiftUI

@main
struct FrameScoopApp: App {

    /// 应用级共享状态：图片库视图模型（全局唯一，注入到整个视图树）
    @StateObject private var library = PhotoLibraryViewModel()

    var body: some Scene {
        // 主窗口：侧边栏 + 图片网格，双击在新窗口查看大图
        WindowGroup {
            ContentView()
                .environmentObject(library)
                .frame(minWidth: 960, minHeight: 620)
                .onOpenURL { url in
                    // 支持将文件夹拖入 Dock 图标或经 Finder「打开方式」直接加入侧边栏
                    //（Info.plist 中 CFBundleDocumentTypes 声明了 public.folder 文档类型）
                    if url.hasDirectoryPath {
                        library.addRootURL(url)
                    }
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            // 用 "添加文件夹" 替换默认 "New" 菜单项
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
            // 文件菜单加入 "在 Finder 中显示" 与 "在信息面板切换"
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

        // 图片详情窗口（独立窗口）
        // 通过 DetailWindowRoot 包裹：currentPhoto 变 nil（切换文件夹）时自动关闭窗口，
        // 窗口被关闭（红色按钮）时清理 currentPhoto，避免状态残留。
        Window("图片详情", id: "photo-detail") {
            DetailWindowRoot()
                .environmentObject(library)
        }
        .defaultSize(width: 1000, height: 700)

        // 设置窗口（模仿"照片"偏好设置）
        Settings {
            SettingsView()
                .environmentObject(library)
        }
    }
}

// MARK: - 详情窗口根视图

/// 详情窗口的根容器：负责在 currentPhoto 被清空时关闭窗口，
/// 并在窗口被用户关闭时回写清理 currentPhoto。
private struct DetailWindowRoot: View {
    @EnvironmentObject var library: PhotoLibraryViewModel
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if let photo = library.currentPhoto {
                PhotoDetailView(photo: photo)
            } else {
                Color.clear
            }
        }
        // 切换文件夹 / 移除当前图片导致 currentPhoto 变 nil 时，关闭详情窗口（避免空白窗口）
        .onChange(of: library.currentPhoto) { _, newValue in
            if newValue == nil { dismissWindow(id: "photo-detail") }
        }
        // 用户点窗口关闭按钮（红色交通灯）时清理 currentPhoto，避免残留状态
        .onDisappear {
            if library.currentPhoto != nil { library.currentPhoto = nil }
        }
    }
}
