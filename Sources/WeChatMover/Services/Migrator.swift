import Foundation

enum MigrationError: Error, LocalizedError {
    case sourceMissing(String)
    case sourceIsSymlink(String)
    case targetAlreadyExists(String)
    case backupAlreadyExists(String)
    case backupMissing(String)
    case unsafeToDeleteBackup(String)
    case notMigrated(String)
    case verifyFailed(String)
    case insufficientSpace(need: Int64, free: Int64)

    var errorDescription: String? {
        switch self {
        case .sourceMissing(let p): return "源目录不存在：\(p)"
        case .sourceIsSymlink(let p): return "源位置已是符号链接，无需迁移：\(p)"
        case .targetAlreadyExists(let p): return "目标位置已存在数据：\(p)"
        case .backupAlreadyExists(let p):
            return "检测到上次迁移中断的残留备份：\(p)。请手工检查（可把 _backup 改名回原名恢复）后重试。"
        case .backupMissing(let p): return "备份不存在：\(p)"
        case .unsafeToDeleteBackup(let p):
            return "软链不存在或目标不可达，删除备份不安全，已拒绝：\(p)"
        case .notMigrated(let p): return "该目录尚未迁移，无法还原：\(p)"
        case .verifyFailed(let p): return "拷贝校验失败：\(p)"
        case .insufficientSpace(let need, let free):
            return "目标盘空间不足：需要 \(DiskProbe.formatBytes(need))，仅剩 \(DiskProbe.formatBytes(free))"
        }
    }
}

/// 迁移/还原核心：拷贝 → 校验 → 源改名 _backup → 建软链（失败自动回滚）。
/// 备份保留在本地，确认迁移完好后由用户手动删除以释放空间。
/// 全部为同步实现，由调用方放到后台线程执行。
enum Migrator {

    static func backupURL(for source: URL) -> URL {
        WeChatPaths.backupDirectory(for: source)
    }

    // MARK: - 目录树拷贝

    /// 递归拷贝目录树（target 必须不存在；校验用 directorySize 只算普通文件，与本拷贝语义一致）。
    /// - 普通文件逐一 copyItem，保留元数据；目录保留 posix 权限；
    /// - 相对软链改写为按源位置解析后的绝对软链——企业微信容器 Data 里的
    ///   Desktop/Downloads 等就是相对软链，整树搬离容器后不改写会全部失效；
    /// - socket/fifo 等运行时特殊文件跳过（App 启动时自建；copyItem 碰到会直接报错，
    ///   实测整搬企微容器 Data 必踩）。
    static func copyTree(from source: URL, to target: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: target, withIntermediateDirectories: true,
                               attributes: posixAttributes(of: source))
        guard let enumerator = fm.enumerator(atPath: source.path) else {
            throw MigrationError.sourceMissing(source.path)
        }
        for case let relative as String in enumerator {
            let src = source.appendingPathComponent(relative)
            let dst = target.appendingPathComponent(relative)
            guard let type = try? fm.attributesOfItem(atPath: src.path)[.type] as? FileAttributeType else {
                continue
            }
            switch type {
            case .typeDirectory:
                try fm.createDirectory(at: dst, withIntermediateDirectories: true,
                                       attributes: posixAttributes(of: src))
            case .typeSymbolicLink:
                let dest = try fm.destinationOfSymbolicLink(atPath: src.path)
                let resolved = dest.hasPrefix("/") ? dest
                    : ((src.deletingLastPathComponent().path as NSString)
                        .appendingPathComponent(dest) as NSString).standardizingPath
                try fm.createSymbolicLink(atPath: dst.path, withDestinationPath: resolved)
            case .typeRegular:
                try fm.copyItem(at: src, to: dst)
            default:
                continue   // socket / fifo / 设备文件等：跳过
            }
        }
    }

    /// 目录的 posix 权限属性（搬容器目录时保留 700 等权限位）。
    private static func posixAttributes(of url: URL) -> [FileAttributeKey: Any] {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let perm = attrs[.posixPermissions] else { return [:] }
        return [.posixPermissions: perm]
    }

    // MARK: - 迁移

    /// 把 source 迁移到 target（target 必须不存在）。
    /// 完成后：source 是指向 target 的软链，原数据保留在同级的 `<原名>_backup`。
    static func migrateItem(source: URL, target: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { throw MigrationError.sourceMissing(source.path) }
        guard !DiskProbe.isSymlink(source) else { throw MigrationError.sourceIsSymlink(source.path) }
        guard !fm.fileExists(atPath: target.path) else { throw MigrationError.targetAlreadyExists(target.path) }
        let backup = backupURL(for: source)
        // 上次迁移中断的残留：源位不是软链但 _backup 已存在，拒绝继续，避免覆盖备份。
        guard !fm.fileExists(atPath: backup.path) else {
            throw MigrationError.backupAlreadyExists(backup.path)
        }

        let expectedSize = DiskProbe.directorySize(at: source)
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)

        // 1. 拷贝
        do {
            try copyTree(from: source, to: target)
        } catch {
            try? fm.removeItem(at: target)
            throw error
        }

        // 2. 校验
        guard DiskProbe.directorySize(at: target) == expectedSize else {
            try? fm.removeItem(at: target)
            throw MigrationError.verifyFailed(target.path)
        }

        // 3. 源改名为 _backup（不删除），再建软链；任一步失败可回滚
        do {
            try fm.moveItem(at: source, to: backup)
            try fm.createSymbolicLink(at: source, withDestinationURL: target)
        } catch {
            try? fm.removeItem(at: source)
            try? fm.moveItem(at: backup, to: source)
            try? fm.removeItem(at: target)
            throw error
        }

        // 4. 确认软链可达；异常则整体回滚
        guard fm.fileExists(atPath: source.path) else {
            try? fm.removeItem(at: source)
            try? fm.moveItem(at: backup, to: source)
            try? fm.removeItem(at: target)
            throw MigrationError.verifyFailed("软链创建后目标不可达")
        }
    }

    // MARK: - 删除备份

    /// 删除迁移后保留的本地备份，返回释放的字节数。
    /// 安全检查：已迁移项仅当软链目标可达时才允许删除；
    /// 非软链项仅允许删除带标记的「覆盖安全网」备份（无标记的可能是迁移中断残留）。
    static func deleteBackup(source: URL) throws -> Int64 {
        let fm = FileManager.default
        let backup = backupURL(for: source)
        guard fm.fileExists(atPath: backup.path) else { throw MigrationError.backupMissing(backup.path) }
        if DiskProbe.isSymlink(source) {
            guard fm.fileExists(atPath: source.path) else {
                throw MigrationError.unsafeToDeleteBackup(backup.path)
            }
        } else {
            guard isOverwriteBackup(backup) else {
                throw MigrationError.unsafeToDeleteBackup(backup.path)
            }
        }
        let size = DiskProbe.directorySize(at: backup)
        try fm.removeItem(at: backup)
        return size
    }

    // MARK: - 还原

    /// 把已迁移的目录还原：
    /// - 本地 _backup 仍在 → 删软链 + 备份改名回原名（秒还原，外置盘副本保留不动）；
    /// - _backup 已删 → 从外置盘拷回 → 校验 → 删目标。
    static func restoreItem(source: URL, target: URL) throws {
        let fm = FileManager.default
        guard DiskProbe.isSymlink(source) else { throw MigrationError.notMigrated(source.path) }

        let backup = backupURL(for: source)
        if fm.fileExists(atPath: backup.path) {
            // 秒还原：仅做改名，失败则恢复软链
            try fm.removeItem(at: source)
            do {
                try fm.moveItem(at: backup, to: source)
            } catch {
                try? fm.removeItem(at: source)
                try? fm.createSymbolicLink(at: source, withDestinationURL: target)
                throw error
            }
            return
        }

        guard fm.fileExists(atPath: target.path) else { throw MigrationError.sourceMissing(target.path) }
        let expectedSize = DiskProbe.directorySize(at: target)

        // 1. 删软链（只删链接，不删数据）
        try fm.removeItem(at: source)

        // 2. 拷回原位
        do {
            try copyTree(from: target, to: source)
        } catch {
            // 拷回失败：尽量恢复软链，数据仍在 target
            try? fm.removeItem(at: source)
            try? fm.createSymbolicLink(at: source, withDestinationURL: target)
            throw error
        }

        // 3. 校验后删目标
        guard DiskProbe.directorySize(at: source) == expectedSize else {
            try? fm.removeItem(at: source)
            try? fm.createSymbolicLink(at: source, withDestinationURL: target)
            throw MigrationError.verifyFailed(source.path)
        }
        try? fm.removeItem(at: target)
    }

    // MARK: - 用外置数据覆盖内置

    /// 用外置数据覆盖内置：当前内置数据先改名 _backup（安全网），再拷入外置数据并校验，
    /// 失败整体回滚（_backup 改回原名）。源位是软链或 _backup 已存在时拒绝。
    /// 外置数据全程不动。
    static func overwriteLocalWithExternal(source: URL, target: URL) throws {
        let fm = FileManager.default
        // 双保险：可用条件在 UI 层已挡，这里再拒绝
        guard !DiskProbe.isSymlink(source) else { throw MigrationError.sourceIsSymlink(source.path) }
        let backup = backupURL(for: source)
        // 不静默销毁旧快照：提示先清理/还原已有备份
        guard !fm.fileExists(atPath: backup.path) else {
            throw MigrationError.backupAlreadyExists(backup.path)
        }
        guard fm.fileExists(atPath: target.path) else { throw MigrationError.sourceMissing(target.path) }
        guard fm.fileExists(atPath: source.path) else { throw MigrationError.sourceMissing(source.path) }
        let expectedSize = DiskProbe.directorySize(at: target)

        // 1. 当前内置数据改名 _backup（安全网）
        try fm.moveItem(at: source, to: backup)

        // 2. 拷入外置数据；失败回滚
        do {
            try copyTree(from: target, to: source)
        } catch {
            try? fm.removeItem(at: source)
            try? fm.moveItem(at: backup, to: source)
            throw error
        }

        // 3. 校验；失败回滚
        guard DiskProbe.directorySize(at: source) == expectedSize else {
            try? fm.removeItem(at: source)
            try? fm.moveItem(at: backup, to: source)
            throw MigrationError.verifyFailed(source.path)
        }

        // 4. 给安全网备份打标记（区别于"迁移中断残留"，后续可正常还原/清理）
        fm.createFile(atPath: backup.appendingPathComponent(Self.overwriteBackupMarker).path,
                      contents: Data())
    }

    /// 覆盖安全网备份内的标记文件名（隐藏文件，指纹/大小统计均跳过）。
    static let overwriteBackupMarker = ".wcm_overwrite_backup"

    /// 该 _backup 是否为「用外置数据覆盖内置」留下的安全网备份。
    static func isOverwriteBackup(_ backup: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: backup.appendingPathComponent(overwriteBackupMarker).path)
    }

    // MARK: - 强制从外置盘还原

    /// 强制从外置盘还原（外置数据比本地备份新时）：拷回 → 校验 → 删外置副本，
    /// 并删除已被外置数据取代的本地 _backup（留着会变成"中断残留"状态）。
    static func restoreItemFromExternal(source: URL, target: URL) throws {
        let fm = FileManager.default
        guard DiskProbe.isSymlink(source) else { throw MigrationError.notMigrated(source.path) }
        guard fm.fileExists(atPath: target.path) else { throw MigrationError.sourceMissing(target.path) }
        let backup = backupURL(for: source)
        let expectedSize = DiskProbe.directorySize(at: target)

        // 1. 删软链（只删链接，不删数据）
        try fm.removeItem(at: source)

        // 2. 拷回原位
        do {
            try copyTree(from: target, to: source)
        } catch {
            try? fm.removeItem(at: source)
            try? fm.createSymbolicLink(at: source, withDestinationURL: target)
            throw error
        }

        // 3. 校验后删外置副本与过期备份
        guard DiskProbe.directorySize(at: source) == expectedSize else {
            try? fm.removeItem(at: source)
            try? fm.createSymbolicLink(at: source, withDestinationURL: target)
            throw MigrationError.verifyFailed(source.path)
        }
        try? fm.removeItem(at: target)
        if fm.fileExists(atPath: backup.path) {
            try? fm.removeItem(at: backup)
        }
    }

    // MARK: - 还原内置备份

    /// 仅用本地 _backup 还原：删软链 + 备份改名回原名。
    /// 完全不访问外置盘（不插盘也能用）；备份不存在时拒绝（改用完整还原）。
    /// 带标记的「覆盖安全网」备份（源位不是软链）：当前内置数据让位给备份。
    static func restoreFromBackup(source: URL) throws {
        let fm = FileManager.default
        let backup = backupURL(for: source)
        let backupExists = fm.fileExists(atPath: backup.path)

        guard DiskProbe.isSymlink(source) else {
            // 非软链：无备份按未迁移拒绝（旧语义）；
            // 仅带标记的「覆盖安全网」备份可还原：当前内置数据让位给备份。
            guard backupExists, isOverwriteBackup(backup) else {
                throw MigrationError.notMigrated(source.path)
            }
            guard fm.fileExists(atPath: source.path) else {
                try fm.moveItem(at: backup, to: source)
                return
            }
            // 当前内置数据（外置拷入的）暂存，备份回位后删除；失败回滚
            let staging = source.deletingLastPathComponent()
                .appendingPathComponent(source.lastPathComponent + "_restoring", isDirectory: true)
            try? fm.removeItem(at: staging)
            try fm.moveItem(at: source, to: staging)
            do {
                try fm.moveItem(at: backup, to: source)
            } catch {
                try? fm.moveItem(at: staging, to: source)
                throw error
            }
            try? fm.removeItem(at: staging)
            return
        }

        guard backupExists else { throw MigrationError.backupMissing(backup.path) }
        // 先记下软链目标用于失败回滚（只读，不访问目标本身）
        let dest = try? fm.destinationOfSymbolicLink(atPath: source.path)
        try fm.removeItem(at: source)
        do {
            try fm.moveItem(at: backup, to: source)
        } catch {
            try? fm.removeItem(at: source)
            if let dest { try? fm.createSymbolicLink(atPath: source.path, withDestinationPath: dest) }
            throw error
        }
    }

    // MARK: - 转移已迁移数据到新位置

    /// 已迁移状态下更改目标位置：把数据从旧位置（当前软链指向）转移到 newTarget，
    /// 然后把软链换指向新位置。拷贝 → 校验 → 换指向 → 删旧数据；失败回滚（软链指回旧位置、删新副本）。
    static func relocateItem(source: URL, newTarget: URL) throws {
        let fm = FileManager.default
        guard DiskProbe.isSymlink(source) else { throw MigrationError.notMigrated(source.path) }
        let dest = try fm.destinationOfSymbolicLink(atPath: source.path)
        let oldTarget = URL(fileURLWithPath: dest, isDirectory: true)
        // 幂等：上次部分完成后的重试，已指向新位置的项直接跳过
        if oldTarget.path == newTarget.path { return }
        guard !fm.fileExists(atPath: newTarget.path) else {
            throw MigrationError.targetAlreadyExists(newTarget.path)
        }
        guard fm.fileExists(atPath: oldTarget.path) else {
            throw MigrationError.sourceMissing(oldTarget.path)
        }
        let expectedSize = DiskProbe.directorySize(at: oldTarget)
        try fm.createDirectory(at: newTarget.deletingLastPathComponent(), withIntermediateDirectories: true)

        // 1. 拷贝到新位置
        do {
            try copyTree(from: oldTarget, to: newTarget)
        } catch {
            try? fm.removeItem(at: newTarget)
            throw error
        }

        // 2. 校验
        guard DiskProbe.directorySize(at: newTarget) == expectedSize else {
            try? fm.removeItem(at: newTarget)
            throw MigrationError.verifyFailed(newTarget.path)
        }

        // 3. 软链换指向新位置；失败回滚（指回旧位置、删新副本）
        do {
            try fm.removeItem(at: source)
            try fm.createSymbolicLink(at: source, withDestinationURL: newTarget)
        } catch {
            try? fm.removeItem(at: source)
            try? fm.createSymbolicLink(at: source, withDestinationURL: oldTarget)
            try? fm.removeItem(at: newTarget)
            throw error
        }

        // 4. 确认新指向可达；异常回滚
        guard fm.fileExists(atPath: source.path) else {
            try? fm.removeItem(at: source)
            try? fm.createSymbolicLink(at: source, withDestinationURL: oldTarget)
            try? fm.removeItem(at: newTarget)
            throw MigrationError.verifyFailed("软链换指向后目标不可达")
        }

        // 5. 校验通过后删除旧位置数据
        try? fm.removeItem(at: oldTarget)
    }

    // MARK: - 不转移改指（新位置已有数据，仅换软链指向）

    /// 不拷贝、不删除，仅把软链改指到新位置（要求新位置已有完整数据；旧位置数据保留不动）。
    /// 失败回滚（指回原位置）。幂等：已指向新位置则跳过。
    static func repointItem(source: URL, newTarget: URL) throws {
        let fm = FileManager.default
        guard DiskProbe.isSymlink(source) else { throw MigrationError.notMigrated(source.path) }
        let dest = try fm.destinationOfSymbolicLink(atPath: source.path)
        let oldTarget = URL(fileURLWithPath: dest, isDirectory: true)
        // 幂等：已指向新位置则跳过
        if oldTarget.path == newTarget.path { return }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: newTarget.path, isDirectory: &isDir), isDir.boolValue,
              !DiskProbe.isSymlink(newTarget) else {
            throw MigrationError.sourceMissing(newTarget.path)
        }
        do {
            try fm.removeItem(at: source)
            try fm.createSymbolicLink(at: source, withDestinationURL: newTarget)
        } catch {
            try? fm.removeItem(at: source)
            try? fm.createSymbolicLink(at: source, withDestinationURL: oldTarget)
            throw error
        }
        // 确认新指向可达；异常回滚
        guard fm.fileExists(atPath: source.path) else {
            try? fm.removeItem(at: source)
            try? fm.createSymbolicLink(at: source, withDestinationURL: oldTarget)
            throw MigrationError.verifyFailed("软链改指后目标不可达")
        }
    }

    // MARK: - 前置检查

    /// 检查目标卷剩余空间是否装得下这些数据。
    static func checkSpace(totalBytes: Int64, targetPath: String) throws {
        if let free = DiskProbe.freeSpace(path: targetPath), free < totalBytes {
            throw MigrationError.insufficientSpace(need: totalBytes, free: free)
        }
    }

    // MARK: - 直接使用外置已有数据（收养）

    /// 不拷贝，直接采用外置已有数据：本地源改名 _backup（安全网），建软链指向 target。
    /// 失败回滚（_backup 改回原名）。源位/目标已是软链、_backup 已存在、目标不存在时拒绝。
    static func adoptExternalItem(source: URL, target: URL) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: target.path, isDirectory: &isDir), isDir.boolValue,
              !DiskProbe.isSymlink(target) else {
            throw MigrationError.sourceMissing(target.path)
        }
        guard fm.fileExists(atPath: source.path) else { throw MigrationError.sourceMissing(source.path) }
        guard !DiskProbe.isSymlink(source) else { throw MigrationError.sourceIsSymlink(source.path) }
        let backup = backupURL(for: source)
        guard !fm.fileExists(atPath: backup.path) else {
            throw MigrationError.backupAlreadyExists(backup.path)
        }

        do {
            try fm.moveItem(at: source, to: backup)
            try fm.createSymbolicLink(at: source, withDestinationURL: target)
        } catch {
            try? fm.removeItem(at: source)
            try? fm.moveItem(at: backup, to: source)
            throw error
        }

        // 确认软链可达；异常则整体回滚
        guard fm.fileExists(atPath: source.path) else {
            try? fm.removeItem(at: source)
            try? fm.moveItem(at: backup, to: source)
            throw MigrationError.verifyFailed("软链创建后目标不可达")
        }
    }
}
