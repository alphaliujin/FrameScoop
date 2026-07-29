//
//  SidebarView.swift
//  FrameScoop
//
//  侧边栏：文件夹「逐级展开」的树形列表（仿 Finder / 照片侧边栏）。
//
//  - 根节点 = 用户添加的文件夹（可重命名 / 移除）
//  - 子节点 = 子目录，递归构建，可逐级展开
//  - 每行相簿风格：首图缩略预览 + 名称 + 递归图片数（懒加载）
//  - 选中任意节点由 ContentView 的 onChange 触发加载
//

import SwiftUI
import AppKit

struct SidebarView: View {
    @EnvironmentObject var library: PhotoLibraryViewModel
    @State private var renamingNodeID: String?
    /// 列表选择的本地状态。绑定到 List 的 selection（@State 在视图更新期间修改总是安全）。
    /// 与视图模型的 selectedNodeID 通过下方两个 onChange 双向同步，
    /// 避免直接把 @Published 绑定到 List 而在点击时触发“publishing during view updates”。
    @State private var selection: String?

    var body: some View {
        // 带子节点的 List：自动渲染展开三角。selection 绑定到本地 @State（非 @Published）。
        List(library.folderTree, children: \.children, selection: $selection) { node in
            FolderTreeRow(node: node, renamingNodeID: $renamingNodeID)
        }
        .listStyle(.sidebar)
        .overlay {
            if library.folderTree.isEmpty {
                ContentUnavailableView {
                    Label("还没有文件夹", systemImage: "folder.badge.plus")
                } description: {
                    Text("点击下方按钮添加图片文件夹")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            addFolderButton
        }
        // 本地选择 -> 视图模型（onChange 在更新事务之后执行，安全）
        .onChange(of: selection) { _, newID in
            if library.selectedNodeID != newID { library.selectedNodeID = newID }
        }
        // 视图模型 -> 本地选择（程序化选中时同步，如启动选中首项 / 添加 / 移除）
        .onChange(of: library.selectedNodeID) { _, id in
            if id != selection { selection = id }
        }
    }

    private var addFolderButton: some View {
        Button {
            library.addFolder()
        } label: {
            Label("添加文件夹", systemImage: "plus")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .padding()
    }
}

// MARK: - 树行（相簿风格）

private struct FolderTreeRow: View {
    let node: FolderNode
    @Binding var renamingNodeID: String?
    @State private var renameText: String = ""
    @State private var count: Int?
    @State private var thumbnail: NSImage?
    @EnvironmentObject var library: PhotoLibraryViewModel

    private var isRenaming: Bool { renamingNodeID == node.id }

    var body: some View {
        HStack(spacing: 10) {
            FolderPreviewImage(node: node, image: $thumbnail)
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            if isRenaming {
                TextField("名称", text: $renameText, onCommit: commitRename)
                    .textFieldStyle(.roundedBorder)
                    .onExitCommand { renamingNodeID = nil }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(node.name).lineLimit(1)
                    Text(countLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer()
        }
        .task(id: node.id) {
            // 并行加载计数与缩略图
            async let c = library.countImages(for: node)
            async let t = library.previewThumbnail(for: node)
            self.count = await c
            self.thumbnail = await t
        }
        .contextMenu {
            Button("在 Finder 中显示") { library.revealFolderInFinder(node) }
            if node.isRoot {
                Button("重命名") { startRename() }
                Divider()
                Button("从侧边栏移除", role: .destructive) {
                    if let rootID = node.rootID { library.removeRoot(by: rootID) }
                }
            }
        }
    }

    private var countLabel: String {
        if let count { return "\(count) 张" }
        return "…"
    }

    private func startRename() {
        renameText = node.name
        renamingNodeID = node.id
    }

    private func commitRename() {
        let name = renameText.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, let rootID = node.rootID {
            library.renameRoot(by: rootID, to: name)
        }
        renamingNodeID = nil
    }
}

// MARK: - 文件夹预览缩略图

private struct FolderPreviewImage: View {
    let node: FolderNode
    @Binding var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Rectangle().fill(Color.accentColor.opacity(0.15))
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.tint)
                        .font(.system(size: 16))
                }
            }
        }
    }
}
