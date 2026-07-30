//
//  FolderMonitorService.swift
//  FrameScoop
//
//  文件夹监控服务。
//  使用 DispatchSource 监听文件系统事件（新增/删除/修改），
//  变化后做防抖回调，使图片库自动刷新。纯系统 API，无需轮询。
//

import Foundation

final class FolderMonitorService {

    /// 文件系统事件回调（已防抖），调用方应在主线程更新 UI
    var onChange: (() -> Void)?

    private var fileDescriptor: CInt = -1
    private var source: DispatchSourceFileSystemObject?
    private var debounceWork: DispatchWorkItem?

    deinit {
        stop()
    }

    /// 开始监控指定文件夹
    /// - Parameter url: 已激活安全作用域的文件夹 URL
    func startMonitoring(url: URL) {
        stop()

        // O_EVTONLY：仅以监听方式打开，不实际读写，权限最小化
        fileDescriptor = open(url.path, O_EVTONLY)
        guard fileDescriptor != -1 else {
            #if DEBUG
            print("[FolderMonitor] open 失败: \(String(cString: strerror(errno)))")
            #endif
            return
        }

        let queue = DispatchQueue(label: "FrameScoop.folderMonitor", qos: .utility)
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .delete, .rename, .extend],
            queue: queue
        )

        // 事件处理器：收到事件后防抖 0.5s 再回调，避免短时间多次刷新。
        // 派发到主线程执行 scheduleDebouncedCallback：与 stop()（也在主线程）串行访问
        // debounceWork，消除后台队列与主线程并发修改的数据竞争。
        source?.setEventHandler { [weak self] in
            DispatchQueue.main.async {
                self?.scheduleDebouncedCallback()
            }
        }
        // 不在 cancelHandler 里 close(fd)：stop() 会同步 cancel 并 close，
        // 否则 cancelHandler 异步执行会造成同一 fd 被关闭两次（double close）。
        source?.resume()
    }

    /// 停止监控并释放资源
    func stop() {
        source?.cancel()
        source = nil
        if fileDescriptor != -1 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
        debounceWork?.cancel()
        debounceWork = nil
    }

    private func scheduleDebouncedCallback() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.onChange?()
        }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}
