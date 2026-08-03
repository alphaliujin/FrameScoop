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
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var image: NSImage?
    @State private var metadata: ImageMetadata?
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            // 毛玻璃 + 暗色背景
            Color.black.opacity(0.96)
                .background(.ultraThinMaterial)

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
            .ignoresSafeArea()

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

            // 底部胶片条
            filmstrip
                .frame(maxHeight: .infinity, alignment: .bottom)
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
            Spacer()
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
                            .onTapGesture { library.currentPhoto = item }
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
        library.currentPhoto = nil
        dismissWindow(id: "photo-detail")
    }

    private func loadImageAndMetadata() async {
        resetTransform()
        let url = photo.url
        // 并发加载大图与元数据，缩短等待
        // 使用 CGImageSource 降采样（最长边 2560px），避免将整张大图解码到内存
        async let loadedImage = Task.detached(priority: .userInitiated) { () -> NSImage? in
            ThumbnailGenerator.generate(url: url, maxPixel: 2560)
        }.value
        async let meta = library.loadMetadata(for: url)
        let (img, md) = await (loadedImage, meta)
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
            image = await ThumbnailCacheService.shared.thumbnail(for: item.url, maxPixel: 128)
        }
    }
}
