//
//  ContentView.swift
//  FrameScoop
//
//  主内容视图：两栏 NavigationSplitView（侧边栏 + 图片网格）。
//  双击图片时以毛玻璃沉浸式详情视图覆盖主窗口。
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var library: PhotoLibraryViewModel

    var body: some View {
        ZStack {
            // 两栏布局：侧边栏 + 图片网格
            NavigationSplitView {
                SidebarView()
                    .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
            } detail: {
                PhotoGridView()
            }
            .navigationTitle(library.selectedNode?.name ?? "FrameScoop")

            // 沉浸式详情视图（毛玻璃覆盖层）
            if library.isShowingDetail, let photo = library.currentPhoto {
                PhotoDetailView(photo: photo)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        // 选中文件夹节点变化时加载其内容。onChange 在视图更新事务之后执行，
        // 因此 loadContent 内修改 @Published 是安全的（不会在 view updates 期间发布）。
        .onChange(of: library.selectedNodeID) { _, newID in
            library.loadContent(for: newID)
        }
        // 错误提示弹窗
        .alert("出错了", isPresented: Binding(
            get: { library.errorMessage != nil },
            set: { if !$0 { library.errorMessage = nil } }
        )) {
            Button("好") { library.errorMessage = nil }
        } message: {
            Text(library.errorMessage ?? "")
        }
    }
}
