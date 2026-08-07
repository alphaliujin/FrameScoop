//
//  SidebarView.swift
//  FrameScoop
//
//  侧边栏：文件夹「逐级展开」的树形列表（仿 Finder / 照片侧边栏）。
//
//  - 根节点 = 用户添加的文件夹（可重命名 / 移除）
//  - 子节点 = 子目录，递归构建，可逐级展开
//  - 每行：系统默认文件夹图标（或照片库符号）+ 名称 + 递归图片数（懒加载），不显示图片缩略图
//  - 选中任意节点由 ContentView 的 onChange 触发加载
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
            VStack(spacing: 0) {
                // 图片数据导入进度：文件夹加载后自动预计算连拍 dHash + 人脸模糊分。
                // 算完后不消失，保留满进度条 + 完成标记，切文件夹随新数据重置。
                if library.precomputeTotal > 0 {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text("图片数据导入：\(library.precomputeDone) / \(library.precomputeTotal) 张")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            Spacer()
                            if !library.isPrecomputing {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.caption)
                            }
                        }
                        ProgressView(value: Double(library.precomputeDone),
                                     total: Double(library.precomputeTotal))
                            .controlSize(.small)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                }
                addFolderButton
            }
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
    @EnvironmentObject var library: PhotoLibraryViewModel

    private var isRenaming: Bool { renamingNodeID == node.id }

    var body: some View {
        HStack(spacing: 10) {
            FolderNodeIcon(node: node)
                .frame(width: 28, height: 22)

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
        .task(id: node.isPhotosLibrary ? "\(node.id)#\(library.photosAuthTick)" : node.id) {
            // 仅加载图片计数（不再加载首图缩略图，文件夹用系统默认图标）
            self.count = await library.countImages(for: node)
        }
        .contextMenu {
            if !node.isPhotosLibrary {
                Button("在 Finder 中显示") { library.revealFolderInFinder(node) }
            }
            if node.isRoot && !node.isPhotosLibrary {
                Button("重命名") { startRename() }
                Divider()
                Button("从侧边栏移除", role: .destructive) {
                    if let rootID = node.rootID { library.removeRoot(by: rootID) }
                }
            }
        }
    }

    private var countLabel: String {
        // 选中节点加载完成后，用经 CGImageSource 校验过的 photos 计数，与缩略图区域
        // 标题「N 张照片」一致；按扩展名计数会把损坏/非图片文件算进去导致侧栏偏多。
        // 非选中节点仍用懒加载的近似计数（按扩展名，快速），保留侧栏展开多节点时的性能。
        if node.id == library.selectedNodeID, !library.isLoading, !library.photosAccessDenied {
            return "\(library.photos.count) 张"
        }
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

// MARK: - 文件夹图标

private struct FolderNodeIcon: View {
    let node: FolderNode

    var body: some View {
        if node.isPhotosLibrary {
            // 照片库节点非文件夹：用照片堆叠符号区分
            Image(systemName: "photo.stack")
                .foregroundStyle(.tint)
                .font(.system(size: 20))
        } else {
            // 文件夹节点：使用 macOS 系统默认文件夹图标（Finder 蓝色文件夹），不加载首图缩略图
            Image(nsImage: NSWorkspace.shared.icon(for: .folder))
                .resizable()
                .aspectRatio(contentMode: .fit)
        }
    }
}
