//
//  GridGeometry.swift
//  FrameScoop
//
//  网格布局的确定性几何计算：流式/连拍两种布局的行与 frame 纯函数。
//  显示布局（FlowLayout / BurstFlowLayout）与框选命中（PhotoGridView）共用同一份几何，
//  保证任何布局调整自动同步到框选。
//

import Foundation
import CoreGraphics

/// 一张图片在网格内容坐标中的显示 frame（内容坐标原点 = LazyVStack 左上角）
struct GridPhotoFrame: Equatable {
    let photo: PhotoItem
    let frame: CGRect
}

enum GridGeometry {

    /// 流式布局（固定行高、宽度按比例自适应）的 frame 计算，换行规则与旧 FlowLayout.computeRows 完全一致。
    static func flowFrames(items: [PhotoItem], rowHeight: CGFloat, spacing: CGFloat, availableWidth: CGFloat) -> [GridPhotoFrame] {
        var frames: [GridPhotoFrame] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowCount = 0
        for photo in items {
            let w = max(rowHeight * photo.aspectRatio, 40)
            // 与旧 computeRows 严格等价: 旧判定 currentWidth + spacing + w,其中 currentWidth = Σwᵢ + (k-1)·spacing
            // (不含尾部 spacing),等价于 x + w(此处 x = Σwᵢ + k·spacing 已含尾部 spacing)。
            // 勿写成 x + spacing + w: 会把尾部 spacing 重复计一次,比旧规则提前一个 spacing 换行。
            if availableWidth > 0, rowCount > 0, x + w > availableWidth {
                x = 0
                y += rowHeight + spacing
                rowCount = 0
            }
            frames.append(GridPhotoFrame(photo: photo, frame: CGRect(x: x, y: y, width: w, height: rowHeight)))
            x += w + spacing
            rowCount += 1
        }
        return frames
    }

    /// 流式布局的行分组：按 frame.minY 相同的连续帧聚合（同 rowHeight 下 y 相等即同行）。
    static func flowRows(items: [PhotoItem], rowHeight: CGFloat, spacing: CGFloat, availableWidth: CGFloat) -> [[PhotoItem]] {
        let frames = flowFrames(items: items, rowHeight: rowHeight, spacing: spacing, availableWidth: availableWidth)
        var rows: [[PhotoItem]] = []
        var lastY: CGFloat? = nil
        for f in frames {
            if lastY == f.frame.minY, !rows.isEmpty {
                rows[rows.count - 1].append(f.photo)
            } else {
                rows.append([f.photo])
                lastY = f.frame.minY
            }
        }
        return rows
    }
}
