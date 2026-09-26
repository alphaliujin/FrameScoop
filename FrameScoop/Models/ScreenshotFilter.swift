//
//  ScreenshotFilter.swift
//  FrameScoop
//
//  截屏筛选三态。三态天然互斥，避免既有 showsBlurFilter/showsBurstFilter
//  那套「两个 didSet 互相置 false」的互斥写法（该模式在三个筛选上已显冗余）。
//

import Foundation

enum ScreenshotFilter: String, CaseIterable, Codable {
    case off       // 不过滤
    case only      // 只看截屏（清理场景）
    case exclude   // 隐藏截屏（选片场景）

    var label: String {
        switch self {
        case .off:     return "全部"
        case .only:    return "只看截屏"
        case .exclude: return "隐藏截屏"
        }
    }
}
