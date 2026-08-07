//
//  PhotoDetailView.swift
//  FrameScoop
//
//  沉浸式图片查看视图（毛玻璃覆盖层）。
//  功能：
//  - 全屏查看大图，支持双指捏合缩放、拖拽平移
//  - 上一张 / 下一张导航（按钮 + 方向键）
//  - 可展开的信息面板（拍摄参数，来自 MetadataService）
//  - 底部胶片条预览
//

import SwiftUI
import AppKit

struct PhotoDetailView: View {
    let photo: PhotoItem

    @EnvironmentObject var library: PhotoLibraryViewModel
    @State private var image: NSImage?
    @State private var metadata: ImageMetadata?
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            // 毛玻璃 + 暗色背景（全屏铺底，含胶片条区域）
            Color.black.opacity(0.96)
                .background(.ultraThinMaterial)
                .ignoresSafeArea()

            // 主内容区：图片在上，胶片条在下，互不叠加
            VStack(spacing: 0) {
                // 图片区 + 浮层控件
                ZStack {
                    GeometryReader { geo in
                        ZStack {
                            if let image {
                                imageView(image, in: geo)
                            } else {
                                ProgressView()
                                    .tint(.white)
                                    .frame(width: geo.size.width, height: geo.size.height)
                            }
                        }
                    }

                    // 顶部控制栏
                    topBar
                        .frame(maxHeight: .infinity, alignment: .top)

                    // 左右导航按钮
                    navigationArrows

                    // 信息面板（可切换）
                    if library.showsInfoPanel, let metadata {
                        MetadataPanelView(photo: photo, metadata: metadata)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }

                // 底部胶片条：独立区域，不再叠加在图片上
                filmstrip
            }
        }
        .task(id: photo.id) {
            await loadImageAndMetadata()
        }
        .focusable()
        .focused($isFocused)
        .onAppear { isFocused = true }
        // Esc 关闭详情窗口（无对应菜单快捷键，需在此处理）。
        // 上一张/下一张由 App 层菜单命令的 .keyboardShortcut(.leftArrow/.rightArrow) 统一处理
        //（菜单 key equivalent 经 performKeyEquivalent 先于 keyDown 派发并消费事件），
        // 此处不再绑定 onKeyPress 方向键，避免与菜单命令重复触发（双倍跳转）。
        .onKeyPress(.escape) { closeWindow(); return .handled }
        .onKeyPress(.space) {
            // 空格选中当前图片（播放中标记当前张；选中态跨详情窗口保留，返回主界面网格仍高亮）
            library.toggleCurrentSelection()
            return .handled
        }
    }

    // MARK: - 主图

    @ViewBuilder
    private func imageView(_ image: NSImage, in geo: GeometryProxy) -> some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .scaleEffect(scale)
            .offset(scale > 1 ? offset : .zero)
            .frame(width: geo.size.width, height: geo.size.height)
            .overlay(alignment: .topLeading) {
                // 左上角徽标：与网格一致的连拍编号 / 模糊 / 闭眼标记；
                // 下移避开顶部标题栏，固定不随图片缩放/平移移动
                PhotoBadges(photo: photo)
                    .scaleEffect(1.6, anchor: .topLeading)
                    .padding(.top, 56)
                    .padding(.leading, 12)
                    .allowsHitTesting(false)
            }
            .gesture(
                // 缩放
                MagnificationGesture()
                    .onChanged { value in
                        scale = max(1, min(5, lastScale * value))
                    }
                    .onEnded { _ in
                        lastScale = scale
                        if scale <= 1 { resetTransform() }
                    }
            )
            .simultaneousGesture(
                // 拖拽平移（仅放大时）
                DragGesture()
                    .onChanged { value in
                        guard scale > 1 else { return }
                        offset = CGSize(
                            width: lastOffset.width + value.translation.width,
                            height: lastOffset.height + value.translation.height
                        )
                    }
                    .onEnded { _ in lastOffset = offset }
            )
            .onTapGesture(count: 1) {
                // 信息面板打开时，单击图片任意位置关闭面板
                if library.showsInfoPanel {
                    withAnimation { library.showsInfoPanel = false }
                }
            }
            .onTapGesture(count: 2) {
                // 双击切换缩放
                if scale > 1 { resetTransform() }
                else { scale = 2; lastScale = 2 }
            }
    }

    // MARK: - 控件

    private var topBar: some View {
        HStack {
            Text(photo.name)
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.top, 30)
            if library.slideshowMode != .off {
                Label("播放中", systemImage: library.slideshowMode == .forward ? "play.fill" : "backward.fill")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.5), in: Capsule())
                    .padding(.top, 30)
                    .help("播放中，每 2 秒自动翻页；按方向键退出")
            }
            Spacer()
            // 选中标记（与网格一致的 checkmark.circle.fill）
            if library.selectedPhotoIDs.contains(photo.id) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white, .tint)
                    .shadow(radius: 1)
            }
            Button {
                withAnimation { library.showsInfoPanel.toggle() }
            } label: {
                Image(systemName: library.showsInfoPanel ? "info.circle.fill" : "info.circle")
                    .font(.system(size: 36))
            }
        }
        .padding()
        .buttonStyle(.plain)
        .tint(.white)
    }

    private var navigationArrows: some View {
        HStack {
            Button {
                library.previousPhoto()
            } label: {
                Image(systemName: "chevron.left.circle.fill")
                    .font(.system(size: 30))
                    .opacity((library.currentPhotoIndex ?? 0) > 0 ? 1 : 0.3)
            }
            .buttonStyle(.plain)
            .tint(.white)

            Spacer()

            Button {
                library.nextPhoto()
            } label: {
                Image(systemName: "chevron.right.circle.fill")
                    .font(.system(size: 30))
                    .opacity(((library.currentPhotoIndex ?? 0) + 1) < library.displayedPhotos.count ? 1 : 0.3)
            }
            .buttonStyle(.plain)
            .tint(.white)
        }
        .padding(.horizontal, 16)
    }

    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                // LazyHStack：仅实例化可见的胶片条单元，避免对整个图库都创建视图/加载任务
                LazyHStack(spacing: 6) {
                    ForEach(library.displayedPhotos) { item in
                        FilmstripThumbnail(item: item, isCurrent: item.id == photo.id)
                            .frame(width: 64, height: 64)
                            .onTapGesture {
                                // 同 closeWindow：手势闭包可能落在视图更新事务中，延后发布
                                Task { @MainActor in library.currentPhoto = item }
                            }
                            .id(item.id)
                    }
                }
                .padding(8)
            }
            .frame(height: 88)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 40)
            .padding(.bottom, 16)
            .onChange(of: photo.id) { _, _ in
                withAnimation { proxy.scrollTo(photo.id, anchor: .center) }
            }
        }
    }

    // MARK: - 加载

    private func closeWindow() {
        // 延后清空 currentPhoto：onKeyPress 闭包可能在视图更新事务期间被同步调用
        //（播放时每 2s 视图更新一次，Esc 易落在事务中），同步改 @Published 会触发
        // "Publishing changes from within view updates"。延后到下一 runloop；
        // currentPhoto=nil 的 didSet 会停止播放，DetailWindowRoot 观察到 nil 后自动关窗。
        Task { @MainActor in
            library.currentPhoto = nil
        }
    }

    private func loadImageAndMetadata() async {
        resetTransform()
        let photo = self.photo
        // 并发加载大图与元数据，缩短等待
        // 大图经 PhotoLoader 分派（folder->CGImageSource 降采样，photoLibrary->PHImageManager），
        // 后台线程解码避免阻塞 UI；元数据按源分派（folder->mdls，photoLibrary->PHAsset）
        let imageTask = Task.detached(priority: .userInitiated) { () -> NSImage? in
            await PhotoLoader.fullImage(for: photo)
        }
        async let meta = library.loadMetadata(for: photo)
        let (img, md) = await (imageTask.value, meta)
        // 校验任务未取消（用户已切到下一张）：避免旧图加载完成后短暂覆盖新图
        guard !Task.isCancelled else { return }
        image = img
        metadata = md
    }

    private func resetTransform() {
        withAnimation(.easeOut(duration: 0.2)) {
            scale = 1; lastScale = 1
            offset = .zero; lastOffset = .zero
        }
    }
}

/// 胶片条单格缩略图
private struct FilmstripThumbnail: View {
    let item: PhotoItem
    let isCurrent: Bool
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.gray.opacity(0.3)
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isCurrent ? Color.accentColor : .clear, lineWidth: 3)
        )
        .task(id: item.id) {
            image = await ThumbnailCacheService.shared.thumbnail(for: item, maxPixel: 128)
        }
    }
}
