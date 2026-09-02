import XCTest
import CoreGraphics
@testable import FrameScoop

final class MarqueeSelectionTests: XCTestCase {

    private func photo(_ name: String) -> PhotoItem {
        PhotoItem(url: URL(fileURLWithPath: "/tmp/\(name).jpg"), name: "\(name).jpg", size: 0,
                  creationDate: nil, modificationDate: nil, pixelWidth: 1, pixelHeight: 1)
    }

    private func frames(_ names: [String]) -> [GridPhotoFrame] {
        GridGeometry.flowFrames(items: names.map(photo), rowHeight: 100, spacing: 4, availableWidth: 400)
    }

    func testHitIntersectsOnlyOverlapping() {
        // a(0,0,100,100) b(104,0,100,100): rect(50,0,50,100) 只与 a 相交
        let hit = GridGeometry.hitPhotoIDs(in: CGRect(x: 50, y: 0, width: 50, height: 100),
                                           frames: frames(["a", "b"]))
        XCTAssertEqual(hit, ["/tmp/a.jpg"])
    }

    func testHitPartialIntersectionCounts() {
        // 擦到 b 左边缘 1pt 也算命中(部分相交)
        let hit = GridGeometry.hitPhotoIDs(in: CGRect(x: 100, y: 0, width: 10, height: 100),
                                           frames: frames(["a", "b"]))
        XCTAssertEqual(hit, ["/tmp/b.jpg"])
    }

    func testHitEmptyRectHitsNothing() {
        let hit = GridGeometry.hitPhotoIDs(in: CGRect(x: 500, y: 500, width: 10, height: 10),
                                           frames: frames(["a", "b"]))
        XCTAssertTrue(hit.isEmpty)
    }

    func testResolveReplace() {
        XCTAssertEqual(MarqueeSelection.resolve(current: ["a", "b"], hit: ["c"], additive: false), ["c"])
    }

    func testResolveReplaceWithEmptyHitClears() {
        XCTAssertTrue(MarqueeSelection.resolve(current: ["a", "b"], hit: [], additive: false).isEmpty)
    }

    func testResolveAdditiveUnions() {
        XCTAssertEqual(MarqueeSelection.resolve(current: ["a", "b"], hit: ["c"], additive: true), ["a", "b", "c"])
    }
}
