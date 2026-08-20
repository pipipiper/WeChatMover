import SwiftUI

/// 支持的目标 App 档案：微信 / 企业微信。
/// 两者迁移原理一致（容器子目录 → 外置盘 + 软链 + 重签名），差异全部收敛在这里。
enum AppProfile: String, CaseIterable, Identifiable {
    case wechat
    case wework

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .wechat: return "微信"
        case .wework: return "企业微信"
        }
    }

    var bundleID: String {
        switch self {
        case .wechat: return "com.tencent.xinWeChat"
        case .wework: return "com.tencent.WeWorkMac"
        }
    }

    var appPath: String {
        switch self {
        case .wechat: return "/Applications/WeChat.app"
        case .wework: return "/Applications/企业微信.app"
        }
    }

    var appURL: URL { URL(fileURLWithPath: appPath) }

    /// 容器内 Data 根目录（基于当前用户 home，不写死用户名）。
    var containerRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(bundleID)/Data", isDirectory: true)
    }

    /// 候选迁移目录 key：在候选间唯一，兼作外置盘文件夹名（取末级）、展示键、清单键。
    /// key → 实际源路径的映射见 sourceDirectory(key:containerRoot:)。
    var candidateSubdirs: [String] {
        switch self {
        case .wechat:
            return [
                "Documents/xwechat_files",                          // 4.x 主力数据
                "Documents/app_data",
                "Library/Application Support/com.tencent.xinWeChat", // 3.x 兼容
            ]
        case .wework:
            return [
                "Documents",        // 聊天记录与文件
                "WeDrive",          // 微盘同步文件
                "WXWork-Data",      // 容器外 ~/Library/Application Support/WXWork/Data
            ]
        }
    }

    /// 候选 key → 实际源目录。
    /// 微信全部是容器相对路径；企业微信的 Documents/WeDrive 也是容器相对
    /// （实测：整搬容器 Data 会被系统拒绝——Data 本体有 MACL 保护，
    /// 但其子目录改名/建软链都正常，所以按子目录迁移）。
    /// WXWork-Data 在容器外，是唯一的特例。
    func sourceDirectory(key: String, containerRoot: URL) -> URL {
        switch (self, key) {
        case (.wework, "WXWork-Data"):
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/WXWork/Data", isDirectory: true)
        default:
            return containerRoot.appendingPathComponent(key, isDirectory: true)
        }
    }

    /// 官网下载页（App Store 版拦截引导用）。
    var downloadURL: URL {
        switch self {
        case .wechat: return URL(string: "https://weixin.qq.com/")!
        case .wework: return URL(string: "https://work.weixin.qq.com/#indexDownload")!
        }
    }

    /// 主题色（微信绿 / 企业微信蓝），深浅色双值。
    var accent: Color {
        switch self {
        case .wechat: return .dynamic(light: 0x07C160, dark: 0x20CD71)
        case .wework: return .dynamic(light: 0x0082EF, dark: 0x3B9CFF)
        }
    }

    /// 持久化键（微信沿用旧键名保证兼容旧版本数据，企业微信加后缀）。
    var targetBaseDefaultsKey: String {
        switch self {
        case .wechat: return DefaultsKey.targetBasePath
        case .wework: return DefaultsKey.targetBasePath + ".wework"
        }
    }

    var lastSignedVersionDefaultsKey: String {
        switch self {
        case .wechat: return DefaultsKey.lastSignedVersion
        case .wework: return DefaultsKey.lastSignedVersion + ".wework"
        }
    }
}

/// 主题色全局状态：跟随当前档案（微信绿 / 企业微信蓝）。
/// 由 AppViewModel.switchProfile 在更新 profile 之前赋值（时序关键：profile 的
/// @Published 发布会立即触发重渲染，Theme 必须先就绪，否则图标"时而对时而错"）。
/// 仅 UI 色值、主线程读写，故用 nonisolated(unsafe) 豁免并发检查。
enum Theme {
    nonisolated(unsafe) static var accent: Color = AppProfile.wechat.accent
}
