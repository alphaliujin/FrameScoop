import XCTest
@testable import FrameScoop

/// 连拍分组的顺序测试。
///
/// 背景：`BurstDetectionService.group()` 内部固定按 creationDate **升序** 排序后分组
/// （这是算法前提：连拍在时间轴上相邻，必须按时间扫描才能只比相邻张，把 O(n²) 降到 O(n)）。
/// 而 `PhotoLibraryViewModel.rebuildDisplayedPhotos()` 在连拍模式下曾直接 flatMap 段、
/// 不经过 `sort(_:)`，导致 `sortOption`/`sortOrder` 被完全旁路 ——
/// 默认 sortOrder == .descending 时，开启连拍筛选会让网格整体翻转成「最旧在前」。
///
/// 修复后的职责划分：**分组恒用升序（算法约束），展示恒用 sortOrder（用户约束）**。
final class BurstOrderTests: XCTestCase {

    /// photoID 是 url.path，不是 name —— 查表（hashes / numbers）一律用它做键
    private func id(_ name: String) -> String { "/tmp/\(name).jpg" }

    /// 构造一张连拍用的照片：creationDate 用秒偏移量表示先后
    private func photo(_ name: String, _ secondsFromEpoch: TimeInterval) -> PhotoItem {
        PhotoItem(url: URL(fileURLWithPath: "/tmp/\(name).jpg"),
                  name: name,
                  size: 0,
                  creationDate: Date(timeIntervalSince1970: secondsFromEpoch),
                  modificationDate: Date(timeIntervalSince1970: secondsFromEpoch))
    }

    /// 段的形状描述：单张直接写名字，连拍组写成 [名字,...]，便于一眼看出段序与组内序
    private func shape(_ segments: [BurstSegment]) -> String {
        segments.map { seg in
            switch seg {
            case .single(let p): return p.name
            case .burst(let ps): return "[" + ps.map(\.name).joined(separator: ",") + "]"
            }
        }.joined(separator: " ")
    }

    /// 一个典型输入：单张 a + 连拍组 [b,c] + 单张 d，时间递增
    private func sampleSegments() -> [BurstSegment] {
        [.single(photo("a", 100)),
         .burst([photo("b", 200), photo("c", 300)]),
         .single(photo("d", 400))]
    }

    // MARK: - group() 的升序前提

    /// 特征测试：确认 group() 的输出恒为**升序**（最旧在前），且与传入顺序无关。
    /// 这不是展示选择，而是分组算法本身的要求，改动它会把 O(n) 退化为 O(n²)。
    func testGroupEmitsAscendingOrderRegardlessOfInputOrder() {
        // 故意打乱传入顺序
        let photos = [photo("c", 300), photo("a", 100), photo("b", 200)]
        // hashes 以 photoID 为键，而 photoID 是 url.path（不是 name）
        // 全部给相同哈希 -> Hamming 距离 0 <= 阈值 -> 合并为一个连拍组
        let hashes = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, UInt64(0)) })

        let segments = BurstDetectionService.group(photos: photos,
                                                   hashes: hashes,
                                                   similarityThreshold: 10)

        XCTAssertEqual(segments.count, 1, "三张相似照片应合并为一个连拍组")
        XCTAssertEqual(shape(segments), "[a,b,c]", "group() 固定升序输出：最旧(a)在前，最新(c)在后")
    }

    // MARK: - ordered()：段间与段内统一遵循排序方向

    /// 降序：段序与组内序**同时**倒转 —— 最新在前，且组内最新的一张排最左。
    func testOrderedDescendingReversesSegmentsAndGroupContents() {
        let ordered = BurstDetectionService.ordered(sampleSegments(), order: .descending)

        XCTAssertEqual(shape(ordered), "d [c,b] a",
                       "降序：最新的单张 d 在最前；组内最新的 c 在 b 前；最旧的 a 在最后")
    }

    /// 升序：与 group() 的输出保持一致（不改变既有行为）。
    func testOrderedAscendingKeepsInputOrder() {
        let ordered = BurstDetectionService.ordered(sampleSegments(), order: .ascending)

        XCTAssertEqual(shape(ordered), "a [b,c] d",
                       "升序：最旧在前，组内最旧的 b 在 c 前")
    }

    /// ordered() 只改顺序，不改分组结果本身（组成员、段数量均不变）。
    func testOrderedPreservesGrouping() {
        let input = sampleSegments()
        let ordered = BurstDetectionService.ordered(input, order: .descending)

        XCTAssertEqual(ordered.count, input.count, "段数量不变")
        XCTAssertEqual(shape(ordered).replacingOccurrences(of: "[", with: "")
                                    .replacingOccurrences(of: "]", with: "")
                                    .replacingOccurrences(of: ",", with: " ")
                                    .split(separator: " ").sorted(),
                       ["a", "b", "c", "d"],
                       "所有照片一张不少")
    }

    /// 缺 creationDate 的照片回退为 distantPast，不应导致崩溃或丢段。
    func testOrderedHandlesMissingCreationDate() {
        let noDate = PhotoItem(url: URL(fileURLWithPath: "/tmp/x.jpg"), name: "x", size: 0,
                               creationDate: nil, modificationDate: nil)
        let ordered = BurstDetectionService.ordered(
            [.single(photo("a", 100)), .burst([noDate, photo("b", 200)])],
            order: .descending)

        XCTAssertEqual(shape(ordered), "a [b,x]", "nil 日期视为最旧，降序时排在组内最后")
    }

    // MARK: - 角标编号锚定「显示顺序」

    /// 降序展示时，角标 1 应指向组内**最新**的那张（编号跟随显示位置，而非拍摄序）。
    func testNumbersAnchorToDisplayOrderWhenDescending() {
        let ordered = BurstDetectionService.ordered(sampleSegments(), order: .descending)
        let numbers = BurstDetectionService.numbers(for: ordered)

        XCTAssertEqual(numbers[id("c")], 1, "降序：组内最新的 c 是第 1 张")
        XCTAssertEqual(numbers[id("b")], 2, "降序：组内较旧的 b 是第 2 张")
        XCTAssertNil(numbers[id("a")], "单张没有角标编号")
    }

    /// 升序展示时，角标 1 指向组内最旧的那张 —— 与拍摄序一致。
    func testNumbersAnchorToDisplayOrderWhenAscending() {
        let ordered = BurstDetectionService.ordered(sampleSegments(), order: .ascending)
        let numbers = BurstDetectionService.numbers(for: ordered)

        XCTAssertEqual(numbers[id("b")], 1, "升序：组内最旧的 b 是第 1 张")
        XCTAssertEqual(numbers[id("c")], 2, "升序：组内较新的 c 是第 2 张")
    }

    /// 角标在同一组内恒为 1..n 连续（从显示首位起算），不跳号。
    func testNumbersAreContiguousWithinGroup() {
        let group = [photo("p", 100), photo("q", 200), photo("r", 300)]
        let numbers = BurstDetectionService.numbers(for: [.burst(group)])

        XCTAssertEqual(Set(numbers.values), [1, 2, 3], "三张照片编号恰为 1,2,3")
    }

    // MARK: - 端到端组合（本 bug 的回归防线）

    /// 复刻 VM 连拍分支的完整处理链：
    /// `group()` -> 过滤出连拍组（displayedBurstSegments）-> `ordered()` -> flatMap。
    ///
    /// 修复前该链路缺 `ordered()` 这一步，降序下会得到「最旧在前」——
    /// 这正是「打开连拍筛选以后排序就反了」。
    func testBurstPipelineYieldsNewestFirstWhenDescending() {
        // a、b 画面相似成一组；c、d 各自独立（哈希两两距离 > 阈值）
        let photos = [photo("a", 100), photo("b", 200), photo("c", 300), photo("d", 400)]
        let hashes: [String: UInt64] = [
            id("a"): 0x0000_0000_0000_0000,
            id("b"): 0x0000_0000_0000_0001,   // 与 a 距离 1 -> 同组
            id("c"): 0xFFFF_FFFF_FFFF_FFFF,   // 与 a/b 距离极大 -> 独立
            id("d"): 0x0000_0000_0000_FFFF,   // 与 c 距离 48、与 b 距离 16 -> 独立
        ]

        // 1) 分组（恒升序）
        let segments = BurstDetectionService.group(photos: photos,
                                                   hashes: hashes,
                                                   similarityThreshold: 2)
        XCTAssertEqual(shape(segments), "[a,b] c d", "前提：group() 升序分组")

        // 2) 连拍模式只展示连拍组（对应 displayedBurstSegments 的过滤）
        let bursts = segments.filter { if case .burst = $0 { return true }; return false }

        // 3) 按排序方向重排 + 扁平化（对应 displayedBurstSegments 内部 + rebuildDisplayedPhotos）
        let ordered = BurstDetectionService.ordered(bursts, order: .descending)
        let displayed = ordered.flatMap { seg -> [PhotoItem] in
            switch seg {
            case .single(let p): return [p]
            case .burst(let ps): return ps
            }
        }

        XCTAssertEqual(displayed.map(\.name), ["b", "a"],
                       "降序下网格应为「组内最新在前」——修复前这里会是 [a,b]")

        // 角标锚定显示位置：b 是第 1 张
        let numbers = BurstDetectionService.numbers(for: ordered)
        XCTAssertEqual(numbers[id("b")], 1)
        XCTAssertEqual(numbers[id("a")], 2)
    }

    /// 同一链路在升序下应保持拍摄序（回归：修复不能把升序也弄反）。
    func testBurstPipelineKeepsShootingOrderWhenAscending() {
        let photos = [photo("a", 100), photo("b", 200)]
        let hashes: [String: UInt64] = [id("a"): 0, id("b"): 1]

        let segments = BurstDetectionService.group(photos: photos,
                                                   hashes: hashes,
                                                   similarityThreshold: 2)
        let ordered = BurstDetectionService.ordered(segments, order: .ascending)
        let displayed = ordered.flatMap { seg -> [PhotoItem] in
            switch seg {
            case .single(let p): return [p]
            case .burst(let ps): return ps
            }
        }

        XCTAssertEqual(displayed.map(\.name), ["a", "b"], "升序下仍是拍摄序")
    }
}
