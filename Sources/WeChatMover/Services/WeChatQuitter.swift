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

    /// 完整流程：优雅退出 → 等 graceTimeout → 仍运行则强杀 → 再等 forceTimeout。
    /// 依赖全部可注入，单测用假 closure 验证流程分支，不触碰真实 App。
    /// 注意：isRunning 默认必须跟随 bundleID（曾默认查微信，导致杀企业微信时误报失败）。
    static func ensureQuit(
        bundleID: String = WeChatDetector.bundleID,
        graceTimeout: TimeInterval = 5,
        forceTimeout: TimeInterval = 3,
        isRunning: (() -> Bool)? = nil,
        graceful: (() -> Void)? = nil,
        force: (() -> Void)? = nil
    ) async -> Bool {
        let isRunning = isRunning ?? { WeChatDetector.isRunning(bundleID: bundleID) }
        let graceful = graceful ?? { requestGracefulQuit(bundleID: bundleID) }
        let force = force ?? { forceKill(bundleID: bundleID) }
        guard isRunning() else { return true }
        graceful()
        if await waitForExit(timeout: graceTimeout, isRunning: isRunning) { return true }
        force()
        return await waitForExit(timeout: forceTimeout, isRunning: isRunning)
    }
}
