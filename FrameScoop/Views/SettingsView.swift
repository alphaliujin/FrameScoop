//
//  SettingsView.swift
//  FrameScoop
//
//  偏好设置窗口（命令 , 打开）。
//  模仿“照片”偏好设置：默认排序、缩略图尺寸、缓存管理。
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var library: PhotoLibraryViewModel
    @State private var clearing = false

    var body: some View {
        Form {
            Section("浏览") {
                Picker("默认排序方式", selection: $library.sortOption) {
                    ForEach(SortOption.allCases, id: \.self) { opt in
                        Text(opt.label).tag(opt)
                    }
                }
                Picker("默认排序方向", selection: $library.sortOrder) {
                    ForEach(SortOrder.allCases, id: \.self) { ord in
                        Text(ord.label).tag(ord)
                    }
                }
                Picker("缩略图大小", selection: $library.thumbnailSize) {
                    ForEach(ThumbnailSize.allCases, id: \.self) { size in
                        Text(size.label).tag(size)
                    }
                }
            }

            Section("缓存") {
                Button("清除缩略图缓存") {
                    clearing = true
                    Task.detached { @MainActor in
                        ThumbnailCacheService.shared.clearCache()
                        clearing = false
                    }
                }
                .disabled(clearing)
                if clearing { Text("正在清除…").foregroundStyle(.secondary) }
            }

            Section("关于") {
                LabeledContent("版本", value: appVersion)
                LabeledContent("最低系统", value: "macOS 14 Sonoma")
                LabeledContent("架构支持", value: "Apple Silicon · Intel")
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 420, height: 480)
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}
