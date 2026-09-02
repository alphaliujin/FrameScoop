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
        // 行号模型(与旧 computeRows 逐行等价): 行按发射顺序连续编号, 行 i 的 y = i*(rowHeight+spacing)。
        // 连拍组独占行 = 关闭打开的流式行后, 组内各行按序号紧接发射 —— 组间不插空行,
        // 组末行留白由"关闭流式行"保证(下一段单张开新行)。
        // 注意: displayedBurstSegments 过滤掉 .single 后连续 .burst 是常态, 因此不能对每个组
        // 先无条件 +rowHeight+spacing 再发射(会在连续组之间插幽灵空行)。
        var frames: [GridPhotoFrame] = []
        var rowIndex = 0                       // 下一个待发射行的行号(= 已发射行数)
        var flowRow: Int? = nil                // 当前打开的流式行行号(nil = 无打开的流式行)
        var flowX: CGFloat = 0                 // 流式行下一个候选 x
        func openFlowRow() { flowRow = rowIndex; rowIndex += 1; flowX = 0 }
        for segment in segments {
            switch segment {
            case .single(let photo):
                let w = cellWidth(photo)
                if flowRow == nil {
                    openFlowRow()                       // 新行首张不检查换行(与旧 !flowRow.isEmpty 门一致)
                } else if flowX + w > availableWidth {  // 旧 flowWidth + spacing + w ≡ flowX + w
                    openFlowRow()
                }
                let rowY = CGFloat(flowRow!) * (rowHeight + spacing)
                frames.append(GridPhotoFrame(photo: photo, frame: CGRect(x: flowX, y: rowY, width: w, height: rowHeight)))
                flowX += w + spacing
            case .burst(let group):
                flowRow = nil                          // 组独占行: 关闭流式行, 下一段单张将开新行
                var burstX: CGFloat = 0
                var burstRowCount = 0
                var burstRowIdx = -1
                for photo in group {
                    let w = cellWidth(photo)
                    // 与旧 burstRow 换行条件等价: burstWidth + spacing + w ≡ burstX + w(候选起点);
                    // 勿写成 burstX + spacing + w(多算尾部 spacing 会提前换行)。行首张不检查换行。
                    if burstRowCount > 0, burstX + w > availableWidth {
                        burstX = 0
                        burstRowCount = 0
                        burstRowIdx = -1
                    }
                    if burstRowCount == 0 {
                        burstRowIdx = rowIndex
                        rowIndex += 1
                    }
                    let rowY = CGFloat(burstRowIdx) * (rowHeight + spacing)
                    frames.append(GridPhotoFrame(photo: photo, frame: CGRect(x: burstX, y: rowY, width: w, height: rowHeight)))
                    burstX += w + spacing
                    burstRowCount += 1
                }
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
