//
//  PhotoThumbnailCell.swift
//  FrameScoop
//
//  单个缩略图单元格：异步加载缩略图、选中态高亮、悬停效果。
//

import SwiftUI
import AppKit

struct PhotoThumbnailCell: View {
    let photo: PhotoItem
    let isSelected: Bool

    @EnvironmentObject var library: PhotoLibraryViewModel
    @State private var thumbnail: NSImage?
    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // 图片 / 占位
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle()
                        .fill(Color(nsColor: .quaternaryLabelColor))
                        .overlay {
                            Image(systemName: "photo")
                                .foregroundStyle(.tertiary)
                        }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            // 选中标记
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.white, .tint)
                    .shadow(radius: 1)
                    .padding(6)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3)
        )
        .overlay(
            // 悬停遮罩
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(isHovering ? 0.08 : 0))
        )
        .onHover { isHovering = $0 }
        .task(id: "\(photo.id)-\(library.thumbnailSize)") {
            await loadThumbnail()
        }
    }

    /// 加载缩略图（命中缓存则即时）
    private func loadThumbnail() async {
        let maxPixel = library.thumbnailSize.maxPixel
        // 尺寸变更时清空旧图，避免拉伸
        thumbnail = nil
        let image = await ThumbnailCacheService.shared.thumbnail(for: photo.url, maxPixel: maxPixel)
        // 校验任务未取消（尺寸切换/单元格复用时旧任务结果丢弃）；.task 闭包已在主线程，可直接赋值
        guard !Task.isCancelled else { return }
        self.thumbnail = image
    }
}
