import Foundation
import AppKit

struct WeChatInfo {
    var isInstalled: Bool = false
    var version: String? = nil
    var isAppStoreVersion: Bool = false
    var isRunning: Bool = false
    var signature: WeChatDetector.SignatureStatus? = nil
}

/// 微信本体探测：是否安装、版本、是否 App Store 版、是否运行中、签名状态。
enum WeChatDetector {
    static let defaultAppURL = URL(fileURLWithPath: "/Applications/WeChat.app")
    static let bundleID = "com.tencent.xinWeChat"
    static let officialDownloadURL = URL(string: "https://weixin.qq.com/")!

    /// 是否为 App Store 版：存在 Contents/_MASReceipt/receipt 即视为 MAS 版。
    static func isAppStoreVersion(appURL: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: appURL.appendingPathComponent("Contents/_MASReceipt/receipt").path
        )
    }

    static func version(appURL: URL) -> String? {
        let plist = appURL.appendingPathComponent("Contents/Info.plist")
        guard let dict = NSDictionary(contentsOf: plist) else { return nil }
        return dict["CFBundleShortVersionString"] as? String
    }

    /// 目标 App 是否正在运行（NSRunningApplication 查询，毫秒级，任意线程可调）。
    /// 过滤 isTerminated：终止流程中的实例可能在列表里短暂残留，不算运行中。
    static func isRunning(bundleID: String = WeChatDetector.bundleID) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { !$0.isTerminated }
    }

    static func detect(
        appURL: URL = WeChatDetector.defaultAppURL,
        bundleID: String = WeChatDetector.bundleID
    ) -> WeChatInfo {
        let installed = FileManager.default.fileExists(atPath: appURL.path)
        var info = WeChatInfo()
        info.isInstalled = installed
        if installed {
            info.version = version(appURL: appURL)
            info.isAppStoreVersion = isAppStoreVersion(appURL: appURL)
        }
        info.isRunning = isRunning(bundleID: bundleID)
        return info
    }

    /// 只读校验签名是否有效（codesign --verify，不写）。
    static func checkSignature(appURL: URL = WeChatDetector.defaultAppURL) -> Bool {        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--deep", "--strict", appURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// 签名状态。对「数据软链到外置盘」的场景，只有 ad-hoc 才是可用态：
    /// 微信更新会恢复官方签名，校验依然通过（旧检测因此误判"签名有效"），
    /// 但官方签名 + 软链数据会导致微信无法打开，必须重新 ad-hoc 签名。
    enum SignatureStatus: Equatable, Sendable {
        case adhoc          // ad-hoc 签名（本工具重签后的可用状态）
        case validOfficial  // 校验通过但非 ad-hoc（微信更新恢复的官方签名，需重新签名）
        case broken         // 封条破损，codesign --verify 失败
    }

    /// 综合检测：先 codesign --verify 验封条，再 codesign -dv 判是否 ad-hoc。
    static func signatureStatus(appURL: URL = WeChatDetector.defaultAppURL) -> SignatureStatus {
        guard checkSignature(appURL: appURL) else { return .broken }
        return isAdhocDescribeOutput(describeOutput(appURL: appURL)) ? .adhoc : .validOfficial
    }

    /// codesign -dv 输出（在 stderr）。
    static func describeOutput(appURL: URL = WeChatDetector.defaultAppURL) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-dv", appURL.path]
        process.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        process.standardError = errPipe
        do {
            try process.run()
            // 先读管道（阻塞至 EOF）再等退出，避免输出填满管道缓冲导致假死。
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    /// 解析 codesign -dv 输出判断是否为 ad-hoc 签名（纯函数，可单测）。
    static func isAdhocDescribeOutput(_ output: String) -> Bool {
        output.contains("Signature=adhoc") || output.contains("flags=0x2(adhoc)")
    }
}
