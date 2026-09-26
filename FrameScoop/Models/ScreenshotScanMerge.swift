//
//  ScreenshotScanMerge.swift
//  FrameScoop
//
//  截屏扫描结果与既有判定的合并规则（纯函数，单元测试锁定）。
//

import Foundation

enum ScreenshotScanMerge {

    /// 扫描结果与既有判定的合并规则。
    /// 扫描每次都重读全部文件夹项，故其对「文件夹来源」完全权威：
    /// 先摘掉全部文件夹项旧判定，再填回本次命中 —— 若只做 formUnion，
    /// 原地被覆盖成非截屏的文件会永久留在集合里。
    /// 照片库来源的判定来自加载路径，不参与合并、不受影响。
    static func merged(existing: Set<String>,
                       folderIDs: Set<String>,
                       found: Set<String>) -> Set<String> {
        existing.subtracting(folderIDs).union(found)
    }
}
