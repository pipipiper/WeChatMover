import Foundation

/// 微信容器内外的所有路径模型。
enum WeChatPaths {
    /// 微信（官网 DMG 版）容器内的 Data 根目录。
    static let defaultContainerRoot: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data")

    /// 需要迁移的候选子目录（相对容器 Data 根，若存在且非软链则迁移）。
    static let candidateSubdirs: [String] = [
        "Documents/xwechat_files",                                  // 4.x 主力数据
        "Documents/app_data",
        "Library/Application Support/com.tencent.xinWeChat",        // 3.x 兼容
    ]

    /// 用户选择的目标文件夹下的数据根目录：<base>/WeChatData
    static func targetRoot(forBase base: URL) -> URL {
        base.appendingPathComponent("WeChatData", isDirectory: true)
    }

    /// 某个候选子目录在外置盘上的目标位置：<base>/WeChatData/<子目录末级名>
    static func targetDirectory(base: URL, subdir: String) -> URL {
        targetRoot(forBase: base).appendingPathComponent((subdir as NSString).lastPathComponent, isDirectory: true)
    }

    /// 候选子目录在容器内的源位置；以 "/" 开头视为绝对路径原样使用
    /// （企业微信 Profiles 在真实 ~/Documents，不在容器里）。
    static func sourceDirectory(containerRoot: URL, subdir: String) -> URL {
        if subdir.hasPrefix("/") { return URL(fileURLWithPath: subdir, isDirectory: true) }
        return containerRoot.appendingPathComponent(subdir, isDirectory: true)
    }

    /// 迁移后保留的本地备份位置：源目录同级、原名加 "_backup" 后缀
    /// （如 xwechat_files → xwechat_files_backup）。
    static func backupDirectory(for source: URL) -> URL {
        source.deletingLastPathComponent()
            .appendingPathComponent(source.lastPathComponent + "_backup", isDirectory: true)
    }
}
