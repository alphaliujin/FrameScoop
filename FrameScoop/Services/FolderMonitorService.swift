//
//  FolderMonitorService.swift
//  FrameScoop
//
//  文件夹监控服务（递归）。
//  使用 FSEvents 监控整个目录树：根目录及任意层级子目录的增删改都会触发回调。
//  变化后做防抖回调，使图片库自动刷新。纯系统 API，无需轮询。
//
//  为何不用 DispatchSource：DispatchSource 监控目录 fd 只报告该目录「直接子项」的
//  变化，不递归到子目录；而本应用的加载是「含所有下级目录」的，子目录内新增/删除
//  图片不会触发刷新。FSEvents 原生支持递归监控，正适合此场景。
//

import Foundation
import CoreServices

final class FolderMonitorService {

    /// 文件系统事件回调（已防抖），调用方应在主线程更新 UI
    var onChange: (() -> Void)?

    private var stream: FSEventStreamRef?
    private var debounceWork: DispatchWorkItem?
    /// FSEvents 回调派发的队列（事件在此队列上回调，再跳主线程防抖）
    private let monitorQueue = DispatchQueue(label: "FrameScoop.folderMonitor", qos: .utility)

    deinit {
        stop()
    }

    /// 开始监控指定文件夹（递归含所有下级目录）。
    /// - Parameter url: 已激活安全作用域的文件夹 URL
    func startMonitoring(url: URL) {
        stop()

        // 通过 context.info 把 self 传给 C 回调（@convention(c) 闭包不能捕获上下文）。
        // Unmanaged unretained：context 不持留 self（避免 self->stream->self 循环引用）；
        // 回调内对 self 做跨 main 异步的 retain/release（见下方），防止 stop()/deinit
        // 与在途 main 块之间的悬空解引用。
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            // 跨 main 异步持有 self：info 是 unretained 裸指针，若 stop()/deinit 在本回调
            //（monitorQueue）与下方 main 块之间执行，takeUnretainedValue 会解引用已释放内存
            //（use-after-free）。这里 retain 一次、main 块末尾 release，保证 main 块执行期间对象存活。
            //（callback 触发时 stream 仍存活，而 stream 由 self 持有，故 self 此时必然存活，retain 安全。）
            let instance = Unmanaged<FolderMonitorService>.fromOpaque(info).retain().takeUnretainedValue()
            DispatchQueue.main.async {
                // 派发到主线程执行防抖：与 stop()（主线程）串行访问 debounceWork，
                // 消除回调队列与主线程并发修改的数据竞争。
                instance.scheduleDebouncedCallback()
                // 释放回调中的 retain：若此时已是最后持有，对象在此之后才析构
                Unmanaged.passUnretained(instance).release()
            }
        }

        // kFSEventStreamCreateFlagWatchRoot：根目录本身被移动/重命名时也回调。
        // 不加 kFSEventStreamCreateFlagFileEvents：只需「目录树有变化即刷新整个文件夹」，
        // 目录级事件更稀疏；latency 合并窗口内的事件，再叠加主线程 0.5s 防抖。
        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            UInt32(kFSEventStreamCreateFlagWatchRoot)
        )

        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, monitorQueue)
        guard FSEventStreamStart(stream) else {
            // 启动失败（极罕见）：释放已创建的 stream，保持无监控状态
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            return
        }
    }

    /// 停止监控并释放资源
    func stop() {
        if let stream {
            // 标准清理顺序：stop 停止新事件 -> invalidate 断开队列 -> release 释放引用
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
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
