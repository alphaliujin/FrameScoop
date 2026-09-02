import XCTest
@testable import FrameScoop

final class SmokeTests: XCTestCase {
    /// 冒烟: 测试模块可加载且宿主 app 可运行(真实断言,验证 200x100 → aspectRatio 2)
    func testModuleLoadsAndHostAppRuns() {
        let p = PhotoItem(url: URL(fileURLWithPath: "/tmp/smoke.jpg"), name: "smoke.jpg", size: 0,
                          creationDate: nil, modificationDate: nil, pixelWidth: 200, pixelHeight: 100)
        XCTAssertEqual(p.aspectRatio, 2)
    }
}
