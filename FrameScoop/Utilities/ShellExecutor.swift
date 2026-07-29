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

/// 命令行执行器：单例，线程安全。
final class ShellExecutor {

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

        // 3. 阻塞等待退出（在后台线程更合适，但此处由调用方负责异步调度）
        process.waitUntilExit()
        watchdog.cancel()

        let stdout = readPipe(outPipe)
        let stderr = readPipe(errPipe)

        return ShellResult(stdout: stdout,
                           stderr: stderr,
                           terminationStatus: process.terminationStatus,
                           didTimeOut: timedOut)
    }

    /// 安全读取管道数据为 UTF-8 字符串
    private func readPipe(_ pipe: Pipe) -> String {
        // 注意：在子进程已终止后读取，避免死锁
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
