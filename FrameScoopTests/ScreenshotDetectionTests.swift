import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
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

    // MARK: - 文件头判据

    /// 现场生成样本图。ImageIO 既能写也能读 EXIF UserComment（已实测往返），
    /// 因此不需要把二进制夹具入库。
    private func makePNG(named: String, userComment: String?) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(named)
        try? FileManager.default.removeItem(at: url)
        let ctx = CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        let props: CFDictionary? = userComment.map {
            [kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: $0]] as CFDictionary
        }
        CGImageDestinationAddImage(dest, ctx.makeImage()!, props)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    func testMarkerPresentIsScreenshot() {
        let url = makePNG(named: "fs-marker-yes.png", userComment: "Screenshot")
        XCTAssertTrue(ScreenshotDetectionService.hasScreenshotMarker(at: url))
    }

    func testMarkerAbsentIsNotScreenshot() {
        let url = makePNG(named: "fs-marker-no.png", userComment: nil)
        XCTAssertFalse(ScreenshotDetectionService.hasScreenshotMarker(at: url))
    }

    func testMarkerMatchIsCaseInsensitive() {
        let url = makePNG(named: "fs-marker-lower.png", userComment: "screenshot")
        XCTAssertTrue(ScreenshotDetectionService.hasScreenshotMarker(at: url))
    }

    /// 全等而非子串：多一个 s 不算
    func testMarkerNearMissIsNotScreenshot() {
        let url = makePNG(named: "fs-marker-plural.png", userComment: "Screenshots")
        XCTAssertFalse(ScreenshotDetectionService.hasScreenshotMarker(at: url))
    }

    func testMissingFileIsNotScreenshotAndDoesNotCrash() {
        let url = URL(fileURLWithPath: "/tmp/fs-does-not-exist-\(UUID().uuidString).png")
        XCTAssertFalse(ScreenshotDetectionService.hasScreenshotMarker(at: url))
    }

    // MARK: - 组合判定

    /// 文件名不匹配但文件头带标记 —— 用户把截屏改名后仍能识别
    func testRenamedScreenshotStillDetectedByMarker() {
        let url = makePNG(named: "DSC_0001.png", userComment: "Screenshot")
        XCTAssertTrue(ScreenshotDetectionService.isScreenshot(name: "DSC_0001.png", url: url))
    }

    /// 文件名命中即算，无需读文件头（第三方工具截图不带标记）
    func testFilenameMatchAloneIsEnough() {
        let url = makePNG(named: "微信截图_20260926143000.png", userComment: nil)
        XCTAssertTrue(ScreenshotDetectionService.isScreenshot(name: "微信截图_20260926143000.png", url: url))
    }

    /// 两者都不匹配 —— 相机原图
    func testRealPhotoIsNotScreenshot() {
        let url = makePNG(named: "2T9A3048.png", userComment: nil)
        XCTAssertFalse(ScreenshotDetectionService.isScreenshot(name: "2T9A3048.png", url: url))
    }
}
