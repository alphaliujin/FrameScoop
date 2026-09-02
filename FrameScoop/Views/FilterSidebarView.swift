//
//  FilterSidebarView.swift
//  FrameScoop
//
//  右侧「智能筛选」边栏。
//  通过 ContentView 的 .inspector 呈现，可由工具栏按钮折叠/展开。
//  连拍筛选 -- 按拍摄时间排序后相邻 + 画面相似（dHash）识别连拍并分段显示。
//  人脸模糊筛选 -- 检测人脸并判断是否模糊（任一清晰人脸即不算模糊），左上角标红 face.dashed。
//

import SwiftUI

struct FilterSidebarView: View {
    @EnvironmentObject var library: PhotoLibraryViewModel
    @State private var showKeepConfirm = false

    var body: some View {
        // 「保留选中」将删除的未选中连拍照片数量（仅本组有被选中的连拍组）。
        // 绑一次 local，避免下面 4 处引用各算一遍（每次遍历 burstSegments）。
        let keepDeleteCount = library.keepSelectedDeleteCount
        VStack(spacing: 0) {
            Form {
                Section("智能筛选") {
                    Toggle("连拍筛选", isOn: $library.showsBurstFilter)
                        .help("按画面相似（dHash）识别连拍，并分段显示")
                    Toggle("人脸筛选", isOn: $library.showsBlurFilter)
                        .help("一次 Vision 检测人脸，按拉普拉斯方差判断人脸模糊；左上角标红/黄 face.dashed")
                    Toggle("闭眼检测", isOn: $library.showsEyeClosedFilter)
                        .help("与人脸筛选共享同一次 Vision，按眼睛纵横比(EAR)判断闭眼；左上角标红/黄 eye.slash")
                }

                if !library.selectedPhotoIDs.isEmpty {
                    Section("选择") {
                        Toggle("只显示选中", isOn: $library.showsSelectedOnly)
                            .help("仅显示已选中的 \(library.selectedPhotoIDs.count) 张图片")
                    }
                }

                if library.showsBurstFilter {
                    Section("连拍判定") {
                        Stepper("相似度阈值：\(library.burstSimilarityThreshold)",
                                value: $library.burstSimilarityThreshold,
                                in: 0...30)
                            .help("画面差异（dHash 汉明距离）不超过此值视为相似；越小越严格")
                    }
                }

                if library.showsBlurFilter {
                    Section {
                        Toggle("只显示人脸模糊照片", isOn: $library.showsBlurOnly)
                            .help("开启后隐藏无人脸或人脸清晰的照片，仅显示人脸模糊的照片")
                    }

                    Section("人脸模糊判定") {
                        Stepper("模糊阈值：\(Int(library.blurThreshold))",
                                value: $library.blurThreshold,
                                in: 1...200,
                                step: 1)
                            .help("人脸拉普拉斯方差低于此值视为该人脸模糊；越小越严格")
                    }
                }

                if library.showsEyeClosedFilter {
                    Section {
                        Toggle("只显示闭眼照片", isOn: $library.showsEyeClosedOnly)
                            .help("开启后隐藏无人脸或睁眼的照片，仅显示闭眼照片；与「只显示模糊」同开取交集")
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

            // 选中图片时显示「删除选中」按钮
            if !library.selectedPhotoIDs.isEmpty {
                Divider()
                VStack(spacing: 8) {
                    Button(role: .destructive) {
                        library.trashSelectedPhotos()
                    } label: {
                        Label("删除选中（\(library.selectedPhotoIDs.count) 张）", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    // 连拍筛选开启时额外提供「保留选中」
                    if library.showsBurstFilter {
                        Button {
                            showKeepConfirm = true
                        } label: {
                            Label("保留选中", systemImage: "checkmark.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(keepDeleteCount == 0)

                        Text("「保留选中」删除未选中的连拍照片（约 \(keepDeleteCount) 张），移到废纸篓可恢复")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(12)
            }

            brandLogo
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

    /// 右边栏底部品牌区:图形标记(图片) + 三行文字,与原整幅品牌图视觉一致。
    /// 文字用 .primary 全浓度自动适配明暗(浅色模式近黑、深色模式近白),图形标记保持半透明。
    private var brandLogo: some View {
        VStack(spacing: 0) {
            Image("BrandMark")
                .resizable()
                .scaledToFit()
                .frame(height: 30)          // ≈ 原图标记占比 18%(实测裁剪 119×63)
                .opacity(0.55)
                .padding(.bottom, 6)
            Text("FrameScoop")
                .font(.system(size: 17, weight: .bold))   // ≈ 原图字高 12%
                .padding(.bottom, 3)
            Text("光影为诗，拾帧成集")
                .font(.system(size: 14))                  // ≈ 原图标语占比 11%
                .foregroundStyle(Self.taglineGreen)       // 深绿(品牌青色加深);深色模式用亮绿保证可读性
                .padding(.bottom, 2)
            Text("version \(Self.appVersion)")
                .font(.system(size: 9))                   // 原图约 4%,按可读性取 9
        }
        .foregroundStyle(.primary)
        .padding(.vertical, 14)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
    }

    /// 版本号(完整 CFBundleShortVersionString,如 "1.0.7"; 缺失时兜底 "1.0")
    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    /// 标语行颜色: 浅色模式深绿(品牌青色 0.220/0.724/0.638 加深),深色模式亮绿同色系
    @Environment(\.colorScheme) private var colorScheme
    private static let taglineGreenDark = Color(red: 0.12, green: 0.40, blue: 0.35)
    private static let taglineGreenLight = Color(red: 0.42, green: 0.78, blue: 0.66)
    private var taglineGreen: Color {
        colorScheme == .dark ? Self.taglineGreenLight : Self.taglineGreenDark
    }
}
