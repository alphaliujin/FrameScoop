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
                Group {
                    // showsBlurOnly 时统一用普通流式展示模糊照片（不按连拍分段）
                    if library.showsBurstFilter && !library.showsBlurOnly
                        && !library.displayedBurstSegments.isEmpty {
                        BurstFlowLayout(
                            spacing: 4,
                            rowHeight: library.thumbnailSize.cellSize,
                            availableWidth: geo.size.width,
                            segments: library.displayedBurstSegments,
                            cellWidth: { photo in max(library.thumbnailSize.cellSize * photo.aspectRatio, 40) },
                            content: { photo in cell(for: photo) }
                        )
                    } else {
                        FlowLayout(
                            spacing: 4,
                            rowHeight: library.thumbnailSize.cellSize,
                            availableWidth: geo.size.width,
                            items: library.displayedPhotos
                        ) { photo in
                            cell(for: photo)
                        }
                    }
                }
                .padding(4)
            }
        }
    }

    /// 单个缩略图 cell（连拍 / 普通网格共用）：选中态、双击打开、单击选择、右键菜单。
    /// 用 AnyView 擦除类型，便于在 BurstFlowLayout / FlowLayout 的泛型 content 闭包中复用。
    private func cell(for photo: PhotoItem) -> AnyView {
        let isSelected = library.selectedPhotoIDs.contains(photo.id)
        let cellSize = library.thumbnailSize.cellSize
        let width = max(cellSize * photo.aspectRatio, 40)
        let number = library.burstPhotoNumbers[photo.id]
        let isRedBlurry = library.blurryPhotoIDs.contains(photo.id)
        let isYellowBlurry = library.partialBlurryPhotoIDs.contains(photo.id)
        let isRedEye = library.closedEyePhotoIDs.contains(photo.id)
        let isYellowEye = library.partialClosedEyePhotoIDs.contains(photo.id)
        return AnyView(
            PhotoThumbnailCell(photo: photo, isSelected: isSelected)
                .frame(width: width, height: cellSize)
                .overlay(alignment: .topLeading) {
                    // 左上角徽标：连拍编号（黑底白数字）+ 人脸模糊感叹号
                    // 红 = 所有人脸都模糊；黄 = 有清晰也有模糊
                    if number != nil || isRedBlurry || isYellowBlurry {
                        HStack(spacing: 2) {
                            if let number {
                                Text("\(number)")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                            }
                            if isRedBlurry {
                                Image(systemName: "exclamationmark")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 14, height: 14)
                                    .background(.red, in: Circle())
                            } else if isYellowBlurry {
                                Image(systemName: "exclamationmark")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.black)
                                    .frame(width: 14, height: 14)
                                    .background(.yellow, in: Circle())
                            }
                        }
                        .padding(2)
                        .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    // 右上角徽标：闭眼（eye.slash）。红 = 所有人脸都闭眼；黄 = 有睁有闭
                    if isRedEye || isYellowEye {
                        Image(systemName: "eye.slash.fill")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(isRedEye ? Color.white : Color.black)
                            .frame(width: 14, height: 14)
                            .background(isRedEye ? Color.red : Color.yellow, in: Circle())
                            .padding(2)
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { openInDetail(photo) }
                .onTapGesture(count: 1) { library.toggleSelection(photo) }
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
        )
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
            // 智能筛选边栏切换
            Button {
                library.showsFilterPanel.toggle()
            } label: {
                Label("筛选", systemImage: "line.3.horizontal.decrease.circle")
            }
            .help("显示或隐藏智能筛选面板")

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

// MARK: - BurstFlowLayout（连拍分段：连拍组独占行，单张流式）

/// 连拍分段流式布局：
/// - 连拍组独占行 -- 首张在行首；组内按宽度自动换行；末张所在行为末行，后面留白（不接下一段）。
/// - 单张段流式排列 -- 可多张同行，超出宽度换行（与普通 FlowLayout 一致）。
private struct BurstFlowLayout<Content: View>: View {
    let spacing: CGFloat
    let rowHeight: CGFloat
    let availableWidth: CGFloat
    let segments: [BurstSegment]
    let cellWidth: (PhotoItem) -> CGFloat
    let content: (PhotoItem) -> Content

    var body: some View {
        let rows = computeRows()
        LazyVStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: spacing) {
                    ForEach(row) { photo in content(photo) }
                }
            }
        }
    }

    private func computeRows() -> [[PhotoItem]] {
        guard availableWidth > 0 else {
            return [segments.flatMap { seg -> [PhotoItem] in
                switch seg { case .single(let p): return [p]; case .burst(let ps): return ps }
            }]
        }
        var rows: [[PhotoItem]] = []
        var flowRow: [PhotoItem] = []        // 当前单张流式行
        var flowWidth: CGFloat = 0

        func flushFlow() {
            if !flowRow.isEmpty {
                rows.append(flowRow)
                flowRow = []
                flowWidth = 0
            }
        }

        for segment in segments {
            switch segment {
            case .single(let photo):
                let w = cellWidth(photo)
                if !flowRow.isEmpty && flowWidth + spacing + w > availableWidth {
                    flushFlow()
                }
                flowRow.append(photo)
                flowWidth += w + (flowRow.count > 1 ? spacing : 0)

            case .burst(let group):
                // 连拍组独占行：先结束当前流式行，保证组首在新行行首
                flushFlow()
                var burstRow: [PhotoItem] = []
                var burstWidth: CGFloat = 0
                for photo in group {
                    let w = cellWidth(photo)
                    if !burstRow.isEmpty && burstWidth + spacing + w > availableWidth {
                        rows.append(burstRow)
                        burstRow = []
                        burstWidth = 0
                    }
                    burstRow.append(photo)
                    burstWidth += w + (burstRow.count > 1 ? spacing : 0)
                }
                if !burstRow.isEmpty {
                    rows.append(burstRow)   // 末行留白：不与下一段同行
                }
            }
        }
        flushFlow()
        return rows
    }
}
