import Foundation
import AppKit

/// 退出目标 App：优先优雅退出（AppleScript quit），等几秒仍未退出再强制结束。
/// 强杀的是自己用户的进程，不需要管理员权限。
enum WeChatQuitter {
    /// 优雅退出：AppleScript `tell application id <bundleID> to quit`
    /// （用 bundle id 定位，比按名称更可靠，微信/企业微信通用）。
    /// 可能触发「自动化」权限弹窗，调用方负责在此之前激活本 App。
    static func requestGracefulQuit(bundleID: String = WeChatDetector.bundleID) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "tell application id \"\(bundleID)\" to quit"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    /// 强制结束当前用户的全部目标进程（kill，无需提权）。
    static func forceKill(bundleID: String = WeChatDetector.bundleID) {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            app.forceTerminate()
        }
    }

    /// 轮询等待目标 App 退出，最多 timeout 秒；返回是否已退出。
    static func waitForExit(
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.3,
        isRunning: () -> Bool = { WeChatDetector.isRunning() }
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isRunning() { return true }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        return !isRunning()
    }

    /// 完整流程：优雅退出 → 等 graceTimeout → 仍运行则强杀 → 再等 forceTimeout → 沉降确认。
    /// 依赖全部可注入，单测用假 closure 验证流程分支，不触碰真实 App。
    /// 注意：isRunning 默认必须跟随 bundleID（曾默认查微信，导致杀企业微信时误报失败）。
    /// 超时给得宽：实测企业微信优雅退出需 5s+（写状态落盘，外置硬盘更慢），
    /// 超时过短会在「App 其实正在正常退出」时误报失败。
    static func ensureQuit(
        bundleID: String = WeChatDetector.bundleID,
        graceTimeout: TimeInterval = 12,
        forceTimeout: TimeInterval = 8,
        settleDuration: TimeInterval = 1.5,
        settleTimeout: TimeInterval = 15,
        isRunning: (() -> Bool)? = nil,
        graceful: (() -> Void)? = nil,
        force: (() -> Void)? = nil
    ) async -> Bool {
        let isRunning = isRunning ?? { WeChatDetector.isRunning(bundleID: bundleID) }
        let graceful = graceful ?? { requestGracefulQuit(bundleID: bundleID) }
        let force = force ?? { forceKill(bundleID: bundleID) }
        guard isRunning() else { return true }
        graceful()
        var exited = await waitForExit(timeout: graceTimeout, isRunning: isRunning)
        if !exited {
            force()
            exited = await waitForExit(timeout: forceTimeout, isRunning: isRunning)
        }
        guard exited else { return false }
        // 沉降：App 刚退出时 NSRunningApplication 会抖动（已空 → 闪现 → 再空），
        // 且容器/数据文件句柄可能未释放完——此时立刻迁移会被系统拒成「没有权限」
        //（实测企微：退出"成功"后立刻改名容器 Data 报 513）。连续稳定未运行才算退干净。
        return await waitUntilSettled(
            isRunning: isRunning, sustained: settleDuration, timeout: settleTimeout)
    }

    /// 连续 sustained 秒都未运行才返回 true（期间抖动回运行则重新计时）；最多等 timeout 秒。
    static func waitUntilSettled(
        isRunning: () -> Bool,
        sustained: TimeInterval,
        timeout: TimeInterval
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var clearSince: Date?
        while Date() < deadline {
            if isRunning() {
                clearSince = nil
            } else {
                if clearSince == nil { clearSince = Date() }
                if let since = clearSince, Date().timeIntervalSince(since) >= sustained {
                    return true
                }
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return false
    }
}
