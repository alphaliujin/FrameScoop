import XCTest
@testable import FrameScoop

final class RangeSelectionTests: XCTestCase {

    /// 6 个 id 的有序列表
    private let ids = ["a", "b", "c", "d", "e", "f"]

    func testForwardRangeIncludesBothEnds() {
        XCTAssertEqual(RangeSelection.range(from: "b", to: "e", in: ids), ["b", "c", "d", "e"])
    }

    func testBackwardRangeSameSet() {
        XCTAssertEqual(RangeSelection.range(from: "e", to: "b", in: ids), ["b", "c", "d", "e"])
    }

    func testSamePhotoIsSingleton() {
        XCTAssertEqual(RangeSelection.range(from: "c", to: "c", in: ids), ["c"])
    }

    func testMissingFromIsEmpty() {
        XCTAssertTrue(RangeSelection.range(from: "x", to: "c", in: ids).isEmpty)
    }

    func testMissingToIsEmpty() {
        XCTAssertTrue(RangeSelection.range(from: "c", to: "x", in: ids).isEmpty)
    }

    func testAdjacentPair() {
        XCTAssertEqual(RangeSelection.range(from: "b", to: "c", in: ids), ["b", "c"])
    }

    func testEmptyListIsEmpty() {
        XCTAssertTrue(RangeSelection.range(from: "a", to: "b", in: []).isEmpty)
    }
}
