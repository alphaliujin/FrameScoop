//
//  PhotoGridView.swift
//  FrameScoop
//
//  缩略图区域视图：固定行高、宽度按图片比例自适应的流式网格。
//  顶部工具栏：排序、缩略图尺寸、刷新。
//

import SwiftUI
import AppKit

struct PhotoGridView: View {
    @EnvironmentObject var library: PhotoLibraryViewModel
    @Environment(\.openWindow) private var openWindow

    /// 框选拖拽状态(nil = 未在框选)
    @State private var marquee: MarqueeDrag? = nil
    /// 本次框选是否加选(拖拽起点时刻的 Shift 状态)
    @State private var marqueeAdditive = false
    /// 本次拖拽期间缓存的布局帧(起拖时一次计算,全程复用;拖拽期间布局不变化)
    @State private var dragFrames: [GridPhotoFrame] = []
    /// 网格测量盒: 滚动/布局偏好经此中转。突变引用类型属性不会使视图失效,
    /// 避免每次滚动 tick 都全量重算 body(布局行计算 O(n) 每帧重跑)。
    private final class GridMeasurement {
        var contentFrame: CGRect = .zero
        var gridWidth: CGFloat = 0
    }
    @State private var gridMeasurement = GridMeasurement()
    /// 坐标空间名
    private static let marqueeSpace = "marqueeGrid"

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
                    // 任一「只显示」过滤开启时统一用普通流式展示（BurstFlowLayout 读的是
                    // 未过滤的 displayedBurstSegments，只显示模糊/闭眼/选中时须改用
                    // 已过滤的 displayedPhotos，否则网格会显示全部照片、与胶片条不一致）
                    if usesBurstLayout {
                        BurstFlowLayout(
                            spacing: 4,
                            rowHeight: library.thumbnailSize.cellSize,
                            availableWidth: geo.size.width,
                            segments: library.displayedBurstSegments,
                            cellWidth: { photo in max(library.thumbnailSize.cellSize * photo.aspectRatio, 40) },
                            content: { photo in cell(for: photo).equatable() }
                        )
                    } else {
                        FlowLayout(
                            spacing: 4,
                            rowHeight: library.thumbnailSize.cellSize,
                            availableWidth: geo.size.width,
                            items: library.displayedPhotos
                        ) { photo in
                            cell(for: photo).equatable()
                        }
                    }
                }
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: GridContentFrameKey.self,
                                               value: proxy.frame(in: .named(Self.marqueeSpace)))
                    }
                }
                .padding(4)
            }
            .coordinateSpace(name: Self.marqueeSpace)
            .gesture(marqueeGesture)
            .overlay { marqueeOverlay }
            .preference(key: GridViewportWidthKey.self, value: geo.size.width)
        }
        .onPreferenceChange(GridContentFrameKey.self) { gridMeasurement.contentFrame = $0 }
        .onPreferenceChange(GridViewportWidthKey.self) { gridMeasurement.gridWidth = $0 }
    }

    /// 是否走连拍分段布局(与 grid body 原条件一致)
    private var usesBurstLayout: Bool {
        library.showsBurstFilter && !library.showsBlurOnly
            && !library.showsEyeClosedOnly && !library.showsSelectedOnly
            && !library.displayedBurstSegments.isEmpty
    }

    /// 单元格宽度(与 GridCell body 一致)
    private func cellWidth(_ photo: PhotoItem) -> CGFloat {
        max(library.thumbnailSize.cellSize * photo.aspectRatio, 40)
    }

    /// 当前显示布局下每张图的内容坐标 frame(框选命中用;与显示布局共用 GridGeometry)
    private var layoutFrames: [GridPhotoFrame] {
        if usesBurstLayout {
            return GridGeometry.burstFrames(segments: library.displayedBurstSegments,
                                            cellWidth: cellWidth,
                                            rowHeight: library.thumbnailSize.cellSize,
                                            spacing: 4, availableWidth: gridMeasurement.gridWidth)
        }
        return GridGeometry.flowFrames(items: library.displayedPhotos,
                                       rowHeight: library.thumbnailSize.cellSize,
                                       spacing: 4, availableWidth: gridMeasurement.gridWidth)
    }

    /// 单个缩略图 cell（连拍 / 普通网格共用）：选中态、双击打开、单击选择、右键菜单。
    /// 返回 concrete GridCell（Equatable），配合 .equatable() 让 SwiftUI 跳过未变化 cell 的 body 求值，
    /// 避免 VM 任意 @Published 变化（如预计算进度）触发全量网格重渲染。
    private func cell(for photo: PhotoItem) -> GridCell {
        let blurOn = library.showsBlurFilter
        let eyeClosedOn = library.showsEyeClosedFilter
        return GridCell(
            photo: photo,
            isSelected: library.selectedPhotoIDs.contains(photo.id),
            thumbnailSize: library.thumbnailSize,
            badgeNumber: library.showsBurstFilter ? library.burstPhotoNumbers[photo.id] : nil,
            isRedBlurry: blurOn && library.blurryPhotoIDs.contains(photo.id),
            isYellowBlurry: blurOn && library.partialBlurryPhotoIDs.contains(photo.id),
            isRedEye: eyeClosedOn && library.closedEyePhotoIDs.contains(photo.id),
            isYellowEye: eyeClosedOn && library.partialClosedEyePhotoIDs.contains(photo.id),
            onDoubleTap: { openInDetail(photo) },
            onSingleTap: { library.toggleSelection(photo) },
            onReveal: { library.revealInFinder(photo) },
            onTrash: { library.trashPhotos([photo.id]) }
        )
    }

    // MARK: - 框选手势

    /// 框选拖拽: 起拖 ≥3pt 进入框选模式; 起拖瞬间记录 Shift 决定加选并缓存布局帧。
    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.marqueeSpace))
            .onChanged { value in
                if marquee == nil {
                    marquee = MarqueeDrag(start: value.startLocation, current: value.location)
                    marqueeAdditive = NSEvent.modifierFlags.contains(.shift)
                    dragFrames = layoutFrames
                } else {
                    marquee?.current = value.location
                }
                applyMarqueeSelection()
            }
            .onEnded { value in
                marquee?.current = value.location
                applyMarqueeSelection()
                marquee = nil
            }
    }

    /// 视口坐标 → 内容坐标,标准化矩形并裁剪到内容边界,应用选中。
    private func applyMarqueeSelection() {
        guard let m = marquee else { return }
        let raw = CGRect(x: m.start.x - gridMeasurement.contentFrame.minX,
                         y: m.start.y - gridMeasurement.contentFrame.minY,
                         width: m.current.x - m.start.x, height: m.current.y - m.start.y)
            .standardized
        let rect = raw.intersection(CGRect(origin: .zero, size: gridMeasurement.contentFrame.size))
        let ids = GridGeometry.hitPhotoIDs(in: rect, frames: dragFrames)
        library.selectPhotoIDs(ids, additive: marqueeAdditive)
    }

    /// 框选矩形(视口坐标): accent 描边 + 15% 填充。
    @ViewBuilder
    private var marqueeOverlay: some View {
        if let m = marquee {
            let rect = CGRect(x: min(m.start.x, m.current.x), y: min(m.start.y, m.current.y),
                              width: abs(m.current.x - m.start.x), height: abs(m.current.y - m.start.y))
            Rectangle()
                .stroke(Color.accentColor, lineWidth: 1)
                .background(Color.accentColor.opacity(0.15))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)
        }
    }

    // MARK: - 网格单元格（Equatable，跳过未变化 cell 的重渲染）

    /// 网格单元格：封装缩略图 + 选中态 + 徽标 + 手势 + 右键菜单。
    /// 遵循 Equatable：SwiftUI 经 .equatable() 对比后，跳过未变化 cell 的 body 求值，
    /// 避免 VM 任意 @Published 变化（如预计算进度）触发全量网格重渲染。
    private struct GridCell: View, Equatable {
    let photo: PhotoItem
    let isSelected: Bool
    let thumbnailSize: ThumbnailSize
    let badgeNumber: Int?
    let isRedBlurry: Bool
    let isYellowBlurry: Bool
    let isRedEye: Bool
    let isYellowEye: Bool

    var onDoubleTap: () -> Void
    var onSingleTap: () -> Void
    var onReveal: () -> Void
    var onTrash: () -> Void

    static func == (lhs: GridCell, rhs: GridCell) -> Bool {
        // 比较整个 photo（含 pixelWidth/Height->aspectRatio、modificationDate）而非仅 id：
        // 文件被原地编辑（同路径、尺寸或 mtime 变）触发监控 reload 后，新 PhotoItem 与旧的同 id
        // 但属性不同；仅比 id 会让 .equatable() 跳过 body，导致 cell 宽度与缩略图陈旧。
        lhs.photo == rhs.photo
        && lhs.isSelected == rhs.isSelected
        && lhs.thumbnailSize == rhs.thumbnailSize
        && lhs.badgeNumber == rhs.badgeNumber
        && lhs.isRedBlurry == rhs.isRedBlurry
        && lhs.isYellowBlurry == rhs.isYellowBlurry
        && lhs.isRedEye == rhs.isRedEye
        && lhs.isYellowEye == rhs.isYellowEye
    }

    var body: some View {
        let cellSize = thumbnailSize.cellSize
        let width = max(cellSize * photo.aspectRatio, 40)
        PhotoThumbnailCell(photo: photo, isSelected: isSelected, thumbnailSize: thumbnailSize)
            .frame(width: width, height: cellSize)
            .overlay(alignment: .topLeading) {
                PhotoBadges(
                    number: badgeNumber,
                    isRedBlurry: isRedBlurry,
                    isYellowBlurry: isYellowBlurry,
                    isRedEye: isRedEye,
                    isYellowEye: isYellowEye
                )
                .padding(2)
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { onDoubleTap() }
            .onTapGesture(count: 1) { onSingleTap() }
            .contextMenu {
                Button("打开") { onDoubleTap() }
                if photo.sourceKind == .folder {
                    Button("在 Finder 中显示") { onReveal() }
                }
                Divider()
                Button("移到废纸篓", role: .destructive) { onTrash() }
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
            // 右边栏（智能筛选）显示/隐藏
            Button {
                library.showsFilterPanel.toggle()
            } label: {
                Label("边栏", systemImage: "sidebar.right")
            }
            .help("显示或隐藏筛选边栏")

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

            // 全选 / 全不选 / 反选
            if !library.photos.isEmpty {
                Menu {
                    Button("全选") { library.selectAll() }
                    Button("全不选") { library.deselectAll() }
                    Divider()
                    Button("反选") { library.invertSelection() }
                } label: {
                    Label("选择", systemImage: "checklist")
                }
                .help("全选 / 全不选 / 反选")
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

// MARK: - 图片徽标

/// 图片徽标视图：连拍编号 + 人脸模糊 face.dashed + 闭眼 eye.slash，横向排列于左上角。
/// 网格缩略图与详情页大图共用；各项按对应筛选开关门控（开关关闭则不显示该项）。
/// 底层数据由预计算始终算好，与开关解耦。调用方负责定位、缩放与 allowsHitTesting。
struct PhotoBadges: View {
    let number: Int?
    let isRedBlurry: Bool
    let isYellowBlurry: Bool
    let isRedEye: Bool
    let isYellowEye: Bool

    var body: some View {
        Group {
            if number != nil || isRedBlurry || isYellowBlurry || isRedEye || isYellowEye {
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
                        badge(symbol: "face.dashed.fill", bg: .red, fg: .white)
                    } else if isYellowBlurry {
                        badge(symbol: "face.dashed.fill", bg: .yellow, fg: .black)
                    }
                    if isRedEye {
                        badge(symbol: "eye.slash.fill", bg: .red, fg: .white)
                    } else if isYellowEye {
                        badge(symbol: "eye.slash.fill", bg: .yellow, fg: .black)
                    }
                }
            }
        }
    }

    private func badge(symbol: String, bg: Color, fg: Color) -> some View {
        Image(systemName: symbol)
            .font(.caption2.weight(.bold))
            .foregroundStyle(fg)
            .frame(width: 14, height: 14)
            .background(bg, in: Circle())
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
        let rows = GridGeometry.flowRows(items: items, rowHeight: rowHeight, spacing: spacing, availableWidth: availableWidth)
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
        let rows = GridGeometry.burstRows(segments: segments, cellWidth: cellWidth,
                                          rowHeight: rowHeight, spacing: spacing,
                                          availableWidth: availableWidth)
        LazyVStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: spacing) {
                    ForEach(row) { photo in content(photo) }
                }
            }
        }
    }
}

// MARK: - 框选(Marquee)

/// 一次框选拖拽的起止点(坐标空间: ScrollView 视口 "marqueeGrid")
private struct MarqueeDrag {
    var start: CGPoint
    var current: CGPoint
}

/// 网格内容(布局 LazyVStack)在视口中的 frame: origin 含滚动偏移与 padding, size 为内容尺寸。
private struct GridContentFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

/// 视口宽度(布局与框选几何共用;与布局拿到的 geo.size.width 同源)。
private struct GridViewportWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
