//
//  AppearanceConfigurator.swift
//  FrameScoop
//
//  应用级一次性外观配置（导航/工具栏样式、强调色等）。
//

import SwiftUI

/// 应用启动时统一配置外观，避免在各个视图中重复设置。
enum AppearanceConfigurator {

    static func configure() {
        // 让 NavigationSplitView 侧边栏使用标准半透明毛玻璃效果（Sonoma 默认支持），无需额外代码。
        // 强调色使用系统强调色，遵循 HIG“让用户掌控外观”原则；如需固定品牌色，可在此设置
        // NSColor.controlAccentColor。此处保留为集中扩展点，不输出日志以免污染控制台。
    }
}
