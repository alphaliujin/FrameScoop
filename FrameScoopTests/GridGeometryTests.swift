import XCTest
import CoreGraphics
@testable import FrameScoop

final class GridGeometryTests: XCTestCase {

    private func photo(_ name: String, _ w: Int, _ h: Int) -> PhotoItem {
        PhotoItem(url: URL(fileURLWithPath: "/tmp/\(name).jpg"), name: "\(name).jpg", size: 0,
                  creationDate: nil, modificationDate: nil, pixelWidth: w, pixelHeight: h)
    }

    func testFlowFramesSingleRow() {
        // 2 张 1:1(100)+ 1 张 2:1(200): 100+4+100+4+200 = 408 > 400? 否: 100+4+100+4=208, +4+200=412 > 400 → 第三张换行
        let items = [photo("a", 1, 1), photo("b", 1, 1), photo("c", 2, 1)]
        let frames = GridGeometry.flowFrames(items: items, rowHeight: 100, spacing: 4, availableWidth: 400)
        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(frames[0].frame, CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(frames[1].frame, CGRect(x: 104, y: 0, width: 100, height: 100))
        XCTAssertEqual(frames[2].frame, CGRect(x: 0, y: 104, width: 200, height: 100))
    }

    func testFlowFramesWrapsOnOverflow() {
        // 300 宽放不下第 3 张(100+4+100+4+100=308>300)
        let items = [photo("a", 1, 1), photo("b", 1, 1), photo("c", 1, 1)]
        let frames = GridGeometry.flowFrames(items: items, rowHeight: 100, spacing: 4, availableWidth: 300)
        XCTAssertEqual(frames.map { $0.frame.origin }, [CGPoint(x: 0, y: 0), CGPoint(x: 104, y: 0), CGPoint(x: 0, y: 104)])
    }

    func testFlowFramesZeroWidthSingleRow() {
        // availableWidth <= 0 时旧行为: 全部单行
        let items = [photo("a", 1, 1), photo("b", 1, 1)]
        let frames = GridGeometry.flowFrames(items: items, rowHeight: 100, spacing: 4, availableWidth: 0)
        XCTAssertEqual(frames.map { $0.frame.origin.y }, [0, 0])
        XCTAssertEqual(frames[1].frame.origin.x, 104)
    }

    func testFlowRowsGroupsByRow() {
        let items = [photo("a", 1, 1), photo("b", 1, 1), photo("c", 1, 1)]
        let rows = GridGeometry.flowRows(items: items, rowHeight: 100, spacing: 4, availableWidth: 300)
        XCTAssertEqual(rows.map { $0.map(\.name) }, [["a.jpg", "b.jpg"], ["c.jpg"]])
    }

    func testFlowFramesKeepsRowWhenExactlyFits() {
        // 边界回归: 3×100 + 2×4 = 308 <= 310 同行(旧规则);若多算一个尾部 spacing(312 > 310)会错误换行
        let items = [photo("a", 1, 1), photo("b", 1, 1), photo("c", 1, 1)]
        let frames = GridGeometry.flowFrames(items: items, rowHeight: 100, spacing: 4, availableWidth: 310)
        XCTAssertEqual(frames.map { $0.frame.origin },
                       [CGPoint(x: 0, y: 0), CGPoint(x: 104, y: 0), CGPoint(x: 208, y: 0)])
    }

    // MARK: - 连拍布局

    func testBurstFramesExclusiveRowsAndTrailingGap() {
        // 单张 a + 连拍组(b,c) + 单张 d: 组独占行、组末行留白(d 不在 b,c 行尾)
        let segs: [BurstSegment] = [
            .single(photo("a", 1, 1)),
            .burst([photo("b", 1, 1), photo("c", 1, 1)]),
            .single(photo("d", 1, 1))
        ]
        let frames = GridGeometry.burstFrames(segments: segs, cellWidth: { _ in 100 },
                                              rowHeight: 100, spacing: 4, availableWidth: 400)
        XCTAssertEqual(frames.map { $0.photo.name }, ["a.jpg", "b.jpg", "c.jpg", "d.jpg"])
        XCTAssertEqual(frames[0].frame.origin, CGPoint(x: 0, y: 0))
        XCTAssertEqual(frames[1].frame.origin, CGPoint(x: 0, y: 104))
        XCTAssertEqual(frames[2].frame.origin, CGPoint(x: 104, y: 104))
        XCTAssertEqual(frames[3].frame.origin, CGPoint(x: 0, y: 208))
    }

    func testBurstFramesGroupInternalWrap() {
        // 组内放不下时组内换行(仍独占自己的行,不接下一段)
        let segs: [BurstSegment] = [
            .burst([photo("b", 1, 1), photo("c", 1, 1), photo("d", 1, 1)]),
            .single(photo("e", 1, 1))
        ]
        let frames = GridGeometry.burstFrames(segments: segs, cellWidth: { _ in 100 },
                                              rowHeight: 100, spacing: 4, availableWidth: 210)
        // b,c 同行(0,0)/(104,0);d 组内换行(0,104);e 新行(0,208)
        XCTAssertEqual(frames.map { $0.frame.origin },
                       [CGPoint(x: 0, y: 0), CGPoint(x: 104, y: 0),
                        CGPoint(x: 0, y: 104), CGPoint(x: 0, y: 208)])
    }

    func testBurstFramesSinglesFlowAcrossSegments() {
        // 连续单张段流式同行(与旧 behavior 一致)
        let segs: [BurstSegment] = [.single(photo("a", 1, 1)), .single(photo("b", 1, 1))]
        let frames = GridGeometry.burstFrames(segments: segs, cellWidth: { _ in 100 },
                                              rowHeight: 100, spacing: 4, availableWidth: 400)
        XCTAssertEqual(frames.map { $0.frame.origin }, [CGPoint(x: 0, y: 0), CGPoint(x: 104, y: 0)])
    }

    func testBurstRowsMatchesFrames() {
        let segs: [BurstSegment] = [
            .single(photo("a", 1, 1)),
            .burst([photo("b", 1, 1), photo("c", 1, 1)]),
            .single(photo("d", 1, 1))
        ]
        let rows = GridGeometry.burstRows(segments: segs, cellWidth: { _ in 100 },
                                          rowHeight: 100, spacing: 4, availableWidth: 400)
        XCTAssertEqual(rows.map { $0.map(\.name) }, [["a.jpg"], ["b.jpg", "c.jpg"], ["d.jpg"]])
    }

    func testBurstFramesConsecutiveBurstsNoPhantomGap() {
        // 边界回归: displayedBurstSegments 过滤掉 .single 后连续 .burst 是常态;
        // 旧布局行号连续、组间无空行。若对每个组先推进一行再发射,第二组会跑到 y=208(幽灵空行)。
        let segs: [BurstSegment] = [.burst([photo("a", 1, 1)]), .burst([photo("b", 1, 1)])]
        let frames = GridGeometry.burstFrames(segments: segs, cellWidth: { _ in 100 },
                                              rowHeight: 100, spacing: 4, availableWidth: 400)
        XCTAssertEqual(frames.map { $0.frame.origin }, [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 104)])
    }
}
