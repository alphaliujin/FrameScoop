//
//  PhotoGridView.swift
//  FrameScoop
//
//  缩略图区域视图：自适应列数的图片网格，模仿“照片”App 内容区，填充 NavigationSplitView 的 detail 列。
//  顶部工具栏：排序、缩略图尺寸、刷新。
//

import SwiftUI

struct PhotoGridView: View {
    @EnvironmentObject var library: PhotoLibraryViewModel

    /// 自适应列：根据缩略图尺寸档位与窗口宽度自动排列列数
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: library.thumbnailSize.cellSize), spacing: 4)]
    }

    var body: some View {
        Group {
            if library.isLoading && library.photos.isEmpty {
                loadingState
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

    // MARK: - 网格

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(library.displayedPhotos) { photo in
                    PhotoThumbnailCell(photo: photo,
                                       isSelected: library.selectedPhotoIDs.contains(photo.id))
                        .aspectRatio(1, contentMode: .fit)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            library.selectSingle(photo)
                            library.openPhoto(photo)
                        }
                        .onTapGesture(count: 1) {
                            library.toggleSelection(photo)
                        }
                        .contextMenu {
                            Button("打开") { library.openPhoto(photo) }
                            Button("在 Finder 中显示") { library.revealInFinder(photo) }
                            Divider()
                            Button("移到废纸篓", role: .destructive) {
                                library.trashPhotos([photo.id])
                            }
                        }
                }
            }
            .padding(4)
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
            if !library.selectedURLs.isEmpty {
                Menu {
                    Button("导出到指定文件夹…") { library.exportSelectionToFolder() }
                    Button("复制到剪贴板") { library.copySelectionToClipboard() }
                    Divider()
                    Button("作为邮件附件发送") { library.sendSelectionViaEmail() }
                } label: {
                    Label("发送", systemImage: "square.and.arrow.up")
                }
                .help("发送选中的 \(library.selectedURLs.count) 张图片")
            }
        }
    }
}
