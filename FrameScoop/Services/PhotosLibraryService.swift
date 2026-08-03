//
//  PhotosLibraryService.swift
//  FrameScoop
//
//  通过 Photos.framework 读取系统照片库（含 iCloud 同步照片）。
//
//  职责：
//  - 鉴权：PHPhotoLibrary.requestAuthorization(for: .readWrite)（readWrite 以支持移到废纸篓）
//  - 枚举：PHAsset 全量图片资源 -> PhotoItem（sourceKind = .photoLibrary）
//  - 取图：PHImageManager.requestImage（缩略图/全尺寸；iCloud 未下载项按需联网）
//  - 元数据：PHAsset 属性（像素、拍摄时间）
//  - 删除 / 导出：PHAssetChangeRequest / PHAssetResourceManager
//
//  与文件夹源（PhotoLoadService）并立，由 PhotoLoader 按 PhotoItem.sourceKind 分派。
//

import Foundation
import Photos
import ImageIO
import AppKit

/// 对 PHAuthorizationStatus 的封装，便于 UI 判断
enum PhotosAuthStatus {
    case notDetermined, authorized, denied, restricted
}

final class PhotosLibraryService {

    static let shared = PhotosLibraryService()

    /// 照片库源在侧边栏的固定节点 id（与文件夹节点 id 不会冲突）
    static let sidebarNodeID = "frameScoop.photosLibrary"

    private init() {}

    // MARK: - 鉴权

    var status: PhotosAuthStatus {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized:      return .authorized
        case .denied:          return .denied
        case .restricted:      return .restricted
        default:               return .notDetermined
        }
    }

    /// 请求相册访问（已授权/拒绝时幂等，不重复弹窗）。
    @discardableResult
    func requestAuthorization() async -> PhotosAuthStatus {
        let s = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        switch s {
        case .authorized: return .authorized
        case .denied:     return .denied
        case .restricted: return .restricted
        default:          return .notDetermined
        }
    }

    // MARK: - 枚举

    /// 枚举照片库全部图片资产，转为 PhotoItem（未排序，由上层排序）。
    func loadAllPhotos() async -> [PhotoItem] {
        guard status == .authorized else { return [] }
        let result = PHAsset.fetchAssets(with: .image, options: nil)
        var items: [PhotoItem] = []
        items.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            items.append(self.makeItem(from: asset))
        }
        return items
    }

    private func makeItem(from asset: PHAsset) -> PhotoItem {
        // PHAsset 未公开 filename，用 KVC 取（常见用法）；失败回退到 localIdentifier
        let name = (asset.value(forKey: "filename") as? String) ?? asset.localIdentifier
        return PhotoItem(
            assetIdentifier: asset.localIdentifier,
            name: name,
            creationDate: asset.creationDate,
            modificationDate: asset.modificationDate,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight
        )
    }

    // MARK: - 取图

    /// 请求图片，maxPixel 控制最长边像素上限。iCloud 未下载项按需联网下载。
    /// 用 deliveryMode=.highQualityFormat 取单次高质量回调，避免 opportunistic 的 degraded
    /// 多回调导致 CheckedContinuation 重复 resume；仍加锁防极端多次回调。
    func image(for localIdentifier: String, maxPixel: Int) async -> NSImage? {
        guard let asset = fetchAsset(localIdentifier) else { return nil }
        let opts = PHImageRequestOptions()
        opts.isNetworkAccessAllowed = true
        opts.deliveryMode = .highQualityFormat
        opts.resizeMode = .fast
        let target = targetSize(for: asset, maxPixel: maxPixel)
        return await withCheckedContinuation { (cont: CheckedContinuation<NSImage?, Never>) in
            var resumed = false
            let lock = NSLock()
            let safeResume: (NSImage?) -> Void = { img in
                lock.lock(); defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: img)
            }
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: target,
                contentMode: .aspectFit,
                options: opts
            ) { image, _ in
                safeResume(image)
            }
        }
    }

    private func targetSize(for asset: PHAsset, maxPixel: Int) -> CGSize {
        let w = CGFloat(asset.pixelWidth > 0 ? asset.pixelWidth : maxPixel)
        let h = CGFloat(asset.pixelHeight > 0 ? asset.pixelHeight : maxPixel)
        let scale = min(CGFloat(maxPixel) / w, CGFloat(maxPixel) / h, 1)
        return CGSize(width: max(1, (w * scale).rounded()),
                      height: max(1, (h * scale).rounded()))
    }

    private func fetchAsset(_ id: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
    }

    private func fetchAssets(_ ids: [String]) -> [PHAsset] {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var arr: [PHAsset] = []
        arr.reserveCapacity(result.count)
        result.enumerateObjects { a, _, _ in arr.append(a) }
        return arr
    }

    // MARK: - 元数据

    /// 从 PHAsset 属性取基础元数据（像素、拍摄时间）。
    /// EXIF/设备信息需异步加载图片数据解析，MVP 暂不取（面板会自动隐藏无值行）。
    func metadata(for localIdentifier: String) -> ImageMetadata {
        guard let asset = fetchAsset(localIdentifier) else { return .empty }
        var meta = ImageMetadata()
        if asset.pixelWidth > 0  { meta.pixelWidth = asset.pixelWidth }
        if asset.pixelHeight > 0 { meta.pixelHeight = asset.pixelHeight }
        if let date = asset.creationDate {
            meta.takenDate = DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .medium)
        }
        return meta
    }

    // MARK: - 删除 / 导出

    /// 删除资产到 Photos「最近删除」（performChanges 内执行，异步）。
    @discardableResult
    func deleteAssets(localIdentifiers: [String]) async -> Bool {
        let assets = fetchAssets(localIdentifiers)
        guard !assets.isEmpty else { return false }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets as NSFastEnumeration)
            } completionHandler: { success, _ in
                cont.resume(returning: success)
            }
        }
    }

    /// 导出资产原始数据到指定路径（iCloud 项按需联网）。返回是否成功。
    @discardableResult
    func exportAsset(localIdentifier: String, to dest: URL) async -> Bool {
        guard let asset = fetchAsset(localIdentifier) else { return false }
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .photo || $0.type == .fullSizePhoto })
            ?? resources.first else { return false }
        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = true
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            // Photos 可能分多次回调 dataReceivedHandler，累积完整数据后于 completion 落盘
            var collected = Data()
            PHAssetResourceManager.default().requestData(
                for: resource,
                options: opts,
                dataReceivedHandler: { data in collected.append(data) },
                completionHandler: { error in
                    if error != nil { cont.resume(returning: false); return }
                    cont.resume(returning: (try? collected.write(to: dest, options: .atomic)) != nil)
                }
            )
        }
    }
}
