//
//  FilterSidebarView.swift
//  FrameScoop
//
//  右侧「智能筛选」边栏。
//  通过 ContentView 的 .inspector 呈现，可由工具栏按钮折叠/展开。
//  连拍筛选 -- 按拍摄时间排序后相邻 + 画面相似（dHash）识别连拍并分段显示。
//  人脸模糊筛选 -- 检测人脸并判断是否模糊（任一清晰人脸即不算模糊），左上角标红感叹号。
//

import SwiftUI

struct FilterSidebarView: View {
    @EnvironmentObject var library: PhotoLibraryViewModel
    @State private var showKeepConfirm = false

    /// 「保留选中」将删除的未选中连拍照片数量（仅本组有被选中的连拍组）
    private var keepDeleteCount: Int {
        library.keepSelectedDeleteCount
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("智能筛选") {
                    Toggle("连拍筛选", isOn: $library.showsBurstFilter)
                        .help("按画面相似（dHash）识别连拍，并分段显示")
                }

                if library.showsBurstFilter {
                    Section("连拍判定") {
                        Stepper("相似度阈值：\(library.burstSimilarityThreshold)",
                                value: $library.burstSimilarityThreshold,
                                in: 0...30)
                            .help("画面差异（dHash 汉明距离）不超过此值视为相似；越小越严格")
                    }
                }

                Section("人脸筛选") {
                    Toggle("人脸筛选", isOn: $library.showsBlurFilter)
                        .help("一次 Vision 同时判断人脸模糊与闭眼；左上角标徽章（红=全模糊/全闭眼，黄=部分）")
                }

                if library.showsBlurFilter {
                    Section {
                        Toggle("只显示人脸模糊照片", isOn: $library.showsBlurOnly)
                            .help("开启后隐藏无人脸或人脸清晰的照片，仅显示人脸模糊的照片")
                        Toggle("只显示闭眼照片", isOn: $library.showsEyeClosedOnly)
                            .help("开启后隐藏无人脸或睁眼的照片，仅显示闭眼照片；与「只显示模糊」同开取交集")
                    }

                    Section("人脸模糊判定") {
                        Stepper("模糊阈值：\(Int(library.blurThreshold))",
                                value: $library.blurThreshold,
                                in: 1...200,
                                step: 1)
                            .help("人脸拉普拉斯方差低于此值视为该人脸模糊；越小越严格")
                    }

                    Section("闭眼判定") {
                        Stepper("闭眼阈值：\(String(format: "%.2f", library.eyeClosedThreshold))",
                                value: $library.eyeClosedThreshold,
                                in: 0.05...0.40,
                                step: 0.01)
                            .help("眼睛纵横比(EAR)低于此值视为闭眼；越小越严格")
                    }
                }
            }
            .formStyle(.grouped)

            // 连拍整理：开启连拍筛选时（默认仅显示连拍组）在边栏最底部呈现操作按钮
            if library.showsBurstFilter {
                Divider()
                VStack(spacing: 8) {
                    HStack(spacing: 10) {
                        Button(role: .destructive) {
                            library.trashSelectedPhotos()
                        } label: {
                            Label("删除选中", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(library.selectedPhotoIDs.isEmpty)

                        Button {
                            showKeepConfirm = true
                        } label: {
                            Label("保留选中", systemImage: "checkmark.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(library.selectedPhotoIDs.isEmpty || keepDeleteCount == 0)
                    }
                    Text("「保留选中」删除未选中的连拍照片（约 \(keepDeleteCount) 张），移到废纸篓可恢复")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
            }
        }
        // 「保留选中」会批量删除未选中照片，先确认再执行
        .confirmationDialog("保留选中的连拍照片？",
                           isPresented: $showKeepConfirm,
                           titleVisibility: .visible) {
            Button("删除其余 \(keepDeleteCount) 张", role: .destructive) {
                library.keepSelectedPhotos()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除当前未选中的 \(keepDeleteCount) 张连拍照片，保留选中的 \(library.selectedPhotoIDs.count) 张。删除后移到废纸篓，可恢复。")
        }
    }
}
