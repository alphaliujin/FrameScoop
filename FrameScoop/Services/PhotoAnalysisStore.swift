//
//  PhotoAnalysisStore.swift
//  FrameScoop
//
//  按照片派生分析的持久化缓存：dHash（连拍筛选）+ FaceBlurScore（人脸模糊筛选）。
//  两类数据合并存一份，共用同一份 mtime 失效逻辑；各字段可独立存在
//  （仅算过连拍则 blur=nil，仅算过模糊则 dHash=nil，互不重算、互不覆盖）。
//  跨会话复用：连拍/模糊筛选二次打开可直接跳过取图+算分，仅做分组/分类（瞬时）。
//
//  dHash 以 16 进制字符串存储（UInt64 超 JSON 安全整数 2^53，直接编码会丢精度）。
//  按照片 mtime 失效：文件改动则 mtime 变，该张重算；其余复用。
//

import Foundation

enum PhotoAnalysisStore {
    private struct Entry: Codable {
        var mtime: Double
        var dHash: String?        // 16 进制；nil=未算
        var blur: FaceBlurScore?  // nil=未算
    }
    private struct Store: Codable { let version: Int; var entries: [String: Entry] }
    private static let version = 1

    private static var url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FrameScoop", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("photo-analysis.json")
    }()

    // 旧版仅存 dHash 的文件；新版首次读不到 photo-analysis.json 时回退读它，
    // 旧条目（无 blur 字段）按 blur=nil 解码，保留已算好的 dHash，避免重算。
    private static var legacyURL: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FrameScoop", isDirectory: true)
            .appendingPathComponent("burst-hashes.json")
    }()

    /// 读全部条目：photoID -> (mtime, dHash?, blur?)。读失败返回空（按未命中处理，重算）。
    static func load() -> [String: (mtime: Double, dHash: UInt64?, blur: FaceBlurScore?)] {
        let useURL = FileManager.default.fileExists(atPath: url.path) ? url : legacyURL
        guard let data = try? Data(contentsOf: useURL),
              let store = try? JSONDecoder().decode(Store.self, from: data) else { return [:] }
        var out: [String: (mtime: Double, dHash: UInt64?, blur: FaceBlurScore?)] = [:]
        out.reserveCapacity(store.entries.count)
        for (id, e) in store.entries {
            let dh = e.dHash.flatMap { UInt64($0, radix: 16) }
            out[id] = (e.mtime, dh, e.blur)
        }
        return out
    }

    /// 整表写入（始终写新文件名 photo-analysis.json；调用方负责合并好）。
    static func save(_ entries: [String: (mtime: Double, dHash: UInt64?, blur: FaceBlurScore?)]) {
        var enc: [String: Entry] = [:]
        enc.reserveCapacity(entries.count)
        for (id, v) in entries {
            enc[id] = Entry(mtime: v.mtime,
                            dHash: v.dHash.map { String($0, radix: 16) },
                            blur: v.blur)
        }
        let store = Store(version: version, entries: enc)
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
