import XCTest
@testable import FrameScoop

final class ScreenshotDetectionTests: XCTestCase {

    // MARK: - 文件名判据

    func testChineseSystemScreenshotName() {
        XCTAssertTrue(ScreenshotDetectionService.matchesFilename("截屏2026-09-26 14.30.00.png"))
    }

    func testChineseSystemScreenshotNameWithMeridiem() {
        XCTAssertTrue(ScreenshotDetectionService.matchesFilename("截屏2026-09-26 下午2.30.00.png"))
    }

    func testEnglishSystemScreenshotName() {
        XCTAssertTrue(ScreenshotDetectionService.matchesFilename("Screenshot 2026-09-26 at 2.30.00 PM.png"))
    }

    func testLegacyEnglishScreenShotName() {
        XCTAssertTrue(ScreenshotDetectionService.matchesFilename("Screen Shot 2026-09-26 at 2.30.00 PM.png"))
    }

    func testWeChatScreenshotName() {
        XCTAssertTrue(ScreenshotDetectionService.matchesFilename("微信截图_20260926143000.png"))
    }

    func testEnterpriseWeChatScreenshotName() {
        XCTAssertTrue(ScreenshotDetectionService.matchesFilename("企业微信截图_20260926143000.png"))
    }

    func testQQScreenshotName() {
        XCTAssertTrue(ScreenshotDetectionService.matchesFilename("QQ截图20260926143000.png"))
    }

    func testSnipasteScreenshotName() {
        XCTAssertTrue(ScreenshotDetectionService.matchesFilename("Snipaste_2026-09-26_14-30-00.png"))
    }

    func testCleanShotScreenshotName() {
        XCTAssertTrue(ScreenshotDetectionService.matchesFilename("CleanShot 2026-09-26 at 14.30.00@2x.png"))
    }

    func testCameraFilenameIsNotScreenshot() {
        XCTAssertFalse(ScreenshotDetectionService.matchesFilename("2T9A3048.JPG"))
    }

    func testAppleOriginalFilenameIsNotScreenshot() {
        XCTAssertFalse(ScreenshotDetectionService.matchesFilename("IMG_1234.HEIC"))
    }

    /// 前缀匹配而非子串：句中出现的"截图"不算
    func testSubstringTrapIsNotScreenshot() {
        XCTAssertFalse(ScreenshotDetectionService.matchesFilename("我的截图旅行.jpg"))
    }

    /// 大小写不敏感
    func testFilenameMatchIsCaseInsensitive() {
        XCTAssertTrue(ScreenshotDetectionService.matchesFilename("SCREENSHOT 2026-09-26.png"))
    }
}
