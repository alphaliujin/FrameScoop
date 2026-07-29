//
//  MetadataPanelView.swift
//  FrameScoop
//
//  元数据信息面板（详情视图右侧）。
//  展示文件信息与拍摄参数（来自 MetadataService / mdls）。
//  使用毛玻璃半透明背景，符合 HIG“在内容之上提供轻量信息”原则。
//

import SwiftUI

struct MetadataPanelView: View {
    let photo: PhotoItem
    let metadata: ImageMetadata

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                section(title: "文件信息") {
                    row("文件名", photo.name)
                    row("大小", photo.formattedSize)
                    row("尺寸", metadata.pixelWidth.map { _ in "\(metadata.pixelWidth ?? 0) × \(metadata.pixelHeight ?? 0)" } ?? photo.dimensionsText)
                    if let colorSpace = metadata.colorSpace { row("色彩空间", colorSpace) }
                    if let depth = metadata.depth { row("位深", "\(depth) 位") }
                    if let dpi = metadata.dpi { row("分辨率", "\(dpi) DPI") }
                    if let date = photo.modificationDate {
                        row("修改时间", DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short))
                    }
                }

                if metadata.hasCameraInfo {
                    section(title: "拍摄信息") {
                        if let make = metadata.cameraMake { row("厂商", make) }
                        if let model = metadata.cameraModel { row("相机", model) }
                        if let lens = metadata.lensModel { row("镜头", lens) }
                        if let focal = metadata.focalLength { row("焦距", String(format: "%.0f mm", focal)) }
                        if let fn = metadata.fNumber { row("光圈", String(format: "f/%.1f", fn)) }
                        if let iso = metadata.isoSpeed { row("ISO", "\(iso)") }
                        if let exp = metadata.exposureTime { row("快门", exp) }
                        if let taken = metadata.takenDate { row("拍摄时间", taken) }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: 300, alignment: .leading)
        }
        .frame(maxWidth: 300, maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding()
    }

    // MARK: - 构件

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.bold)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                content()
            }
            .padding(.vertical, 4)
        }
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(key)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .font(.callout)
    }
}
