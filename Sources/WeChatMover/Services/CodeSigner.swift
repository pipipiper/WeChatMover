import Foundation

/// codesign 封装：进程内直接执行 /usr/bin/codesign（不走 osascript、不提权）。
/// 微信是拖拽安装、/Applications/WeChat.app 所有者为当前用户，重签名不需要 root；
/// 直接执行还能让 TCC「App 管理」权限归责到 WeChatMover 自身，用户授权一次即可
/// （经 osascript 提权会归责到 security_authtrampoline 等系统中间进程，授权无效）。
/// 异步等待进程真正退出，不阻塞主线程。
enum CodeSigner {
    static let wechatAppPath = "/Applications/WeChat.app"

    /// 重签名结果：成功 / App 管理权限缺失（TCC EPERM）/ 一般失败。
    enum ResignResult: Equatable, Sendable {
        case success
        case appManagementDenied(String)
        case failed(String)
    }

    /// 进程内直接执行的 codesign 参数。
    static func codesignArguments(appPath: String = wechatAppPath) -> [String] {
        ["--sign", "-", "--force", "--deep", appPath]
    }

    /// 兜底方案：包当前用户不可写时在终端里执行的命令（终端通常已有「App 管理」权限）。
    static func shellCommand(appPath: String = wechatAppPath) -> String {
        "codesign --sign - --force --deep \(appPath)"
    }

    static func terminalCommand(appPath: String = wechatAppPath) -> String {
        "sudo \(shellCommand(appPath: appPath))"
    }

    /// /Applications/WeChat.app 当前用户是否可写（不可写时需终端 sudo 兜底）。
    static func isWritableByCurrentUser(appPath: String = wechatAppPath) -> Bool {
        FileManager.default.isWritableFile(atPath: appPath)
    }

    /// 由退出码 + stderr 判定结果（纯逻辑，可单测）。
    /// stderr 含 Operation not permitted 是 macOS Ventura+ 的 TCC「App 管理」
    /// 权限拒绝修改其他 App 的包，单独分类以便弹授权指引。
    static func parseResult(status: Int32, stderr: String) -> ResignResult {
        if status == 0 { return .success }
        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if stderr.contains("Operation not permitted") {
            return .appManagementDenied(detail.isEmpty ? "退出码 \(status)" : detail)
        }
        return .failed(detail.isEmpty ? "退出码 \(status)" : detail)
    }

    /// 异步启动进程并等待真正退出：
    /// - terminationHandler 回调，绝不阻塞调用线程；
    /// - stderr 用 readabilityHandler 持续排空，避免输出填满管道缓冲导致假死；
    /// - 进程退出后再读管道尾部，保证 stderr 完整。
    static func run(
        executableURL: URL,
        arguments: [String],
        completion: @escaping @Sendable (ResignResult) -> Void
    ) {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice

        // readabilityHandler 与 terminationHandler 可能跑在不同线程，串行队列保护缓冲。
        final class Buffer: @unchecked Sendable { var data = Data() }
        let buffer = Buffer()
        let queue = DispatchQueue(label: "WeChatMover.CodeSigner.stderr")
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            queue.sync { buffer.data.append(chunk) }
        }
        process.terminationHandler = { proc in
            errPipe.fileHandleForReading.readabilityHandler = nil
            let tail = errPipe.fileHandleForReading.readDataToEndOfFile()
            queue.sync { buffer.data.append(tail) }
            let stderr = String(data: buffer.data, encoding: .utf8) ?? ""
            completion(parseResult(status: proc.terminationStatus, stderr: stderr))
        }
        do {
            try process.run()
        } catch {
            errPipe.fileHandleForReading.readabilityHandler = nil
            completion(.failed("无法启动 codesign：\(error.localizedDescription)"))
        }
    }

    /// 对目标 App 执行 ad-hoc 重签名（异步，completion 在后台线程回调）。
    /// 不提权、不弹密码框；首次可能触发 TCC「App 管理」授权提示。
    static func resignWeChat(
        appPath: String = wechatAppPath,
        completion: @escaping @Sendable (ResignResult) -> Void
    ) {
        run(
            executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: codesignArguments(appPath: appPath),
            completion: completion
        )
    }
}
