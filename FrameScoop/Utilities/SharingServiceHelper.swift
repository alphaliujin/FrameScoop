//
//  SharingServiceHelper.swift
//  FrameScoop
//
//  NSSharingService 调用辅助：为分享服务（邮件 / 微信等）提供锚点窗口并执行。
//  用于「发送」菜单中的「作为邮件附件发送」「通过微信发送」。
//

import AppKit

final class SharingServiceHelper: NSObject, NSSharingServiceDelegate {

    static let shared = SharingServiceHelper()
    private override init() { super.init() }

    /// 执行某个分享服务。
    /// - Parameters:
    ///   - service: 已创建的 NSSharingService（如 .composeEmail、微信服务）
    ///   - items: 要分享的内容（文件 URL 等）
    func perform(_ service: NSSharingService, items: [Any]) {
        service.delegate = self
        service.perform(withItems: items)
    }

    // MARK: - NSSharingServiceDelegate

    /// 为分享 UI 提供父窗口（锚点）
    func sharingService(
        _ sharingService: NSSharingService,
        sourceWindowForShareItems sharingItems: [Any],
        sharingContentScope: UnsafeMutablePointer<NSSharingService.SharingContentScope>
    ) -> NSWindow? {
        sharingContentScope.pointee = .full
        return NSApp.keyWindow
    }
}
