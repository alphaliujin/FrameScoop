//
//  ShellExecutor.swift
//  FrameScoop
//
//  安全的命令行执行封装。
//
//  设计目标：
//  1. 所有 Process 调用都做异常捕获，任何失败都返回结构化结果，绝不抛出导致崩溃。
//  2. 支持超时：子进程超时自动终止，防止挂起主流程。
//  3. 仅使用系统自带命令（/usr/bin/mdls 等），不引入任何第三方 SDK。
//

import Foundation

/// 一次命令执行的返回结果
struct ShellResult {
    let stdout: String
    let stderr: String
    let terminationStatus: Int32
    let didTimeOut: Bool

    /// 是否成功（正常退出且非超时）
    var isSuccess: Bool { !didTimeOut && terminationStatus == 0 }
}

/// 命令行执行器：单例，线程安全（无实例可变状态，run 每次创建独立 Process）。
final class ShellExecutor: Sendable {

    static let shared = ShellExecutor()
    private init() {}

    /// 执行一个可执行文件并返回结果。
    /// - Parameters:
    ///   - executablePath: 可执行文件绝对路径（如 "/usr/bin/mdls"）
    ///   - arguments: 参数列表
    ///   - environment: 自定义环境变量（默认继承当前进程）
    ///   - timeout: 超时秒数，超时后会向子进程发送 terminate
    /// - Returns: 结构化执行结果（永不抛出）
    func run(_ executablePath: String,
             arguments: [String] = [],
             environment: [String: String]? = nil,
             timeout: TimeInterval = 10) -> ShellResult {

        let process = Process()

        // 校验可执行文件存在，避免 “No such file” 导致崩溃
        let execURL = URL(fileURLWithPath: executablePath)
        guard FileManager.default.isExecutableFile(atPath: execURL.path) else {
            return ShellResult(stdout: "",
                               stderr: "可执行文件不存在或不可执行: \(executablePath)",
                               terminationStatus: -1,
                               didTimeOut: false)
        }
        process.executableURL = execURL
        process.arguments = arguments
        if let environment { process.environment = environment }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // 1. 启动子进程 -- 此处是少数会抛错的位置，做捕获
        do {
            try process.run()
        } catch {
            return ShellResult(stdout: "",
                               stderr: "启动进程失败: \(error.localizedDescription)",
                               terminationStatus: -1,
                               didTimeOut: false)
        }

        // 2. 超时看门狗：到点若仍在运行则 terminate
        var timedOut = false
        let watchdog = DispatchWorkItem { [weak process] in
            guard let process, process.isRunning else { return }
            timedOut = true
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        // 3. 并发收集两端管道数据并等待退出。
        //    子进程输出若超过管道缓冲（约 64KB）会写阻塞：若先 waitUntilExit 再
        //    readDataToEndOfFile 会死锁（子进程被写阻塞无法退出，本线程又在等退出不读管道）。
        //    用 readabilityHandler 事件驱动收集：有数据就追加，EOF（availableData 为空）即收尾。
        let stdoutCollector = PipeCollector()
        let stderrCollector = PipeCollector()
        outPipe.fileHandleForReading.readabilityHandler = stdoutCollector.handler
        errPipe.fileHandleForReading.readabilityHandler = stderrCollector.handler

        process.waitUntilExit()
        watchdog.cancel()

        // waitUntilExit 返回后子进程已关闭管道，readabilityHandler 会收到 EOF；
        // 等待两端都读到 EOF 再转字符串，确保数据完整。
        let stdout = String(data: stdoutCollector.wait(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrCollector.wait(), encoding: .utf8) ?? ""

        return ShellResult(stdout: stdout,
                           stderr: stderr,
                           terminationStatus: process.terminationStatus,
                           didTimeOut: timedOut)
    }
}

/// 管道数据事件驱动收集器：作为 FileHandle.readabilityHandler 使用。
/// 回调中追加数据，读到 EOF（availableData 为空）时信号通知。
/// readabilityHandler 由 FileHandle 在其内部串行队列上调用，故追加与 signal 同队列串行，
/// semaphore.wait() 与 signal 构成 happens-before，wait 返回后读取 data 安全。
private final class PipeCollector {
    private var data = Data()
    private let done = DispatchSemaphore(value: 0)

    var handler: (FileHandle) -> Void {
        { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                self?.done.signal()
            } else {
                self?.data.append(chunk)
            }
        }
    }

    /// 阻塞至读到 EOF，返回全部收集的数据
    func wait() -> Data {
        done.wait()
        return data
    }
}
