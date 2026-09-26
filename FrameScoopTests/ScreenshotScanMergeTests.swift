import XCTest
@testable import FrameScoop

/// 截屏扫描合并规则：文件夹来源由扫描结果全量权威，照片库来源不受影响。
/// 钉住曾经漏网的一类缺陷：集合只增不减 —— 原地被覆盖成非截屏的文件
/// 在 mtime 变化触发重扫后仍留在集合里（「只看截屏」滤出相机照片）。
final class ScreenshotScanMergeTests: XCTestCase {

    // MARK: - 文件夹来源：本次扫描结果权威

    /// 同名同路径被原地覆盖成非截屏（mtime 变、本次未命中）-> 旧判定必须摘除
    func testStaleFolderIDNotRefoundIsRemoved() {
        let merged = ScreenshotScanMerge.merged(existing: ["a", "b"],
                                                folderIDs: ["a", "b"],
                                                found: ["b"])
        XCTAssertEqual(merged, ["b"])
    }

    /// 本次命中的文件夹项保留（含此前已在集合里的）
    func testFoundFolderIDIsPresent() {
        let merged = ScreenshotScanMerge.merged(existing: ["a"],
                                                folderIDs: ["a", "b"],
                                                found: ["a", "b"])
        XCTAssertEqual(merged, ["a", "b"])
    }

    /// 新出现的截屏：本次命中但此前不在集合里，也要进集合
    func testNewlyFoundFolderIDIsAdded() {
        let merged = ScreenshotScanMerge.merged(existing: [],
                                                folderIDs: ["a"],
                                                found: ["a"])
        XCTAssertEqual(merged, ["a"])
    }

    /// 全部未命中（文件夹整个换成相机照片）-> 文件夹项清空
    func testEmptyFoundClearsAllFolderIDs() {
        let merged = ScreenshotScanMerge.merged(existing: ["a", "b"],
                                                folderIDs: ["a", "b"],
                                                found: [])
        XCTAssertTrue(merged.isEmpty)
    }

    // MARK: - 照片库来源：不参与合并

    /// 照片库 id（"ph:" 前缀）不在 folderIDs 里 -> 无论 found 如何都原样保留
    func testLibraryIDsSurviveUntouched() {
        let merged = ScreenshotScanMerge.merged(existing: ["ph:1", "ph:2", "a"],
                                                folderIDs: ["a"],
                                                found: [])
        XCTAssertEqual(merged, ["ph:1", "ph:2"])
    }

    /// 无文件夹项（照片库节点）-> 集合不变
    func testNoFolderIDsLeavesSetUnchanged() {
        let merged = ScreenshotScanMerge.merged(existing: ["ph:1", "ph:2"],
                                                folderIDs: [],
                                                found: [])
        XCTAssertEqual(merged, ["ph:1", "ph:2"])
    }
}
