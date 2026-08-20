import Foundation

/// 微信容器内外的所有路径模型。
enum WeChatPaths {
    /// 微信（官网 DMG 版）容器内的 Data 根目录。
    static let defaultContainerRoot: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data")

    /// 用户选择的目标文件夹下的数据根目录：<base>/WeChatData
    static func targetRoot(forBase base: URL) -> URL {
        base.appendingPathComponent("WeChatData", isDirectory: true)
    }

    /// 某个候选目录在外置盘上的目标位置：<base>/WeChatData/<key 末级名>
    static func targetDirectory(base: URL, subdir: String) -> URL {
        targetRoot(forBase: base).appendingPathComponent((subdir as NSString).lastPathComponent, isDirectory: true)
    }

    /// 迁移后保留的本地备份位置：源目录同级、原名加 "_backup" 后缀
    /// （如 xwechat_files → xwechat_files_backup）。
    static func backupDirectory(for source: URL) -> URL {
        source.deletingLastPathComponent()
            .appendingPathComponent(source.lastPathComponent + "_backup", isDirectory: true)
    }
}
