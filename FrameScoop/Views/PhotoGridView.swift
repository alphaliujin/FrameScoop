//
//  PhotoGridView.swift
//  FrameScoop
//
//  缩略图区域视图：固定行高、宽度按图片比例自适应的流式网格。
//  顶部工具栏：排序、缩略图尺寸、刷新。
//

import SwiftUI

struct PhotoGridView: View {
    @EnvironmentObject var library: PhotoLibraryViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if library.isLoading && library.photos.isEmpty {
                loadingState
            } else if library.photosAccessDenied {
                EmptyStateView(systemImage: "photo.badge.exclamationmark",
                               title: "无法访问照片库",
                               message: "请在「系统设置 › 隐私与安全性 › 照片」中允许 FrameScoop 访问照片，然后刷新。")
            } else if library.photos.isEmpty {
                EmptyStateView(systemImage: "photo.on.rectangle.angled",
                               title: "此文件夹暂无图片",
                               message: "将图片放入该文件夹，或选择其他文件夹。")
            } else {
                grid
            }
        }
        .navigationSubtitle("\(library.photos.count) 张照片")
        .toolbar { toolbarContent }
    }

    // MARK: - 打开详情

    /// 双击 / 上下文菜单「打开」共用：单选该图、置为当前图并打开详情窗口。
    private func openInDetail(_ photo: PhotoItem) {
        library.openPhoto(photo)
        openWindow(id: "photo-detail")
    }

    // MARK: - 网格

    private var grid: some View {
        GeometryReader { geo in
            ScrollView {
                FlowLayout(
                    spacing: 4,
                    rowHeight: library.thumbnailSize.cellSize,
                    availableWidth: geo.size.width,
                    items: library.displayedPhotos
                ) { photo in
                    PhotoThumbnailCell(photo: photo,
                                       isSelected: library.selectedPhotoIDs.contains(photo.id))
                        .frame(width: max(library.thumbnailSize.cellSize * photo.aspectRatio, 40),
                               height: library.thumbnailSize.cellSize)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            openInDetail(photo)
                        }
                        .onTapGesture(count: 1) {
                            library.toggleSelection(photo)
                        }
                        .contextMenu {
                            Button("打开") { openInDetail(photo) }
                            if photo.sourceKind == .folder {
                                Button("在 Finder 中显示") { library.revealInFinder(photo) }
                            }
                            Divider()
                            Button("移到废纸篓", role: .destructive) {
                                library.trashPhotos([photo.id])
                            }
                        }
                }
                .padding(4)
            }
        }
    }

    // MARK: - 加载占位

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("正在读取图片…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            // 排序菜单
            Menu {
                Picker("排序方式", selection: $library.sortOption) {
                    ForEach(SortOption.allCases, id: \.self) { opt in
                        Label(opt.label, systemImage: opt.systemImage).tag(opt)
                    }
                }
                Divider()
                Picker("方向", selection: $library.sortOrder) {
                    ForEach(SortOrder.allCases, id: \.self) { ord in
                        Label(ord.label, systemImage: ord.systemImage).tag(ord)
                    }
                }
            } label: {
                Label("排序", systemImage: "arrow.up.arrow.down.circle")
            }

            // 缩略图尺寸
            Menu {
                Picker("缩略图大小", selection: $library.thumbnailSize) {
                    ForEach(ThumbnailSize.allCases, id: \.self) { size in
                        Text(size.label).tag(size)
                    }
                }
            } label: {
                Label("显示大小", systemImage: "rectangle.expand.vertical")
            }

            // 刷新
            Button {
                library.reloadCurrentFolder()
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }

            // 选中图片时显示「发送」菜单（右上角）
            if !library.selectedPhotoIDs.isEmpty {
                Menu {
                    Button("导出到指定文件夹…") { library.exportSelectionToFolder() }
                    Button("复制到剪贴板") { library.copySelectionToClipboard() }
                    Divider()
                    Button("作为邮件附件发送") { library.sendSelectionViaEmail() }
                } label: {
                    Label("发送", systemImage: "square.and.arrow.up")
                }
                .help("发送选中的 \(library.selectedPhotoIDs.count) 张图片")
            }
        }
    }
}

// MARK: - FlowLayout（固定行高、宽度按比例自适应）

/// 将子视图按行排列的流式布局。每行高度固定，子视图宽度由自身决定（图片比例），
/// 超出可用宽度时自动换行。效果类似照片 App 的"时刻"视图。
private struct FlowLayout<Content: View>: View {
    let spacing: CGFloat
    let rowHeight: CGFloat
    let availableWidth: CGFloat
    let items: [PhotoItem]
    let content: (PhotoItem) -> Content

    var body: some View {
        let rows = computeRows()
        LazyVStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: spacing) {
                    ForEach(row) { photo in
                        content(photo)
                    }
                }
            }
        }
    }

    /// 将图片按比例宽度分行：累加每张图的显示宽度，超出可用宽度即换行
    private func computeRows() -> [[PhotoItem]] {
        guard availableWidth > 0 else { return [items] }
        var rows: [[PhotoItem]] = []
        var current: [PhotoItem] = []
        var currentWidth: CGFloat = 0
        for photo in items {
            let w = max(rowHeight * photo.aspectRatio, 40)
            if !current.isEmpty && currentWidth + spacing + w > availableWidth {
                rows.append(current)
                current = []
                currentWidth = 0
            }
            current.append(photo)
            currentWidth += w + (current.count > 1 ? spacing : 0)
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }
}
