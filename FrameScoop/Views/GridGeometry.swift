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

    /// 连拍分段布局的 frame 计算：连拍组独占行(组内可换行、组末行留白)；单张段流式排列。
    static func burstFrames(segments: [BurstSegment], cellWidth: (PhotoItem) -> CGFloat,
                            rowHeight: CGFloat, spacing: CGFloat, availableWidth: CGFloat) -> [GridPhotoFrame] {
        guard availableWidth > 0 else {
            // 与旧行为一致: 宽度未知时全部单行
            let photos = segments.flatMap { seg -> [PhotoItem] in
                switch seg { case .single(let p): return [p]; case .burst(let ps): return ps }
            }
            var x: CGFloat = 0
            return photos.map { p in
                let w = cellWidth(p)
                defer { x += w + spacing }
                return GridPhotoFrame(photo: p, frame: CGRect(x: x, y: 0, width: w, height: rowHeight))
            }
        }
        var frames: [GridPhotoFrame] = []
        var y: CGFloat = 0
        for segment in segments {
            switch segment {
            case .single(let photo):
                let w = cellWidth(photo)
                let continuesFlow = frames.last.map { $0.frame.minY == y } ?? false
                var x = continuesFlow ? frames.last!.frame.maxX + spacing : 0
                if continuesFlow, x + w > availableWidth {
                    y += rowHeight + spacing
                    x = 0
                }
                frames.append(GridPhotoFrame(photo: photo, frame: CGRect(x: x, y: y, width: w, height: rowHeight)))
            case .burst(let group):
                // 连拍组独占行: 组首永远新行; 组末行留白(与下一段分开)
                if !frames.isEmpty { y += rowHeight + spacing }
                var burstX: CGFloat = 0
                var burstRowCount = 0
                for photo in group {
                    let w = cellWidth(photo)
                    // 与旧 burstRow 换行条件等价: burstWidth + spacing + w ≡ burstX + w(burstX 为候选起点);
                    // 勿写成 burstX + spacing + w(多算尾部 spacing 会提前换行)。
                    if burstRowCount > 0, burstX + w > availableWidth {
                        y += rowHeight + spacing
                        burstX = 0
                        burstRowCount = 0
                    }
                    frames.append(GridPhotoFrame(photo: photo, frame: CGRect(x: burstX, y: y, width: w, height: rowHeight)))
                    burstX += w + spacing
                    burstRowCount += 1
                }
                y += rowHeight + spacing
            }
        }
        return frames
    }

    /// 连拍布局的行分组(同 flowRows: 按 frame.minY 聚合连续帧)。
    static func burstRows(segments: [BurstSegment], cellWidth: (PhotoItem) -> CGFloat,
                          rowHeight: CGFloat, spacing: CGFloat, availableWidth: CGFloat) -> [[PhotoItem]] {
        let frames = burstFrames(segments: segments, cellWidth: cellWidth, rowHeight: rowHeight,
                                 spacing: spacing, availableWidth: availableWidth)
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
