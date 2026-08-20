import Testing
import Foundation
@testable import WeChatMover

/// 所有用例只操作临时目录 fixture，绝不触碰真实微信数据。
private func withTempDir(_ body: (URL) throws -> Void) throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("WeChatMoverTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(dir)
}

/// 造一个带几个文件的假数据目录。
@discardableResult
private func makeDataDir(root: URL, _ relative: String, fileSizes: [Int] = [100, 200, 300]) throws -> URL {
    let dir = root.appendingPathComponent(relative, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for (i, size) in fileSizes.enumerated() {
        try Data(repeating: UInt8(i + 1), count: size)
            .write(to: dir.appendingPathComponent("file\(i).bin"))
    }
    return dir
}

/// 每个测试独立的 UserDefaults suite：并行测试共享 .standard 会互相污染
/// （targetBasePath 等键），注入独立 suite 彻底隔离。返回 suite 与清理闭包。
private func makeIsolatedDefaults() -> (defaults: UserDefaults, cleanup: () -> Void) {
    let name = "WeChatMoverTests-\(UUID().uuidString)"
    let suite = UserDefaults(suiteName: name)!
    return (suite, { suite.removePersistentDomain(forName: name) })
}

// MARK: - 路径模型

@Test func targetPathMapping() {
    let base = URL(fileURLWithPath: "/Volumes/Ext/MyFolder", isDirectory: true)
    #expect(WeChatPaths.targetDirectory(base: base, subdir: "Documents/xwechat_files").path
            == "/Volumes/Ext/MyFolder/WeChatData/xwechat_files")
    #expect(WeChatPaths.targetDirectory(base: base, subdir: "Documents/app_data").path
            == "/Volumes/Ext/MyFolder/WeChatData/app_data")
    #expect(WeChatPaths.targetDirectory(base: base, subdir: "Library/Application Support/com.tencent.xinWeChat").path
            == "/Volumes/Ext/MyFolder/WeChatData/com.tencent.xinWeChat")
}

@Test func weworkSourceMapping() {
    // 企业微信整搬两个目录：容器 Data 整体 + 容器外 WXWork/Data。
    // 不猜容器内部子目录（老安装 Documents 是软链、新安装是真实目录，整搬都覆盖）。
    let container = URL(fileURLWithPath: "/tmp/fixture/Data", isDirectory: true)
    let ww = AppProfile.wework
    #expect(ww.sourceDirectory(key: "com.tencent.WeWorkMac-Data", containerRoot: container) == container)
    #expect(ww.sourceDirectory(key: "WXWork-Data", containerRoot: container)
            == FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/WXWork/Data", isDirectory: true))
    // 微信候选仍是容器相对路径
    let wc = AppProfile.wechat
    #expect(wc.sourceDirectory(key: "Documents/xwechat_files", containerRoot: container).path
            == "/tmp/fixture/Data/Documents/xwechat_files")
}

// MARK: - 目录树拷贝（整搬容器 Data 的基石）

@Test func copyTreeSkipsSocketsAndAbsolutizesRelativeSymlinks() throws {
    try withTempDir { root in
        let fm = FileManager.default
        let src = root.appendingPathComponent("src", isDirectory: true)
        let dst = root.appendingPathComponent("dst", isDirectory: true)
        try fm.createDirectory(at: src.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: src.appendingPathComponent("sub/file.txt"))
        // 相对软链（企微容器 Data 里的 Desktop/Downloads 就是这种）
        try fm.createSymbolicLink(atPath: src.appendingPathComponent("sub/rel").path,
                                  withDestinationPath: "../sub/file.txt")
        // 绝对软链原样保留
        try fm.createSymbolicLink(atPath: src.appendingPathComponent("abs").path,
                                  withDestinationPath: "/tmp")
        // socket：copyItem 碰到会直接报错，copyTree 必须跳过
        let sockFD = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let sockPath = src.appendingPathComponent("ipc.sock").path
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            strcpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), sockPath)
        }
        #expect(bind(sockFD, withUnsafePointer(to: &addr, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 } }),
                     socklen_t(MemoryLayout<sockaddr_un>.size)) == 0)
        defer { close(sockFD) }

        try Migrator.copyTree(from: src, to: dst)

        // 普通文件内容一致
        #expect(try String(contentsOf: dst.appendingPathComponent("sub/file.txt"), encoding: .utf8) == "hello")
        // 相对软链 → 绝对软链，且在源位置可解析（搬走不失效）
        let relDest = try fm.destinationOfSymbolicLink(atPath: dst.appendingPathComponent("sub/rel").path)
        #expect(relDest.hasPrefix("/"))
        #expect(fm.fileExists(atPath: dst.appendingPathComponent("sub/rel").path))
        // 绝对软链原样
        #expect(try fm.destinationOfSymbolicLink(atPath: dst.appendingPathComponent("abs").path) == "/tmp")
        // socket 被跳过
        #expect(!fm.fileExists(atPath: dst.appendingPathComponent("ipc.sock").path))
        // 大小校验语义一致（只算普通文件）
        #expect(DiskProbe.directorySize(at: dst) == DiskProbe.directorySize(at: src))
    }
}

// MARK: - 软链识别

@Test func symlinkDetection() throws {
    try withTempDir { root in
        let real = try makeDataDir(root: root, "real")
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        #expect(DiskProbe.isSymlink(link))
        #expect(!DiskProbe.isSymlink(real))
        #expect(!DiskProbe.isSymlink(root.appendingPathComponent("nope")))
    }
}

// MARK: - 状态推断

@Test func itemStateMissing() throws {
    try withTempDir { root in
        #expect(itemState(at: root.appendingPathComponent("nothing")) == .missing)
    }
}

@Test func itemStateLocal() throws {
    try withTempDir { root in
        let dir = try makeDataDir(root: root, "data")
        #expect(itemState(at: dir) == .local)
    }
}

@Test func itemStateMigrated() throws {
    try withTempDir { root in
        let target = try makeDataDir(root: root, "WeChatData/xwechat_files")
        let source = root.appendingPathComponent("Documents/xwechat_files")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: target)
        #expect(itemState(at: source) == .migrated)
    }
}

@Test func itemStateBrokenSymlink() throws {
    try withTempDir { root in
        // 指向不存在目标的软链 = 外置盘未插入
        let source = root.appendingPathComponent("Documents/app_data")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: root.appendingPathComponent("unplugged"))
        #expect(itemState(at: source) == .brokenSymlink)
    }
}

// MARK: - APFS 判断（纯逻辑）

@Test func isAPFSJudgement() {
    #expect(DiskProbe.isAPFS(fsTypeName: "apfs"))
    #expect(DiskProbe.isAPFS(fsTypeName: "APFS"))
    #expect(!DiskProbe.isAPFS(fsTypeName: "exfat"))
    #expect(!DiskProbe.isAPFS(fsTypeName: "ntfs"))
    #expect(!DiskProbe.isAPFS(fsTypeName: "hfs"))
}

// MARK: - 目录大小

@Test func directorySizeCounting() throws {
    try withTempDir { root in
        let dir = try makeDataDir(root: root, "sized", fileSizes: [128, 256])
        #expect(DiskProbe.directorySize(at: dir) == 384)
        #expect(DiskProbe.directorySize(at: root.appendingPathComponent("missing")) == 0)
    }
}

// MARK: - 签名命令

@Test func codesignCommand() {
    #expect(CodeSigner.codesignArguments()
            == ["--sign", "-", "--force", "--deep", "/Applications/WeChat.app"])
    #expect(CodeSigner.shellCommand() == "codesign --sign - --force --deep /Applications/WeChat.app")
    // 企业微信档案
    #expect(CodeSigner.shellCommand(appPath: "/Applications/企业微信.app")
            == "codesign --sign - --force --deep /Applications/企业微信.app")
}

// MARK: - App Store 版检测

@Test func masReceiptDetection() throws {
    try withTempDir { root in
        let contents = root.appendingPathComponent("WeChat.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let appURL = root.appendingPathComponent("WeChat.app")
        #expect(!WeChatDetector.isAppStoreVersion(appURL: appURL))

        let receiptDir = contents.appendingPathComponent("_MASReceipt", isDirectory: true)
        try FileManager.default.createDirectory(at: receiptDir, withIntermediateDirectories: true)
        try Data().write(to: receiptDir.appendingPathComponent("receipt"))
        #expect(WeChatDetector.isAppStoreVersion(appURL: appURL))
    }
}

// MARK: - 迁移 / 还原全流程（临时目录 fixture）

@Test func migrateAndRestoreRoundtrip() throws {
    try withTempDir { root in
        let source = try makeDataDir(root: root, "container/Documents/xwechat_files", fileSizes: [512, 1024])
        let base = root.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let target = WeChatPaths.targetDirectory(base: base, subdir: "Documents/xwechat_files")
        let backup = WeChatPaths.backupDirectory(for: source)

        // 迁移：源改名为 _backup 保留，原位建软链
        try Migrator.migrateItem(source: source, target: target)
        #expect(DiskProbe.isSymlink(source))
        #expect(itemState(at: source) == .migrated)
        #expect(DiskProbe.directorySize(at: target) == 1536)
        #expect(DiskProbe.directorySize(at: backup) == 1536)   // 备份保留
        // 通过软链能读到原文件
        #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("file0.bin").path))

        // 重复迁移应被拒绝
        #expect(throws: MigrationError.self) {
            try Migrator.migrateItem(source: source, target: root.appendingPathComponent("other"))
        }

        // 秒还原：备份改名回原名，外置盘副本保留不动
        try Migrator.restoreItem(source: source, target: target)
        #expect(!DiskProbe.isSymlink(source))
        #expect(itemState(at: source) == .local)
        #expect(DiskProbe.directorySize(at: source) == 1536)
        #expect(!FileManager.default.fileExists(atPath: backup.path))
        #expect(FileManager.default.fileExists(atPath: target.path))   // 外置盘副本保留
    }
}

// MARK: - _backup 机制

@Test func backupPathMapping() {
    let source = URL(fileURLWithPath: "/tmp/c/Documents/xwechat_files", isDirectory: true)
    #expect(WeChatPaths.backupDirectory(for: source).path
            == "/tmp/c/Documents/xwechat_files_backup")
}

@Test func restorePrefersLocalBackup() throws {
    try withTempDir { root in
        let source = try makeDataDir(root: root, "container/Documents/app_data", fileSizes: [256])
        let base = root.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let target = WeChatPaths.targetDirectory(base: base, subdir: "Documents/app_data")
        try Migrator.migrateItem(source: source, target: target)

        // 删掉外置盘副本，模拟"外置盘不在手边"：有本地备份照样能秒还原
        try FileManager.default.removeItem(at: target)
        try Migrator.restoreItem(source: source, target: target)
        #expect(itemState(at: source) == .local)
        #expect(DiskProbe.directorySize(at: source) == 256)
    }
}

@Test func restoreFallsBackToExternalCopy() throws {
    try withTempDir { root in
        let source = try makeDataDir(root: root, "container/Documents/app_data", fileSizes: [256])
        let base = root.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let target = WeChatPaths.targetDirectory(base: base, subdir: "Documents/app_data")
        try Migrator.migrateItem(source: source, target: target)

        // 用户已删本地备份 → 走外置盘拷回路径，完成后删外置盘副本
        try FileManager.default.removeItem(at: WeChatPaths.backupDirectory(for: source))
        try Migrator.restoreItem(source: source, target: target)
        #expect(itemState(at: source) == .local)
        #expect(DiskProbe.directorySize(at: source) == 256)
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }
}

@Test func deleteBackupSafetyChecks() throws {
    try withTempDir { root in
        let source = try makeDataDir(root: root, "container/Documents/xwechat_files", fileSizes: [512])
        let base = root.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let target = WeChatPaths.targetDirectory(base: base, subdir: "Documents/xwechat_files")
        let backup = WeChatPaths.backupDirectory(for: source)

        // 未迁移（无 _backup）→ 拒绝
        #expect(throws: MigrationError.self) { try Migrator.deleteBackup(source: source) }

        try Migrator.migrateItem(source: source, target: target)
        // 迁移完好（软链有效）→ 允许删除并返回释放空间
        let freed = try Migrator.deleteBackup(source: source)
        #expect(freed == 512)
        #expect(!FileManager.default.fileExists(atPath: backup.path))
        #expect(itemState(at: source) == .migrated)

        // 再删一次 → 备份不存在
        #expect {
            try Migrator.deleteBackup(source: source)
        } throws: { error in
            guard case MigrationError.backupMissing = error else { return false }
            return true
        }
    }
}

@Test func deleteBackupRefusesWhenSymlinkBroken() throws {
    try withTempDir { root in
        let source = try makeDataDir(root: root, "container/Documents/xwechat_files", fileSizes: [128])
        let base = root.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let target = WeChatPaths.targetDirectory(base: base, subdir: "Documents/xwechat_files")
        try Migrator.migrateItem(source: source, target: target)

        // 外置盘副本消失 → 软链失效，删除备份必须被拒绝
        try FileManager.default.removeItem(at: target)
        #expect {
            try Migrator.deleteBackup(source: source)
        } throws: { error in
            guard case MigrationError.unsafeToDeleteBackup = error else { return false }
            return true
        }
        // 备份仍在
        #expect(FileManager.default.fileExists(
            atPath: WeChatPaths.backupDirectory(for: source).path))
    }
}

@Test func interruptedResidueDetection() throws {
    try withTempDir { root in
        // 源位是普通目录且 _backup 已存在 = 上次迁移中断残留
        let source = try makeDataDir(root: root, "container/Documents/xwechat_files")
        _ = try makeDataDir(root: root, "container/Documents/xwechat_files_backup", fileSizes: [64])
        #expect(itemState(at: source) == .interrupted)

        // 迁移必须明确报错而不是静默失败
        let target = root.appendingPathComponent("external/WeChatData/xwechat_files")
        #expect {
            try Migrator.migrateItem(source: source, target: target)
        } throws: { error in
            guard case MigrationError.backupAlreadyExists = error else { return false }
            return true
        }
    }
}

@Test func migratedWithBackupStateDistinction() throws {
    try withTempDir { root in
        let source = try makeDataDir(root: root, "container/Documents/xwechat_files", fileSizes: [128])
        let base = root.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let target = WeChatPaths.targetDirectory(base: base, subdir: "Documents/xwechat_files")
        try Migrator.migrateItem(source: source, target: target)

        // 已迁移且备份仍在
        #expect(itemState(at: source) == .migrated)
        #expect(FileManager.default.fileExists(
            atPath: WeChatPaths.backupDirectory(for: source).path))

        // 删掉备份 → 已迁移无备份，状态仍为 migrated
        _ = try Migrator.deleteBackup(source: source)
        #expect(itemState(at: source) == .migrated)
    }
}

@Test func migrateRefusesExistingTarget() throws {
    try withTempDir { root in
        let source = try makeDataDir(root: root, "container2/Documents/app_data")
        let target = try makeDataDir(root: root, "external2/WeChatData/app_data")
        #expect {
            try Migrator.migrateItem(source: source, target: target)
        } throws: { error in
            guard case MigrationError.targetAlreadyExists = error else { return false }
            return true
        }
        // 源应保持原样
        #expect(itemState(at: source) == .local)
    }
}

@Test func restoreRefusesNonSymlink() throws {
    try withTempDir { root in
        let source = try makeDataDir(root: root, "container3/Documents/app_data")
        #expect {
            try Migrator.restoreItem(source: source, target: root.appendingPathComponent("whatever"))
        } throws: { error in
            guard case MigrationError.notMigrated = error else { return false }
            return true
        }
    }
}


// MARK: - 安装/来源检测（Bug 2 回归：只依赖 /Applications/WeChat.app 本体）

/// 造一个假 .app（Contents/Info.plist，可选 MASReceipt）。
private func makeFakeApp(root: URL, version: String?, masReceipt: Bool) throws -> URL {
    let contents = root.appendingPathComponent("WeChat.app/Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    if let version {
        try NSDictionary(dictionary: ["CFBundleShortVersionString": version])
            .write(to: contents.appendingPathComponent("Info.plist"))
    }
    if masReceipt {
        let receiptDir = contents.appendingPathComponent("_MASReceipt", isDirectory: true)
        try FileManager.default.createDirectory(at: receiptDir, withIntermediateDirectories: true)
        try Data().write(to: receiptDir.appendingPathComponent("receipt"))
    }
    return root.appendingPathComponent("WeChat.app")
}

@Test func detectOfficialDMGVersion() throws {
    try withTempDir { root in
        let app = try makeFakeApp(root: root, version: "4.1.12", masReceipt: false)
        let info = WeChatDetector.detect(appURL: app)
        #expect(info.isInstalled)
        #expect(info.version == "4.1.12")
        #expect(!info.isAppStoreVersion)
    }
}

@Test func detectAppStoreVersion() throws {
    try withTempDir { root in
        let app = try makeFakeApp(root: root, version: "4.1.12", masReceipt: true)
        let info = WeChatDetector.detect(appURL: app)
        #expect(info.isInstalled)
        #expect(info.isAppStoreVersion)
    }
}

@Test func detectNotInstalled() throws {
    try withTempDir { root in
        let info = WeChatDetector.detect(appURL: root.appendingPathComponent("NoSuch.app"))
        #expect(!info.isInstalled)
        #expect(info.version == nil)
        #expect(!info.isAppStoreVersion)
    }
}

/// 本机真实环境只读验证：/Applications/WeChat.app 应识别为「已安装 / 官网 DMG 版」。
/// 仅在存在该 App 的机器上运行，其他机器自动跳过。
@Test(
    .enabled(if: FileManager.default.fileExists(atPath: "/Applications/WeChat.app"))
)
func detectRealWeChat() {
    let info = WeChatDetector.detect()
    #expect(info.isInstalled)
    #expect(info.version != nil)
    #expect(!info.isAppStoreVersion)  // 本机为官网 DMG 版
}

// MARK: - 目标选择回调（与 NSOpenPanel 解耦后的纯逻辑）

@MainActor @Test func applyTargetSelectionPersists() throws {
    try withTempDir { root in
        let folder = root.appendingPathComponent("ExtFolder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let (defaults, cleanup) = makeIsolatedDefaults()
        defer { cleanup() }
        let vm = AppViewModel()
        vm.defaults = defaults
        vm.applyTargetSelection(folder)
        #expect(vm.targetBase?.path == folder.path)
        #expect(defaults.string(forKey: DefaultsKey.targetBasePath) == folder.path)
        #expect(vm.targetFSType != nil)                       // 卷格式已探测
        #expect(vm.targetFreeSpace != nil)                    // 剩余空间已探测
        #expect(vm.logs.contains { $0.contains("已选择目标位置") })
    }
}

// MARK: - codesign 结果解析（纯逻辑）

@Test func parseResignResultSuccess() {
    #expect(CodeSigner.parseResult(status: 0, stderr: "") == .success)
    // 退出码 0 即成功，即使 stderr 有杂散输出
    #expect(CodeSigner.parseResult(status: 0, stderr: "noise") == .success)
}

@Test func parseResignResultFailure() {
    #expect(CodeSigner.parseResult(status: 1, stderr: "some error\n")
            == .failed("some error"))
    #expect(CodeSigner.parseResult(status: 3, stderr: "  \n") == .failed("退出码 3"))
}

// MARK: - 进程异步执行（用 /bin/sh fixture）

@Test func runProcessSuccess() async {
    let result: CodeSigner.ResignResult = await withCheckedContinuation { cont in
        CodeSigner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exit 0"]
        ) { cont.resume(returning: $0) }
    }
    #expect(result == .success)
}

@Test func runProcessFailure() async {
    let result: CodeSigner.ResignResult = await withCheckedContinuation { cont in
        CodeSigner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo boom >&2; exit 2"]
        ) { cont.resume(returning: $0) }
    }
    #expect(result == .failed("boom"))
}

/// stderr 输出超过管道缓冲（64KB）时进程不应假死：readabilityHandler 持续排空。
@Test func runProcessLargeStderrNoDeadlock() async {
    let result: CodeSigner.ResignResult = await withCheckedContinuation { cont in
        CodeSigner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "i=0; while [ $i -lt 20000 ]; do echo line$i >&2; i=$((i+1)); done; exit 7"]
        ) { cont.resume(returning: $0) }
    }
    if case .failed(let msg) = result {
        #expect(msg.contains("line19999"))   // stderr 完整读完
    } else {
        Issue.record("期望 failed，实际 \(result)")
    }
}

// MARK: - 退出微信流程（注入假 closure，不触碰真实微信）

private final class QuitFixture: @unchecked Sendable {
    var running = true
    var gracefulCalls = 0
    var forceCalls = 0
}

@Test func ensureQuitSkipsWhenNotRunning() async {
    let f = QuitFixture()
    f.running = false
    let ok = await WeChatQuitter.ensureQuit(
        isRunning: { f.running },
        graceful: { f.gracefulCalls += 1 },
        force: { f.forceCalls += 1 })
    #expect(ok)
    #expect(f.gracefulCalls == 0)
    #expect(f.forceCalls == 0)
}

@Test func ensureQuitGracefulSuccess() async {
    let f = QuitFixture()
    let ok = await WeChatQuitter.ensureQuit(
        graceTimeout: 2, forceTimeout: 1,
        isRunning: { f.running },
        graceful: { f.gracefulCalls += 1; f.running = false },   // 优雅退出成功
        force: { f.forceCalls += 1 })
    #expect(ok)
    #expect(f.gracefulCalls == 1)
    #expect(f.forceCalls == 0)                                    // 不应强杀
}

@Test func ensureQuitForceKillAfterGraceTimeout() async {
    let f = QuitFixture()
    let ok = await WeChatQuitter.ensureQuit(
        graceTimeout: 0.4, forceTimeout: 2,
        isRunning: { f.running },
        graceful: { f.gracefulCalls += 1 },                       // 优雅退出无效
        force: { f.forceCalls += 1; f.running = false })          // 强杀生效
    #expect(ok)
    #expect(f.gracefulCalls == 1)
    #expect(f.forceCalls == 1)
}

@Test func ensureQuitFailsWhenProcessStubborn() async {
    let f = QuitFixture()
    let ok = await WeChatQuitter.ensureQuit(
        graceTimeout: 0.3, forceTimeout: 0.3,
        isRunning: { f.running },                                 // 始终不退
        graceful: { f.gracefulCalls += 1 },
        force: { f.forceCalls += 1 })
    #expect(!ok)
    #expect(f.gracefulCalls == 1)
    #expect(f.forceCalls == 1)
}

@Test func waitForExitTiming() async {
    let timedOut = await WeChatQuitter.waitForExit(timeout: 0.3, pollInterval: 0.1) { true }
    #expect(!timedOut)
    let exited = await WeChatQuitter.waitForExit(timeout: 1, pollInterval: 0.1) { false }
    #expect(exited)
}

// MARK: - App 管理权限缺失分类（TCC EPERM）

@Test func parseResignResultAppManagementDenied() {
    // 用户实测的真实 stderr
    let real = """
        0:105: execution error: /Applications/WeChat.app: replacing existing signature
        /Applications/WeChat.app: Operation not permitted
        In subcomponent: /Applications/WeChat.app/Contents/MacOS/WeChatAppEx.app (1)
        """
    let result = CodeSigner.parseResult(status: 1, stderr: real)
    guard case .appManagementDenied(let detail) = result else {
        Issue.record("EPERM 应分类为 appManagementDenied，实际 \(result)")
        return
    }
    #expect(detail.contains("Operation not permitted"))
    // 不含 EPERM 的普通失败仍走 failed
    #expect(CodeSigner.parseResult(status: 1, stderr: "boom") == .failed("boom"))
}

@Test func terminalFallbackCommand() {
    #expect(CodeSigner.terminalCommand()
            == "sudo codesign --sign - --force --deep /Applications/WeChat.app")
    #expect(CodeSigner.terminalCommand(appPath: "/Applications/企业微信.app")
            == "sudo codesign --sign - --force --deep /Applications/企业微信.app")
}

// MARK: - 目标冲突路径安全检查（纯逻辑）

@Test func conflictPathSafety() {
    let base = URL(fileURLWithPath: "/Volumes/Ext/test", isDirectory: true)
    #expect(AppViewModel.isConflictPathInsideTarget(
        "/Volumes/Ext/test/WeChatData/xwechat_files", base: base))
    // 目标目录外一律拒绝
    #expect(!AppViewModel.isConflictPathInsideTarget("/Volumes/Ext/test", base: base))
    #expect(!AppViewModel.isConflictPathInsideTarget(
        "/Volumes/Ext/test/WeChatData", base: base))
    #expect(!AppViewModel.isConflictPathInsideTarget("/etc/whatever", base: base))
    #expect(!AppViewModel.isConflictPathInsideTarget(
        "/Volumes/Ext/test2/WeChatData/x", base: base))
}

// MARK: - 迁移目标冲突流程（临时目录 fixture，注入假依赖）

/// 轮询等待 MainActor 上的条件成立（集成测试用）。
@MainActor
private func waitUntil(
    _ timeout: TimeInterval = 10,
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    return condition()
}

@MainActor @Test func migrationTargetConflictFlow() async throws {
    // withTempDir 是同步闭包，这里要 await，改为内联临时目录（同样的 fixture 约定）
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WeChatMoverTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let source = try makeDataDir(root: root, "container/Documents/xwechat_files",
                                 fileSizes: [128])
    let base = root.appendingPathComponent("external", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let target = WeChatPaths.targetDirectory(base: base,
                                             subdir: "Documents/xwechat_files")
    // 上次中断/重复迁移留下的旧数据
    _ = try makeDataDir(root: root, "external/WeChatData/xwechat_files",
                        fileSizes: [64])

    let vm = AppViewModel()
    vm.isWeChatRunning = { false }
    vm.resignRunner = { completion in completion(.success) }   // 不弹真实密码框
    // 容器根指向 fixture：refresh() 重建 items 时不会碰到真实微信数据
    vm.containerRoot = root.appendingPathComponent("container", isDirectory: true)
    vm.targetBase = base
    vm.items = [ItemStatus(subdir: "Documents/xwechat_files", source: source,
                           state: .local, size: 128, hasBackup: false, backupSize: 0)]

    // 1. 目标已存在 → 不判失败，弹「删除旧数据并重新迁移」确认框
    vm.startMigration()
    #expect(await waitUntil { vm.showExistingTargetConfirm })
    #expect(vm.conflictingTargetPaths == [target.path])
    #expect(vm.lastError == nil)
    #expect(vm.logs.contains { $0.contains("目标位置已有数据") })
    #expect(FileManager.default.fileExists(atPath: target.path))   // 旧数据还在

    // 2. 确认删除旧数据并重新迁移 → 迁移成功
    vm.removeConflictingTargetAndMigrate()
    let migrated = await waitUntil {
        !vm.isBusy && itemState(at: source) == .migrated
    }
    #expect(migrated)
    #expect(DiskProbe.directorySize(at: target) == 128)   // 新数据覆盖了旧数据
    #expect(vm.lastError == nil)
}

@MainActor @Test func migrationMultipleConflictsSingleConfirm() async throws {
    // 两个迁移项的目标都已存在：只弹一次确认框，一次确认后全部完成
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WeChatMoverTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let source1 = try makeDataDir(root: root, "container/Documents/xwechat_files",
                                  fileSizes: [128])
    let source2 = try makeDataDir(root: root, "container/Documents/app_data",
                                  fileSizes: [64])
    let base = root.appendingPathComponent("external", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    // 两项都留有旧数据
    _ = try makeDataDir(root: root, "external/WeChatData/xwechat_files", fileSizes: [32])
    _ = try makeDataDir(root: root, "external/WeChatData/app_data", fileSizes: [32])

    let vm = AppViewModel()
    vm.isWeChatRunning = { false }
    vm.resignRunner = { completion in completion(.success) }
    vm.containerRoot = root.appendingPathComponent("container", isDirectory: true)
    vm.targetBase = base
    vm.items = [
        ItemStatus(subdir: "Documents/xwechat_files", source: source1,
                   state: .local, size: 128, hasBackup: false, backupSize: 0),
        ItemStatus(subdir: "Documents/app_data", source: source2,
                   state: .local, size: 64, hasBackup: false, backupSize: 0),
    ]

    // 一次弹窗收集全部冲突
    vm.startMigration()
    #expect(await waitUntil { vm.showExistingTargetConfirm })
    #expect(vm.conflictingTargetPaths.count == 2)

    // 一次确认 → 两项都迁移完成，不再二次弹窗
    vm.removeConflictingTargetAndMigrate()
    let done = await waitUntil {
        !vm.isBusy && itemState(at: source1) == .migrated && itemState(at: source2) == .migrated
    }
    #expect(done)
    #expect(vm.lastError == nil)
    #expect(!vm.showExistingTargetConfirm)
}

// MARK: - 转移已迁移数据到新位置

@Test func relocateItemSuccess() throws {
    try withTempDir { root in
        let source = try makeDataDir(root: root, "container/Documents/xwechat_files",
                                     fileSizes: [128, 256])
        let oldBase = root.appendingPathComponent("external", isDirectory: true)
        let oldTarget = WeChatPaths.targetDirectory(base: oldBase,
                                                    subdir: "Documents/xwechat_files")
        try Migrator.migrateItem(source: source, target: oldTarget)
        let backup = WeChatPaths.backupDirectory(for: source)
        let backupSize = DiskProbe.directorySize(at: backup)

        let newBase = root.appendingPathComponent("external2", isDirectory: true)
        let newTarget = WeChatPaths.targetDirectory(base: newBase,
                                                    subdir: "Documents/xwechat_files")
        try Migrator.relocateItem(source: source, newTarget: newTarget)

        // 软链指向新位置且可达，内容完整；旧位置已删；_backup 不动
        #expect(itemState(at: source) == .migrated)
        let dest = try FileManager.default.destinationOfSymbolicLink(atPath: source.path)
        #expect(dest == newTarget.path)
        #expect(DiskProbe.directorySize(at: newTarget) == 384)
        #expect(!FileManager.default.fileExists(atPath: oldTarget.path))
        #expect(DiskProbe.directorySize(at: backup) == backupSize)
    }
}

@Test func relocateItemRefusals() throws {
    try withTempDir { root in
        let source = try makeDataDir(root: root, "container/Documents/xwechat_files",
                                     fileSizes: [128])
        let base = root.appendingPathComponent("external", isDirectory: true)
        let target = WeChatPaths.targetDirectory(base: base, subdir: "Documents/xwechat_files")
        // 未迁移（源位不是软链）→ 拒绝
        #expect(throws: MigrationError.self) {
            try Migrator.relocateItem(source: source, newTarget: target)
        }
        // 新目标已存在（且不是当前软链指向）→ 拒绝
        try Migrator.migrateItem(source: source, target: target)
        let other = WeChatPaths.targetDirectory(base: base, subdir: "Documents/other_data")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        #expect(throws: MigrationError.self) {
            try Migrator.relocateItem(source: source, newTarget: other)
        }
    }
}

@Test func relocateItemIdempotentRetry() throws {
    try withTempDir { root in
        // 部分完成后的重试：已指向新位置的项应跳过而不是报"目标已存在"
        let source = try makeDataDir(root: root, "container/Documents/xwechat_files",
                                     fileSizes: [128])
        let oldBase = root.appendingPathComponent("external", isDirectory: true)
        try Migrator.migrateItem(
            source: source,
            target: WeChatPaths.targetDirectory(base: oldBase, subdir: "Documents/xwechat_files"))
        let newBase = root.appendingPathComponent("external2", isDirectory: true)
        let newTarget = WeChatPaths.targetDirectory(base: newBase,
                                                    subdir: "Documents/xwechat_files")
        try Migrator.relocateItem(source: source, newTarget: newTarget)
        // 再执行一次：幂等跳过，不报错、状态不变
        try Migrator.relocateItem(source: source, newTarget: newTarget)
        #expect(itemState(at: source) == .migrated)
        #expect(DiskProbe.directorySize(at: newTarget) == 128)
    }
}

@MainActor @Test func relocatePartialFailureThenRetry() async throws {
    // 模拟"转移中途出问题"：第 2 项的新目标被占位 → 第 1 项已转走、第 2 项失败。
    // 验证：数据完整（各在其位）、提示可重试；排除障碍后重试成功续传。
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WeChatMoverTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let (defaults, cleanup) = makeIsolatedDefaults()
    defer {
        try? FileManager.default.removeItem(at: root)
        cleanup()
    }

    let source1 = try makeDataDir(root: root, "container/Documents/xwechat_files",
                                  fileSizes: [128])
    let source2 = try makeDataDir(root: root, "container/Documents/app_data",
                                  fileSizes: [64])
    let oldBase = root.appendingPathComponent("external", isDirectory: true)
    try Migrator.migrateItem(
        source: source1,
        target: WeChatPaths.targetDirectory(base: oldBase, subdir: "Documents/xwechat_files"))
    try Migrator.migrateItem(
        source: source2,
        target: WeChatPaths.targetDirectory(base: oldBase, subdir: "Documents/app_data"))

    let vm = AppViewModel()
    vm.defaults = defaults
    vm.isWeChatRunning = { false }
    vm.resignRunner = { completion in completion(.success) }
    vm.signatureVerifier = { .adhoc }
    vm.containerRoot = root.appendingPathComponent("container", isDirectory: true)
    vm.targetBase = oldBase
    vm.items = [
        ItemStatus(subdir: "Documents/xwechat_files", source: source1,
                   state: .migrated, size: 128, hasBackup: true, backupSize: 128),
        ItemStatus(subdir: "Documents/app_data", source: source2,
                   state: .migrated, size: 64, hasBackup: true, backupSize: 64),
    ]

    // 第 2 项的新目标被占位 → 强制部分失败
    let newBase = root.appendingPathComponent("external2", isDirectory: true)
    let blocker = WeChatPaths.targetDirectory(base: newBase, subdir: "Documents/app_data")
    try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)

    vm.pendingRelocateBase = newBase
    vm.startRelocation()
    #expect(await waitUntil { !vm.isBusy })
    #expect(vm.lastError == nil)   // 部分失败走 outcome，不是 lastError
    // 第 1 项已在新位置，第 2 项仍在原位置，数据都完整
    #expect(itemState(at: source1) == .migrated)
    #expect(itemState(at: source2) == .migrated)
    let dest1 = try FileManager.default.destinationOfSymbolicLink(atPath: source1.path)
    #expect(dest1.hasPrefix(WeChatPaths.targetRoot(forBase: newBase).path))
    let dest2 = try FileManager.default.destinationOfSymbolicLink(atPath: source2.path)
    #expect(dest2.hasPrefix(WeChatPaths.targetRoot(forBase: oldBase).path))
    #expect(DiskProbe.directorySize(at: WeChatPaths.targetDirectory(
        base: oldBase, subdir: "Documents/app_data")) == 64)
    #expect(vm.logs.contains { $0.contains("未丢失") || $0.contains("未受影响") })

    // 排除障碍后重试：已转移项自动跳过，全部完成
    try FileManager.default.removeItem(at: blocker)
    vm.pendingRelocateBase = newBase
    vm.startRelocation()
    #expect(await waitUntil { !vm.isBusy && vm.targetBase == newBase })
    #expect(vm.lastError == nil)
    #expect(itemState(at: source2) == .migrated)
    let dest2After = try FileManager.default.destinationOfSymbolicLink(atPath: source2.path)
    #expect(dest2After.hasPrefix(WeChatPaths.targetRoot(forBase: newBase).path))
}

@MainActor @Test func relocateFlowDoubleConfirm() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WeChatMoverTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let (defaults, cleanup) = makeIsolatedDefaults()
    defer {
        try? FileManager.default.removeItem(at: root)
        cleanup()
    }

    let source1 = try makeDataDir(root: root, "container/Documents/xwechat_files",
                                  fileSizes: [128])
    let source2 = try makeDataDir(root: root, "container/Documents/app_data",
                                  fileSizes: [64])
    let oldBase = root.appendingPathComponent("external", isDirectory: true)
    try Migrator.migrateItem(
        source: source1,
        target: WeChatPaths.targetDirectory(base: oldBase, subdir: "Documents/xwechat_files"))
    try Migrator.migrateItem(
        source: source2,
        target: WeChatPaths.targetDirectory(base: oldBase, subdir: "Documents/app_data"))

    let vm = AppViewModel()
    vm.defaults = defaults
    vm.isWeChatRunning = { false }
    vm.resignRunner = { completion in completion(.success) }
    vm.signatureVerifier = { .adhoc }
    vm.containerRoot = root.appendingPathComponent("container", isDirectory: true)
    vm.targetBase = oldBase
    vm.externalDataSize = 192
    vm.items = [
        ItemStatus(subdir: "Documents/xwechat_files", source: source1,
                   state: .migrated, size: 128, hasBackup: true, backupSize: 128),
        ItemStatus(subdir: "Documents/app_data", source: source2,
                   state: .migrated, size: 64, hasBackup: true, backupSize: 64),
    ]

    // 1. 已迁移状态点「更改…」→ 第一重确认（不弹位置选择框）
    vm.chooseTarget()
    #expect(vm.activeDialog == .relocateConfirm)

    // 2. 选择与当前相同的位置 → 提示无需更改
    vm.applyRelocateSelection(oldBase)
    #expect(vm.notice?.contains("相同") == true)
    #expect(vm.pendingRelocateBase == nil)
    vm.notice = nil
    vm.activeDialog = nil

    // 3. 选择新位置 → 第二重确认
    let newBase = root.appendingPathComponent("external2", isDirectory: true)
    try FileManager.default.createDirectory(at: newBase, withIntermediateDirectories: true)
    vm.applyRelocateSelection(newBase)
    #expect(vm.pendingRelocateBase == newBase)
    #expect(vm.activeDialog == .relocateExecute)

    // 4. 确认转移 → 软链换指向、旧位置清除、targetBase 更新
    vm.confirmRelocate()
    let done = await waitUntil { !vm.isBusy && vm.targetBase == newBase }
    #expect(done)
    #expect(vm.lastError == nil)
    #expect(itemState(at: source1) == .migrated)
    #expect(itemState(at: source2) == .migrated)
    let dest1 = try FileManager.default.destinationOfSymbolicLink(atPath: source1.path)
    #expect(dest1 == WeChatPaths.targetDirectory(
        base: newBase, subdir: "Documents/xwechat_files").path)
    #expect(DiskProbe.directorySize(at: WeChatPaths.targetRoot(forBase: newBase)) == 192)
    #expect(!FileManager.default.fileExists(
        atPath: WeChatPaths.targetDirectory(base: oldBase,
                                            subdir: "Documents/xwechat_files").path))
    #expect(defaults.string(forKey: DefaultsKey.targetBasePath) == newBase.path)
}

// MARK: - 不转移：改指新位置 / 仅改记录

@Test func repointItemSwitchesWithoutCopy() throws {
    try withTempDir { root in
        let source = try makeDataDir(root: root, "container/Documents/xwechat_files",
                                     fileSizes: [128])
        let oldBase = root.appendingPathComponent("external", isDirectory: true)
        let oldTarget = WeChatPaths.targetDirectory(
            base: oldBase, subdir: "Documents/xwechat_files")
        try Migrator.migrateItem(source: source, target: oldTarget)

        // 新位置已有数据（用户自己拷的）
        let newBase = root.appendingPathComponent("external2", isDirectory: true)
        let newTarget = WeChatPaths.targetDirectory(
            base: newBase, subdir: "Documents/xwechat_files")
        try FileManager.default.createDirectory(at: newTarget, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: newTarget.appendingPathComponent("f.bin"))

        try Migrator.repointItem(source: source, newTarget: newTarget)
        let dest = try FileManager.default.destinationOfSymbolicLink(atPath: source.path)
        #expect(dest == newTarget.path)
        // 旧位置数据保留不删
        #expect(FileManager.default.fileExists(atPath: oldTarget.path))

        // 幂等：已指向新位置则跳过
        try Migrator.repointItem(source: source, newTarget: newTarget)

        // 新位置无数据 → 拒绝
        let missingTarget = WeChatPaths.targetDirectory(
            base: root.appendingPathComponent("empty", isDirectory: true),
            subdir: "Documents/xwechat_files")
        #expect(throws: MigrationError.self) {
            try Migrator.repointItem(source: source, newTarget: missingTarget)
        }
        // 拒绝后指向未变
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: source.path)
            == newTarget.path)
    }
}

@MainActor @Test func repointFlowFullSuccess() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WeChatMoverTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let (defaults, cleanup) = makeIsolatedDefaults()
    defer {
        try? FileManager.default.removeItem(at: root)
        cleanup()
    }

    let source1 = try makeDataDir(root: root, "container/Documents/xwechat_files",
                                  fileSizes: [128])
    let source2 = try makeDataDir(root: root, "container/Documents/app_data",
                                  fileSizes: [64])
    let oldBase = root.appendingPathComponent("external", isDirectory: true)
    try Migrator.migrateItem(
        source: source1,
        target: WeChatPaths.targetDirectory(base: oldBase, subdir: "Documents/xwechat_files"))
    try Migrator.migrateItem(
        source: source2,
        target: WeChatPaths.targetDirectory(base: oldBase, subdir: "Documents/app_data"))

    // 新位置已有两项完整数据（用户自行拷入）
    let newBase = root.appendingPathComponent("external2", isDirectory: true)
    for subdir in ["Documents/xwechat_files", "Documents/app_data"] {
        let t = WeChatPaths.targetDirectory(base: newBase, subdir: subdir)
        try FileManager.default.createDirectory(at: t, withIntermediateDirectories: true)
        try Data([9]).write(to: t.appendingPathComponent("f.bin"))
    }

    let vm = AppViewModel()
    vm.defaults = defaults
    vm.isWeChatRunning = { false }
    vm.isAppBundleWritable = { true }
    final class Flag: @unchecked Sendable { var value = false }
    let resigned = Flag()
    vm.resignRunner = { completion in resigned.value = true; completion(.success) }
    vm.signatureVerifier = { .adhoc }
    vm.containerRoot = root.appendingPathComponent("container", isDirectory: true)
    vm.targetBase = oldBase
    vm.items = [
        ItemStatus(subdir: "Documents/xwechat_files", source: source1,
                   state: .migrated, size: 128, hasBackup: true, backupSize: 128),
        ItemStatus(subdir: "Documents/app_data", source: source2,
                   state: .migrated, size: 64, hasBackup: true, backupSize: 64),
    ]

    // 选新位置 → 弹「改指 / 只改记录」选择框，预检两项都在
    vm.applyNoTransferSelection(newBase)
    #expect(vm.activeDialog == .repointChoice)
    #expect(vm.pendingRepointPresent == 2)
    #expect(vm.pendingRepointMissing == 0)

    // 直接改指：软链换指向、旧数据保留、targetBase 更新、触发重签名
    vm.confirmRepoint()
    #expect(await waitUntil { !vm.isBusy && vm.targetBase == newBase })
    #expect(vm.lastError == nil)
    for (source, subdir) in [(source1, "Documents/xwechat_files"), (source2, "Documents/app_data")] {
        let dest = try FileManager.default.destinationOfSymbolicLink(atPath: source.path)
        #expect(dest == WeChatPaths.targetDirectory(base: newBase, subdir: subdir).path)
        // 旧位置数据保留未删
        #expect(FileManager.default.fileExists(
            atPath: WeChatPaths.targetDirectory(base: oldBase, subdir: subdir).path))
    }
    #expect(defaults.string(forKey: DefaultsKey.targetBasePath) == newBase.path)
    #expect(await waitUntil { resigned.value })
    #expect(vm.notice?.contains("旧位置数据原样保留") == true)
}

@MainActor @Test func repointFlowSkipsMissingKeepsRecord() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WeChatMoverTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let (defaults, cleanup) = makeIsolatedDefaults()
    defer {
        try? FileManager.default.removeItem(at: root)
        cleanup()
    }

    let source1 = try makeDataDir(root: root, "container/Documents/xwechat_files",
                                  fileSizes: [128])
    let source2 = try makeDataDir(root: root, "container/Documents/app_data",
                                  fileSizes: [64])
    let oldBase = root.appendingPathComponent("external", isDirectory: true)
    try Migrator.migrateItem(
        source: source1,
        target: WeChatPaths.targetDirectory(base: oldBase, subdir: "Documents/xwechat_files"))
    try Migrator.migrateItem(
        source: source2,
        target: WeChatPaths.targetDirectory(base: oldBase, subdir: "Documents/app_data"))

    // 新位置只有第 1 项数据，第 2 项缺失
    let newBase = root.appendingPathComponent("external2", isDirectory: true)
    let t1 = WeChatPaths.targetDirectory(base: newBase, subdir: "Documents/xwechat_files")
    try FileManager.default.createDirectory(at: t1, withIntermediateDirectories: true)
    try Data([9]).write(to: t1.appendingPathComponent("f.bin"))

    let vm = AppViewModel()
    vm.defaults = defaults
    vm.isWeChatRunning = { false }
    vm.isAppBundleWritable = { true }
    vm.resignRunner = { completion in completion(.success) }
    vm.signatureVerifier = { .adhoc }
    vm.containerRoot = root.appendingPathComponent("container", isDirectory: true)
    vm.targetBase = oldBase
    vm.items = [
        ItemStatus(subdir: "Documents/xwechat_files", source: source1,
                   state: .migrated, size: 128, hasBackup: true, backupSize: 128),
        ItemStatus(subdir: "Documents/app_data", source: source2,
                   state: .migrated, size: 64, hasBackup: true, backupSize: 64),
    ]

    vm.applyNoTransferSelection(newBase)
    #expect(vm.pendingRepointPresent == 1)
    #expect(vm.pendingRepointMissing == 1)
    #expect(vm.repointChoiceMessage.contains("缺少 1 项"))

    vm.confirmRepoint()
    #expect(await waitUntil { !vm.isBusy && vm.notice != nil })
    // 第 1 项已改指，第 2 项保持原指向；记录维持原位置
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: source1.path)
        == t1.path)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: source2.path)
        == WeChatPaths.targetDirectory(base: oldBase, subdir: "Documents/app_data").path)
    #expect(vm.targetBase == oldBase)
    #expect(vm.notice?.contains("未找到数据") == true)
}

@MainActor @Test func recordOnlyUpdatesTargetWithoutTouchingData() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WeChatMoverTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let (defaults, cleanup) = makeIsolatedDefaults()
    defer {
        try? FileManager.default.removeItem(at: root)
        cleanup()
    }

    let source = try makeDataDir(root: root, "container/Documents/xwechat_files",
                                 fileSizes: [128])
    let oldBase = root.appendingPathComponent("external", isDirectory: true)
    let oldTarget = WeChatPaths.targetDirectory(
        base: oldBase, subdir: "Documents/xwechat_files")
    try Migrator.migrateItem(source: source, target: oldTarget)

    let vm = AppViewModel()
    vm.defaults = defaults
    vm.isWeChatRunning = { false }
    vm.containerRoot = root.appendingPathComponent("container", isDirectory: true)
    vm.targetBase = oldBase
    vm.items = [
        ItemStatus(subdir: "Documents/xwechat_files", source: source,
                   state: .migrated, size: 128, hasBackup: true, backupSize: 128),
    ]

    let newBase = root.appendingPathComponent("external2", isDirectory: true)
    try FileManager.default.createDirectory(at: newBase, withIntermediateDirectories: true)
    vm.applyNoTransferSelection(newBase)
    #expect(vm.activeDialog == .repointChoice)
    #expect(vm.pendingRepointPresent == 0)   // 新位置没数据
    #expect(vm.repointChoiceMessage.contains("未检测到微信数据"))

    vm.confirmRecordOnly()
    // 只改记录：targetBase 与持久化更新，软链保持原指向，数据不动
    #expect(vm.targetBase == newBase)
    #expect(defaults.string(forKey: DefaultsKey.targetBasePath) == newBase.path)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: source.path)
        == oldTarget.path)
    #expect(vm.logs.contains { $0.contains("未改动任何数据与链接") })
}

// MARK: - 直接使用外置已有数据（收养）

@Test func adoptExternalItemSuccess() throws {
    try withTempDir { root in
        let source = try makeDataDir(root: root, "container/Documents/xwechat_files",
                                     fileSizes: [128])
        let base = root.appendingPathComponent("external", isDirectory: true)
        let target = WeChatPaths.targetDirectory(base: base, subdir: "Documents/xwechat_files")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        // 外置已有数据的标记文件
        try Data(repeating: 9, count: 64).write(to: target.appendingPathComponent("old-marker.bin"))

        try Migrator.adoptExternalItem(source: source, target: target)

        #expect(itemState(at: source) == .migrated)
        #expect(FileManager.default.fileExists(
            atPath: WeChatPaths.backupDirectory(for: source).path))   // 本地数据转为备份
        // 未发生拷贝：外置内容保持原样（标记文件在，源数据没盖过去）
        #expect(FileManager.default.fileExists(
            atPath: target.appendingPathComponent("old-marker.bin").path))
        #expect(DiskProbe.directorySize(at: target) == 64)
    }
}

@Test func adoptExternalItemRefusals() throws {
    try withTempDir { root in
        let source = try makeDataDir(root: root, "container/Documents/xwechat_files",
                                     fileSizes: [128])
        let base = root.appendingPathComponent("external", isDirectory: true)
        let target = WeChatPaths.targetDirectory(base: base, subdir: "Documents/xwechat_files")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        // 目标不存在
        #expect(throws: MigrationError.self) {
            try Migrator.adoptExternalItem(
                source: source, target: base.appendingPathComponent("WeChatData/nope"))
        }
        // _backup 已存在（中断残留）→ 拒绝，源目录不动
        _ = try makeDataDir(root: root, "container/Documents/xwechat_files_backup",
                            fileSizes: [32])
        #expect(throws: MigrationError.self) {
            try Migrator.adoptExternalItem(source: source, target: target)
        }
        #expect(itemState(at: source) == .interrupted)   // 有 _backup 残留，状态不变
    }
}

@MainActor @Test func migrationAdoptConflictFlow() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WeChatMoverTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let source1 = try makeDataDir(root: root, "container/Documents/xwechat_files",
                                  fileSizes: [128])
    let source2 = try makeDataDir(root: root, "container/Documents/app_data",
                                  fileSizes: [64])
    let base = root.appendingPathComponent("external", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    // 两项外置都已有数据，各放一个标记文件证明没被拷贝覆盖
    let t1 = WeChatPaths.targetDirectory(base: base, subdir: "Documents/xwechat_files")
    let t2 = WeChatPaths.targetDirectory(base: base, subdir: "Documents/app_data")
    try FileManager.default.createDirectory(at: t1, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: t2, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 16).write(to: t1.appendingPathComponent("old1.bin"))
    try Data(repeating: 2, count: 16).write(to: t2.appendingPathComponent("old2.bin"))

    let vm = AppViewModel()
    vm.isWeChatRunning = { false }
    vm.resignRunner = { completion in completion(.success) }
    vm.containerRoot = root.appendingPathComponent("container", isDirectory: true)
    vm.targetBase = base
    vm.items = [
        ItemStatus(subdir: "Documents/xwechat_files", source: source1,
                   state: .local, size: 128, hasBackup: false, backupSize: 0),
        ItemStatus(subdir: "Documents/app_data", source: source2,
                   state: .local, size: 64, hasBackup: false, backupSize: 0),
    ]

    vm.startMigration()
    #expect(await waitUntil { vm.showExistingTargetConfirm })
    #expect(vm.conflictingTargetPaths.count == 2)

    // 选「直接使用外置数据」：两项都变已迁移，不再弹窗，外置内容未被覆盖
    vm.adoptExistingTargetsAndMigrate()
    let done = await waitUntil {
        !vm.isBusy && itemState(at: source1) == .migrated && itemState(at: source2) == .migrated
    }
    #expect(done)
    #expect(vm.lastError == nil)
    #expect(!vm.showExistingTargetConfirm)
    #expect(FileManager.default.fileExists(atPath: t1.appendingPathComponent("old1.bin").path))
    #expect(FileManager.default.fileExists(atPath: t2.appendingPathComponent("old2.bin").path))
    // 本地数据转为 _backup
    #expect(FileManager.default.fileExists(
        atPath: WeChatPaths.backupDirectory(for: source1).path))
    #expect(FileManager.default.fileExists(
        atPath: WeChatPaths.backupDirectory(for: source2).path))
}

@MainActor @Test func resignAppManagementDeniedShowsGuide() async {
    let vm = AppViewModel()
    vm.isAppBundleWritable = { true }
    vm.resignRunner = { completion in
        completion(.appManagementDenied("Operation not permitted"))
    }
    vm.resignWeChat()
    #expect(await waitUntil { vm.showAppManagementGuide })
    #expect(vm.resignGuideReason == .appManagementDenied)
    #expect(!vm.isResigning)
    #expect(vm.lastError == nil)   // 不算普通失败，走专属指引
    #expect(vm.logs.contains { $0.contains("App 管理") })
}

@MainActor @Test func resignNotWritableShowsTerminalFallback() async {
    let vm = AppViewModel()
    var runnerCalled = false
    vm.isAppBundleWritable = { false }   // 包所有者不是当前用户
    vm.resignRunner = { _ in runnerCalled = true }
    vm.resignWeChat()
    // 直接弹终端 sudo 兜底指引，不启动 codesign
    #expect(vm.showAppManagementGuide)
    #expect(vm.resignGuideReason == .notWritable)
    #expect(!vm.isResigning)
    #expect(!runnerCalled)
    #expect(vm.logs.contains { $0.contains("不可写") })
}

@MainActor @Test func resignSuccessVerifiesSignature() async {
    let vm = AppViewModel()
    vm.isAppBundleWritable = { true }
    vm.resignRunner = { completion in completion(.success) }
    vm.signatureVerifier = { .adhoc }   // 不扫真实 App
    vm.resignWeChat()
    #expect(await waitUntil { vm.wechat.signature == .adhoc })
    #expect(!vm.isResigning)
    #expect(vm.logs.contains { $0.contains("签名有效") })
}

// MARK: - 签名状态三态检测（adhoc / 官方签名 / 失效）

@Test func adhocDescribeOutputParsing() {
    // ad-hoc 签名（本工具重签后）：Signature=adhoc / flags=0x2(adhoc)
    let adhoc = """
    Executable=/Applications/WeChat.app/Contents/MacOS/WeChat
    Identifier=com.tencent.xinWeChat
    CodeDirectory v=20400 size=13998 flags=0x2(adhoc) hashes=431+3 location=embedded
    Signature=adhoc
    TeamIdentifier=not set
    """
    #expect(WeChatDetector.isAdhocDescribeOutput(adhoc))

    // 官方签名（微信更新后恢复）：有 Authority/TeamIdentifier，无 adhoc 标记
    let official = """
    Identifier=com.tencent.xinWeChat
    CodeDirectory v=20400 size=13998 flags=0x0(none) hashes=431+3 location=embedded
    Authority=Developer ID Application: Tencent Technology (Shenzhen) Company Limited (88L2Q4487U)
    TeamIdentifier=88L2Q4487U
    """
    #expect(!WeChatDetector.isAdhocDescribeOutput(official))
    #expect(!WeChatDetector.isAdhocDescribeOutput(""))
}

/// 未签名 fixture → broken；ad-hoc 重签后 → adhoc（真实 codesign，只碰临时目录）。
@Test func signatureStatusOnFixtureApp() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WeChatMoverTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let app = try makeSignableFixtureApp(root: root)

    #expect(WeChatDetector.signatureStatus(appURL: app) == .broken)   // 未签名

    let result: CodeSigner.ResignResult = await withCheckedContinuation { cont in
        CodeSigner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--sign", "-", "--force", "--deep", app.path]
        ) { cont.resume(returning: $0) }
    }
    #expect(result == .success)
    #expect(WeChatDetector.signatureStatus(appURL: app) == .adhoc)
}

@MainActor @Test func checkSignatureNowAppliesStatus() async {
    let vm = AppViewModel()
    vm.wechat.isInstalled = true
    vm.signatureVerifier = { .validOfficial }   // 不扫真实 App
    vm.checkSignatureNow()
    #expect(await waitUntil { vm.wechat.signature == .validOfficial })
}

/// 官方签名 + 已迁移数据 → 安全检查提示需重新签名；未迁移则是正常态。
@MainActor @Test func officialSignatureOnlyFlaggedWhenMigrated() {
    let source = URL(fileURLWithPath: "/tmp/fixture-xwechat_files")
    let vm = AppViewModel()
    vm.wechat.isInstalled = true
    vm.wechat.signature = .validOfficial
    vm.items = [ItemStatus(subdir: "Documents/xwechat_files", source: source,
                           state: .migrated, size: 1, hasBackup: false, backupSize: 0)]
    #expect(vm.safetyIssues.contains { $0.contains("官方签名") })
    #expect(vm.signatureDisplayText.contains("需重新签名"))

    vm.items = [ItemStatus(subdir: "Documents/xwechat_files", source: source,
                           state: .local, size: 1, hasBackup: false, backupSize: 0)]
    #expect(!vm.safetyIssues.contains { $0.contains("官方签名") })
    #expect(vm.signatureDisplayText == "官方签名")
}

/// 重签后复核仍是官方签名（签名没生效）→ 日志提示重试，不算成功。
@MainActor @Test func resignVerifyOfficialSignatureWarns() async {
    let vm = AppViewModel()
    vm.isAppBundleWritable = { true }
    vm.resignRunner = { completion in completion(.success) }
    vm.signatureVerifier = { .validOfficial }
    vm.resignWeChat()
    #expect(await waitUntil { !vm.isResigning && vm.wechat.signature == .validOfficial })
    #expect(vm.logs.contains { $0.contains("仍是官方签名") })
    #expect(!vm.logs.contains { $0.contains("复核通过") })
}

// MARK: - 真实 codesign 直签（只签临时目录 fixture，不碰真实微信）

/// 造一个可签名的最小 .app（Info.plist + 主可执行文件）。
private func makeSignableFixtureApp(root: URL) throws -> URL {
    let contents = root.appendingPathComponent("Mini.app/Contents", isDirectory: true)
    let macos = contents.appendingPathComponent("MacOS", isDirectory: true)
    try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
    try NSDictionary(dictionary: [
        "CFBundleExecutable": "Mini",
        "CFBundleIdentifier": "com.example.mini",
        "CFBundleShortVersionString": "1.0",
    ]).write(to: contents.appendingPathComponent("Info.plist"))
    let exe = macos.appendingPathComponent("Mini")
    try "#!/bin/sh\nexit 0\n".write(to: exe, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
    return root.appendingPathComponent("Mini.app")
}

/// 验证本次修复的核心前提：不提权直接 codesign ad-hoc 重签 + 复核通过。
@Test func resignFixtureAppDirectly() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WeChatMoverTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let app = try makeSignableFixtureApp(root: root)

    let result: CodeSigner.ResignResult = await withCheckedContinuation { cont in
        CodeSigner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--sign", "-", "--force", "--deep", app.path]
        ) { cont.resume(returning: $0) }
    }
    #expect(result == .success)
    #expect(WeChatDetector.checkSignature(appURL: app))   // codesign -v 复核通过
}

// MARK: - 清理外置数据：安全校验（纯逻辑 + fixture）

@Test func externalDataPathValidation() {
    let base = URL(fileURLWithPath: "/Volumes/Ext/MyFolder", isDirectory: true)
    #expect(AppViewModel.isExternalDataPathValid(
        "/Volumes/Ext/MyFolder/WeChatData", base: base))
    // 目标目录外/形态不符一律拒绝
    #expect(!AppViewModel.isExternalDataPathValid(
        "/Volumes/Ext/MyFolder", base: base))
    #expect(!AppViewModel.isExternalDataPathValid(
        "/Volumes/Ext/MyFolder/WeChatData/xwechat_files", base: base))
    #expect(!AppViewModel.isExternalDataPathValid(
        "/Volumes/Ext/Other/WeChatData", base: base))
    #expect(!AppViewModel.isExternalDataPathValid("/etc", base: base))
}

@Test func externalDataInUseDetection() throws {
    try withTempDir { root in
        let base = root.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let dataRoot = WeChatPaths.targetRoot(forBase: base)

        // 已迁移：源位软链 → WeChatData 内部
        let migratedSource = try makeDataDir(root: root, "c/Documents/xwechat_files")
        try Migrator.migrateItem(
            source: migratedSource,
            target: WeChatPaths.targetDirectory(base: base, subdir: "Documents/xwechat_files"))
        let migratedItem = ItemStatus(
            subdir: "Documents/xwechat_files", source: migratedSource,
            state: .migrated, size: 0, hasBackup: true, backupSize: 0)
        #expect(AppViewModel.isExternalDataInUse(items: [migratedItem], dataRoot: dataRoot))

        // 本地（未迁移）目录不算使用
        let localSource = try makeDataDir(root: root, "c/Documents/app_data")
        let localItem = ItemStatus(
            subdir: "Documents/app_data", source: localSource,
            state: .local, size: 0, hasBackup: false, backupSize: 0)
        #expect(!AppViewModel.isExternalDataInUse(items: [localItem], dataRoot: dataRoot))
        #expect(!AppViewModel.isExternalDataInUse(items: [], dataRoot: dataRoot))

        // 指向别处的软链不算使用
        let elsewhere = root.appendingPathComponent("elsewhere_link")
        try FileManager.default.createSymbolicLink(
            at: elsewhere, withDestinationURL: root.appendingPathComponent("c"))
        let otherItem = ItemStatus(
            subdir: "elsewhere", source: elsewhere,
            state: .migrated, size: 0, hasBackup: false, backupSize: 0)
        #expect(!AppViewModel.isExternalDataInUse(items: [otherItem], dataRoot: dataRoot))

        // 软链指向 WeChatData 但目标不可达（外置盘未插）仍算使用
        let broken = root.appendingPathComponent("broken_link")
        try FileManager.default.createSymbolicLink(
            at: broken, withDestinationURL: dataRoot.appendingPathComponent("gone"))
        let brokenItem = ItemStatus(
            subdir: "broken", source: broken,
            state: .brokenSymlink, size: 0, hasBackup: false, backupSize: 0)
        #expect(AppViewModel.isExternalDataInUse(items: [brokenItem], dataRoot: dataRoot))
    }
}

// MARK: - 清理外置数据：完整流程（临时目录 fixture）

@MainActor @Test func cleanExternalDataRefusedWhenInUse() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WeChatMoverTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let source = try makeDataDir(root: root, "container/Documents/xwechat_files",
                                 fileSizes: [128])
    let base = root.appendingPathComponent("external", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    try Migrator.migrateItem(
        source: source,
        target: WeChatPaths.targetDirectory(base: base, subdir: "Documents/xwechat_files"))

    let vm = AppViewModel()
    vm.containerRoot = root.appendingPathComponent("container", isDirectory: true)
    vm.targetBase = base
    vm.items = [ItemStatus(subdir: "Documents/xwechat_files", source: source,
                           state: .migrated, size: 128, hasBackup: true, backupSize: 128)]

    // 迁移中 → 按钮置灰；直接调用也仍被拒绝（防御性校验保留），弹中性提示
    #expect(!vm.canCleanExternalData)
    vm.requestCleanExternalData()
    #expect(vm.notice?.contains("仍在使用中") == true)
    #expect(!vm.showCleanExternalConfirm)
    #expect(FileManager.default.fileExists(
        atPath: WeChatPaths.targetRoot(forBase: base).path))
}

@MainActor @Test func cleanExternalDataFlow() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WeChatMoverTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    // 先迁移再还原：源位恢复本地，外置 WeChatData 保留（典型清理场景）
    let source = try makeDataDir(root: root, "container/Documents/xwechat_files",
                                 fileSizes: [128, 256])
    let base = root.appendingPathComponent("external", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let target = WeChatPaths.targetDirectory(base: base, subdir: "Documents/xwechat_files")
    try Migrator.migrateItem(source: source, target: target)
    try Migrator.restoreItem(source: source, target: target)
    #expect(itemState(at: source) == .local)

    let vm = AppViewModel()
    vm.containerRoot = root.appendingPathComponent("container", isDirectory: true)
    vm.targetBase = base
    vm.items = [ItemStatus(subdir: "Documents/xwechat_files", source: source,
                           state: .local, size: 384, hasBackup: false, backupSize: 0)]

    // 1. 统计大小 → 弹二次确认框
    vm.requestCleanExternalData()
    #expect(await waitUntil { vm.showCleanExternalConfirm })
    #expect(vm.externalDataSize == 384)
    #expect(vm.notice == nil && vm.lastError == nil)
    #expect(FileManager.default.fileExists(atPath: target.path))   // 尚未删除

    // 2. 确认删除 → WeChatData 整体移除，日志显示释放空间
    vm.cleanExternalData()
    #expect(await waitUntil { !vm.isBusy })
    #expect(!FileManager.default.fileExists(
        atPath: WeChatPaths.targetRoot(forBase: base).path))
    #expect(vm.lastError == nil)
    #expect(vm.logs.contains { $0.contains("释放空间") })
}

// MARK: - 展示层映射（AppStatus → 横幅/卡片，纯展示逻辑）

@MainActor
private func makePresentationVM() -> AppViewModel {
    let vm = AppViewModel()
    vm.wechat.isInstalled = true
    vm.containerReadable = true
    vm.sizesLoaded = true
    vm.targetBase = URL(fileURLWithPath: "/Volumes/Ext/test", isDirectory: true)
    vm.targetFSType = "apfs"
    vm.targetFreeSpace = 1_000_000_000
    vm.items = [ItemStatus(subdir: "Documents/xwechat_files",
                           source: URL(fileURLWithPath: "/tmp/c/Documents/xwechat_files"),
                           state: .local, size: 100_000_000,
                           hasBackup: false, backupSize: 0)]
    return vm
}

@MainActor @Test func bannerReady() {
    let vm = makePresentationVM()
    #expect(vm.appStatus == .ready)
    #expect(vm.banner.tone == .success)
    #expect(vm.banner.title == "可以开始迁移")
    #expect(vm.primaryActionTitle == "迁移到外置硬盘")
    // 三张摘要卡片：数据 / 目标磁盘 / 安全检查
    #expect(vm.summaryCards.map(\.id) == ["data", "destination", "safety"])
    #expect(vm.summaryCards[2].value == "全部通过")
}

@MainActor @Test func bannerBlockedReasons() {
    // 未选目标
    let noDest = AppViewModel()
    noDest.wechat.isInstalled = true
    noDest.items = makePresentationVM().items
    #expect(noDest.appStatus == .blocked(.noDestination))
    #expect(noDest.banner.fix == .chooseDestination)

    // 无容器权限（优先级高于未选目标）
    let noPerm = makePresentationVM()
    noPerm.containerReadable = false
    #expect(noPerm.appStatus == .blocked(.containerUnreadable))
    #expect(noPerm.banner.fix == .openFullDiskAccess)

    // 非 APFS：不禁止，ready 状态 + 警示横幅 + 迁移按钮可用
    let exfat = makePresentationVM()
    exfat.targetFSType = "exfat"
    #expect(exfat.appStatus == .ready)
    #expect(exfat.banner.tone == .warning)
    #expect(exfat.banner.message.contains("APFS"))
    #expect(exfat.canMigrate)
    #expect(exfat.migrateConfirmMessage.contains("⚠️"))

    // 空间不足
    let tight = makePresentationVM()
    tight.targetFreeSpace = 50_000_000
    #expect(tight.appStatus == .blocked(.insufficientSpace(need: 100_000_000, free: 50_000_000)))
    #expect(tight.banner.title == "目标磁盘空间不足")

    // App Store 版
    let mas = makePresentationVM()
    mas.wechat.isAppStoreVersion = true
    #expect(mas.appStatus == .blocked(.appStoreVersion))
    #expect(mas.banner.fix == .openOfficialDownload)
}

@MainActor @Test func bannerExternalized() {
    let vm = makePresentationVM()
    vm.items = [ItemStatus(subdir: "Documents/xwechat_files",
                           source: URL(fileURLWithPath: "/tmp/c/Documents/xwechat_files"),
                           state: .migrated, size: 100_000_000,
                           hasBackup: false, backupSize: 0)]
    #expect(vm.appStatus == .externalized)
    #expect(vm.banner.tone == .success)
    #expect(vm.banner.title == "微信数据已在外置硬盘")
    #expect(vm.primaryActionTitle == "更新迁移")   // 有部分外置时主按钮文案
}

@MainActor @Test func bannerBusyAndOutcome() {
    let vm = makePresentationVM()
    // 迁移中：横幅带真实字节进度
    vm.busyKind = .migrating
    vm.progress = 0.42
    #expect(vm.appStatus == .busy(.migrating, progress: 0.42))
    #expect(vm.banner.title == "正在迁移… 42%")
    #expect(vm.banner.progress == 0.42)

    // 成功
    vm.busyKind = nil
    vm.migrationOutcome = .succeeded(items: 1, bytes: 100_000_000)
    guard case .succeeded = vm.appStatus else {
        Issue.record("应为 succeeded"); return
    }
    #expect(vm.banner.tone == .success)
    #expect(vm.banner.title == "迁移完成")

    // 失败：横幅给出重试动作，不走泛化错误弹窗
    vm.migrationOutcome = .failed("目标硬盘已断开")
    #expect(vm.appStatus == .failed("目标硬盘已断开"))
    #expect(vm.banner.tone == .danger)
    #expect(vm.banner.fix == .retryMigration)
}

// MARK: - 文案与日志展示映射

@Test func copywritingHumanNames() {
    #expect(Copywriting.itemName("Documents/xwechat_files") == "微信聊天文件")
    #expect(Copywriting.itemName("Documents/app_data") == "微信应用数据")
    #expect(Copywriting.itemName("Library/Application Support/com.tencent.xinWeChat") == "微信兼容数据")
    #expect(Copywriting.itemName("other") == "other")
    #expect(Copywriting.sourceName(isAppStoreVersion: false) == "官网下载版")
}

@Test func logLineParsing() {
    let ok = LogPresentation.parse("[13:49:07] ✅ 已迁移：xwechat_files")
    #expect(ok.tone == .success)
    #expect(ok.symbol == "checkmark.circle.fill")
    #expect(!ok.text.contains("✅"))

    #expect(LogPresentation.parse("[t] ⚠️ 跳过").tone == .warning)
    #expect(LogPresentation.parse("[t] ❌ 失败").tone == .danger)
    let plain = LogPresentation.parse("[13:49:07] 开始迁移")
    #expect(plain.tone == .neutral)
    #expect(plain.text == "[13:49:07] 开始迁移")
}

// MARK: - 还原内置备份（Migrator 层，不访问外置盘）

@Test func restoreFromBackupOnly() throws {
    try withTempDir { root in
        let source = try makeDataDir(root: root, "container/Documents/xwechat_files",
                                     fileSizes: [256])
        let base = root.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let target = WeChatPaths.targetDirectory(base: base, subdir: "Documents/xwechat_files")
        try Migrator.migrateItem(source: source, target: target)

        try Migrator.restoreFromBackup(source: source)
        #expect(itemState(at: source) == .local)
        #expect(DiskProbe.directorySize(at: source) == 256)
        #expect(!FileManager.default.fileExists(
            atPath: WeChatPaths.backupDirectory(for: source).path))
        #expect(FileManager.default.fileExists(atPath: target.path))   // 外置数据保留不动
    }
}

@Test func restoreFromBackupRefusals() throws {
    try withTempDir { root in
        // 非软链 → notMigrated
        let local = try makeDataDir(root: root, "c/Documents/app_data")
        #expect {
            try Migrator.restoreFromBackup(source: local)
        } throws: { error in
            guard case MigrationError.notMigrated = error else { return false }
            return true
        }

        // 软链但无 _backup → backupMissing（应改用完整还原）
        let source = root.appendingPathComponent("c2/Documents/xwechat_files")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: source, withDestinationURL: root.appendingPathComponent("c"))
        #expect {
            try Migrator.restoreFromBackup(source: source)
        } throws: { error in
            guard case MigrationError.backupMissing = error else { return false }
            return true
        }
    }
}

// MARK: - 清理外置数据按钮可用性收紧

@MainActor @Test func cleanExternalButtonAvailability() throws {
    try withTempDir { root in
        let source = try makeDataDir(root: root, "container/Documents/xwechat_files",
                                     fileSizes: [128])
        let base = root.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let target = WeChatPaths.targetDirectory(base: base, subdir: "Documents/xwechat_files")
        try Migrator.migrateItem(source: source, target: target)

        let vm = AppViewModel()
        vm.targetBase = base
        vm.items = [ItemStatus(subdir: "Documents/xwechat_files", source: source,
                               state: .migrated, size: 128, hasBackup: true, backupSize: 128)]
        // 已迁移（软链仍指向外置）→ 置灰
        #expect(vm.hasExternalData)
        #expect(!vm.canCleanExternalData)

        // 还原后（无软链指向外置）→ 点亮
        try Migrator.restoreItem(source: source, target: target)
        vm.items = [ItemStatus(subdir: "Documents/xwechat_files", source: source,
                               state: .local, size: 128, hasBackup: false, backupSize: 0)]
        #expect(vm.canCleanExternalData)
    }
}

// MARK: - 还原/还原内置备份的退微信流程（注入假 quitter，不碰真实微信）

private final class RunningFlag: @unchecked Sendable { var value = true }
private final class CallFlag: @unchecked Sendable { var value = false }

@MainActor @Test func confirmRestoreQuitsWeChatFirst() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WeChatMoverTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let source = try makeDataDir(root: root, "container/Documents/xwechat_files",
                                 fileSizes: [128])
    let base = root.appendingPathComponent("external", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    try Migrator.migrateItem(
        source: source,
        target: WeChatPaths.targetDirectory(base: base, subdir: "Documents/xwechat_files"))

    let running = RunningFlag()
    let quitterCalled = CallFlag()
    let vm = AppViewModel()
    vm.isWeChatRunning = { running.value }
    vm.wechatQuitter = { quitterCalled.value = true; running.value = false; return true }
    vm.resignRunner = { completion in completion(.success) }
    vm.signatureVerifier = { .adhoc }
    vm.containerRoot = root.appendingPathComponent("container", isDirectory: true)
    vm.targetBase = base
    vm.wechat.isRunning = true   // 微信运行中
    vm.items = [ItemStatus(subdir: "Documents/xwechat_files", source: source,
                           state: .migrated, size: 128, hasBackup: true, backupSize: 128)]

    // 运行中不再禁用还原
    #expect(vm.canRestore)
    vm.confirmRestore()
    let restored = await waitUntil { itemState(at: source) == .local && !vm.isBusy }
    #expect(restored)
    #expect(quitterCalled.value)                   // 先退了微信
    #expect(vm.logs.contains { $0.contains("已还原") })
}

@MainActor @Test func restoreBackupsFlow() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WeChatMoverTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let source = try makeDataDir(root: root, "container/Documents/xwechat_files",
                                 fileSizes: [128, 256])
    let base = root.appendingPathComponent("external", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let target = WeChatPaths.targetDirectory(base: base, subdir: "Documents/xwechat_files")
    try Migrator.migrateItem(source: source, target: target)

    let vm = AppViewModel()
    vm.isWeChatRunning = { false }
    vm.resignRunner = { completion in completion(.success) }
    vm.signatureVerifier = { .adhoc }
    vm.containerRoot = root.appendingPathComponent("container", isDirectory: true)
    vm.targetBase = base
    vm.items = [ItemStatus(subdir: "Documents/xwechat_files", source: source,
                           state: .migrated, size: 384, hasBackup: true, backupSize: 384)]

    #expect(vm.canRestoreBackups)
    vm.confirmRestoreBackups()
    let restored = await waitUntil { itemState(at: source) == .local && !vm.isBusy }
    #expect(restored)
    #expect(!FileManager.default.fileExists(
        atPath: WeChatPaths.backupDirectory(for: source).path))   // 备份已改名回原名
    #expect(FileManager.default.fileExists(atPath: target.path))  // 外置数据保留
    #expect(vm.lastError == nil)
    #expect(vm.logs.contains { $0.contains("已还原内置备份") })
}

// MARK: - 卡片图标模型（微信真实图标 / 目标磁盘微信绿）

@MainActor @Test func cardIconModels() {
    let vm = makePresentationVM()
    let cards = vm.summaryCards
    #expect(cards[0].customIcon == .weChatApp)     // 已安装 → 真实微信图标
    #expect(cards[1].iconUsesAccent)               // 目标磁盘图标用微信绿
    // 未安装 → 降级绿色 message.circle.fill
    let empty = AppViewModel()
    #expect(empty.summaryCards[0].customIcon == nil)
    #expect(empty.summaryCards[0].symbol == "message.circle.fill")
    #expect(empty.summaryCards[0].iconUsesAccent)
}

// MARK: - 仅本地备份状态（backupOnly）与主按钮切换

@MainActor @Test func backupOnlyStatePresentation() {
    let vm = AppViewModel()
    vm.wechat.isInstalled = true
    // 外置未连接：源位是断链软链，本地 _backup 有数据
    vm.items = [ItemStatus(subdir: "Documents/xwechat_files",
                           source: URL(fileURLWithPath: "/tmp/c/Documents/xwechat_files"),
                           state: .brokenSymlink, size: 0,
                           hasBackup: true, backupSize: 427_000_000)]
    #expect(vm.isBackupOnlyState)
    #expect(vm.appStatus == .backupOnly(count: 1, bytes: 427_000_000))
    #expect(vm.banner.title == "检测到本地备份")
    #expect(vm.banner.message.contains("还原内置存储数据到 Mac…"))
    // 断链软链也可恢复（restoreFromBackup 不访问外置盘）
    #expect(vm.restorableBackupItems.count == 1)
    #expect(vm.canRestoreBackups)
    #expect(vm.canDeleteBackups)   // 备份行仍可清理
    // 主按钮是「还原内置存储数据到 Mac…」
    #expect(vm.primaryAction == .restoreBackups)
}

@MainActor @Test func primaryActionSwitching() {
    let vm = AppViewModel()
    vm.wechat.isInstalled = true
    // 未迁移 → 迁移
    vm.items = [ItemStatus(subdir: "Documents/xwechat_files",
                           source: URL(fileURLWithPath: "/tmp/a"),
                           state: .local, size: 100, hasBackup: false, backupSize: 0)]
    #expect(vm.primaryAction == .migrate)
    #expect(vm.primaryActionTitle == "迁移到外置硬盘")

    // 部分外置 → 仍是迁移（更新迁移），还原降级到管理行
    vm.items.append(ItemStatus(subdir: "Documents/app_data",
                               source: URL(fileURLWithPath: "/tmp/b"),
                               state: .migrated, size: 100, hasBackup: true, backupSize: 100))
    #expect(vm.primaryAction == .migrate)
    #expect(vm.primaryActionTitle == "更新迁移")

    // 全部外置 → 还原
    vm.items = [ItemStatus(subdir: "Documents/app_data",
                           source: URL(fileURLWithPath: "/tmp/b"),
                           state: .migrated, size: 100, hasBackup: true, backupSize: 100)]
    #expect(vm.primaryAction == .restore)
    #expect(!vm.isBackupOnlyState)

    // 空状态 → 无主按钮
    vm.items = []
    #expect(vm.primaryAction == .none)
}

// MARK: - 目录指纹

@Test func fingerprintDeterministicAndOrderIndependent() throws {
    try withTempDir { root in
        let a = root.appendingPathComponent("a", isDirectory: true)
        _ = try makeDataDir(root: root, "a/sub", fileSizes: [100, 200])
        try Data(repeating: 9, count: 50).write(to: a.appendingPathComponent("top.bin"))
        // b 用 copyItem 逐个复制（保留 mtime），但创建顺序与 a 不同
        let b = root.appendingPathComponent("b")
        try FileManager.default.createDirectory(
            at: b.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: a.appendingPathComponent("top.bin"), to: b.appendingPathComponent("top.bin"))
        for i in [1, 0] {   // 反序
            try FileManager.default.copyItem(
                at: a.appendingPathComponent("sub/file\(i).bin"),
                to: b.appendingPathComponent("sub/file\(i).bin"))
        }
        let fa = Fingerprint.compute(at: a)
        let fb = Fingerprint.compute(at: b)
        #expect(fa != nil && fa == fb)                       // 顺序无关、确定性
        #expect(Fingerprint.compute(at: a) == fa)            // 重算一致
        #expect(fa?.fileCount == 3 && fa?.totalBytes == 350)
    }
}

@Test func fingerprintDetectsChanges() throws {
    try withTempDir { root in
        let dir = try makeDataDir(root: root, "data", fileSizes: [100, 200])
        let base = Fingerprint.compute(at: dir)

        // 新增文件
        try Data(repeating: 1, count: 10).write(to: dir.appendingPathComponent("new.bin"))
        #expect(Fingerprint.compute(at: dir) != base)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("new.bin"))
        #expect(Fingerprint.compute(at: dir) == base)

        // 改名（来回改回后指纹应复原：改名不改 mtime）
        try FileManager.default.moveItem(
            at: dir.appendingPathComponent("file0.bin"),
            to: dir.appendingPathComponent("renamed.bin"))
        #expect(Fingerprint.compute(at: dir) != base)
        try FileManager.default.moveItem(
            at: dir.appendingPathComponent("renamed.bin"),
            to: dir.appendingPathComponent("file0.bin"))
        #expect(Fingerprint.compute(at: dir) == base)

        // 同尺寸改写 → mtime 变化可检出
        let file = dir.appendingPathComponent("file0.bin")
        try Data(repeating: 42, count: 100).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
            ofItemAtPath: file.path)
        #expect(Fingerprint.compute(at: dir) != base)

        // 删除文件
        try FileManager.default.removeItem(at: dir.appendingPathComponent("file1.bin"))
        #expect(Fingerprint.compute(at: dir) != base)

        // 目录不存在 → nil
        #expect(Fingerprint.compute(at: root.appendingPathComponent("nope")) == nil)
    }
}

@Test func copyPreservesFingerprint() throws {
    try withTempDir { root in
        // 迁移依赖此前提：FileManager.copyItem 保留 mtime，拷贝副本指纹一致
        let dir = try makeDataDir(root: root, "origin/deep", fileSizes: [128, 256])
        let copy = root.appendingPathComponent("copy")
        try FileManager.default.copyItem(at: dir, to: copy)
        #expect(Fingerprint.compute(at: copy) == Fingerprint.compute(at: dir))
    }
}

// MARK: - 迁移清单读写

@Test func manifestRoundtrip() throws {
    try withTempDir { root in
        let base = root.appendingPathComponent("external", isDirectory: true)
        let target = try makeDataDir(root: root, "external/WeChatData/xwechat_files",
                                     fileSizes: [128])
        let fp = Fingerprint.compute(at: target)!
        let manifest = MigrationManifest(
            toolVersion: "1.0.0", migratedAt: Date(timeIntervalSince1970: 1_700_000_000),
            items: [.init(subdir: "Documents/xwechat_files", fingerprint: fp)])
        try Fingerprint.writeManifest(manifest, base: base)
        let read = Fingerprint.readManifest(base: base)
        #expect(read == manifest)
        #expect(read?.fingerprint(for: "Documents/xwechat_files") == fp)
        #expect(read?.fingerprint(for: "Documents/nope") == nil)
        // 无清单 → nil
        #expect(Fingerprint.readManifest(
            base: root.appendingPathComponent("empty")) == nil)
    }
}

// MARK: - 新旧判定（manifest 单侧快路径 / 无 manifest 双侧兜底）

@MainActor
private func makeRestoreFixture(_ root: URL) throws -> (vm: AppViewModel, source: URL, base: URL, target: URL) {
    let source = try makeDataDir(root: root, "container/Documents/xwechat_files",
                                 fileSizes: [128, 256])
    let base = root.appendingPathComponent("external", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let target = WeChatPaths.targetDirectory(base: base, subdir: "Documents/xwechat_files")
    try Migrator.migrateItem(source: source, target: target)
    let vm = AppViewModel()
    vm.isWeChatRunning = { false }
    vm.resignRunner = { completion in completion(.success) }
    vm.signatureVerifier = { .adhoc }
    vm.containerRoot = root.appendingPathComponent("container", isDirectory: true)
    vm.targetBase = base
    vm.items = [ItemStatus(subdir: "Documents/xwechat_files", source: source,
                           state: .migrated, size: 384, hasBackup: true, backupSize: 384)]
    return (vm, source, base, target)
}

private func writeManifestFor(base: URL, subdir: String, target: URL) throws {
    try Fingerprint.writeManifest(
        MigrationManifest(toolVersion: "test", migratedAt: Date(),
                          items: [.init(subdir: subdir, fingerprint: Fingerprint.compute(at: target)!)]),
        base: base)
}

@MainActor @Test func restoreDecisionSameWithManifest() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WeChatMoverTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let (vm, _, base, target) = try makeRestoreFixture(root)
    try writeManifestFor(base: base, subdir: "Documents/xwechat_files", target: target)

    vm.requestRestore()
    // 一致：提示可选内置备份（更快）或仍从外置拷贝
    #expect(await waitUntil { vm.activeDialog == .restoreSameChoice && !vm.isBusy })
}

@MainActor @Test func restoreDecisionSameWithoutManifest() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WeChatMoverTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let (vm, _, _, _) = try makeRestoreFixture(root)   // 不写 manifest → 双侧兜底

    vm.requestRestore()
    #expect(await waitUntil { vm.activeDialog == .restoreSameChoice && !vm.isBusy })
}

@MainActor @Test func restoreDecisionDiffersUsesExternal() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WeChatMoverTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let (vm, _, base, target) = try makeRestoreFixture(root)
    try writeManifestFor(base: base, subdir: "Documents/xwechat_files", target: target)
    // 迁移后外置盘有新写入
    try Data(repeating: 7, count: 64).write(to: target.appendingPathComponent("new-chat.bin"))

    vm.requestRestore()
    // 外置更新：用户点的就是「还原外置」，直接用外置数据（确认框注明），不弹新旧选择
    #expect(await waitUntil { vm.activeDialog == .restoreConfirm && !vm.isBusy })
    #expect(vm.restoreNote?.contains("外置数据比内置备份新") == true)
}

@MainActor @Test func restoreDecisionNoBackupSkipsCompare() {
    let vm = AppViewModel()
    vm.isWeChatRunning = { false }
    vm.items = [ItemStatus(subdir: "Documents/xwechat_files",
                           source: URL(fileURLWithPath: "/tmp/c/x"),
                           state: .migrated, size: 100, hasBackup: false, backupSize: 0)]
    vm.requestRestore()
    // 无本地备份 → 不比对，直接弹常规确认框
    #expect(vm.activeDialog == .restoreConfirm)
    #expect(vm.busyKind == nil)
}

// MARK: - 内置备份入口的新旧判定

@MainActor @Test func backupRestoreDecisionSameGoesConfirm() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WeChatMoverTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let (vm, _, base, target) = try makeRestoreFixture(root)
    try writeManifestFor(base: base, subdir: "Documents/xwechat_files", target: target)

    vm.requestRestoreBackups()
    // 一致：无需打扰，直接走内置备份确认框
    #expect(await waitUntil { vm.activeDialog == .backupRestoreConfirm && !vm.isBusy })
}

@MainActor @Test func backupRestoreDecisionDiffersShowsNewerChoice() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WeChatMoverTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let (vm, _, base, target) = try makeRestoreFixture(root)
    try writeManifestFor(base: base, subdir: "Documents/xwechat_files", target: target)
    try Data(repeating: 7, count: 64).write(to: target.appendingPathComponent("new-chat.bin"))

    vm.requestRestoreBackups()
    // 外置更新：提示改用外置数据还原
    #expect(await waitUntil { vm.activeDialog == .restoreNewerChoice && !vm.isBusy })
}

@MainActor @Test func backupRestoreDecisionUnpluggedSkipsCompare() {
    let vm = AppViewModel()
    vm.isWeChatRunning = { false }
    // 有备份但无目标盘（拔盘）：跳过比对直接走内置备份确认框
    vm.items = [ItemStatus(subdir: "Documents/xwechat_files",
                           source: URL(fileURLWithPath: "/tmp/c/x"),
                           state: .migrated, size: 100, hasBackup: true, backupSize: 100)]
    vm.requestRestoreBackups()
    #expect(vm.activeDialog == .backupRestoreConfirm)
    #expect(vm.busyKind == nil)
}

// MARK: - 强制从外置还原

@Test func restoreItemFromExternalPath() throws {
    try withTempDir { root in
        let source = try makeDataDir(root: root, "container/Documents/xwechat_files",
                                     fileSizes: [128])
        let base = root.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let target = WeChatPaths.targetDirectory(base: base, subdir: "Documents/xwechat_files")
        try Migrator.migrateItem(source: source, target: target)
        let backup = WeChatPaths.backupDirectory(for: source)

        // 外置有新数据
        try Data(repeating: 7, count: 64).write(to: target.appendingPathComponent("new.bin"))
        try Migrator.restoreItemFromExternal(source: source, target: target)
        #expect(itemState(at: source) == .local)
        #expect(DiskProbe.directorySize(at: source) == 192)   // 含新数据
        #expect(!FileManager.default.fileExists(atPath: target.path))  // 外置副本已删
        #expect(!FileManager.default.fileExists(atPath: backup.path))  // 过期备份已删
    }
}

@Test func restoreItemFromExternalRefusals() throws {
    try withTempDir { root in
        // 非软链 → notMigrated
        let local = try makeDataDir(root: root, "c/Documents/app_data")
        #expect {
            try Migrator.restoreItemFromExternal(
                source: local, target: root.appendingPathComponent("t"))
        } throws: { guard case MigrationError.notMigrated = $0 else { return false }; return true }

        // 软链但外置目标不存在 → sourceMissing
        let source = root.appendingPathComponent("c2/Documents/xwechat_files")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: source, withDestinationURL: root.appendingPathComponent("gone"))
        #expect {
            try Migrator.restoreItemFromExternal(
                source: source, target: root.appendingPathComponent("gone"))
        } throws: { guard case MigrationError.sourceMissing = $0 else { return false }; return true }
    }
}

// MARK: - 用外置数据覆盖内置

@Test func overwriteSuccessKeepsBackupAndExternal() throws {
    try withTempDir { root in
        let source = try makeDataDir(root: root, "container/Documents/xwechat_files",
                                     fileSizes: [128])                       // 内置旧数据
        let target = try makeDataDir(root: root, "external/WeChatData/xwechat_files",
                                     fileSizes: [256, 64])                    // 外置新数据
        try Migrator.overwriteLocalWithExternal(source: source, target: target)

        let backup = WeChatPaths.backupDirectory(for: source)
        #expect(DiskProbe.directorySize(at: source) == 320)    // 内容 = 外置
        #expect(DiskProbe.directorySize(at: backup) == 128)    // _backup = 原内置
        #expect(Migrator.isOverwriteBackup(backup))            // 带安全网标记
        #expect(DiskProbe.directorySize(at: target) == 320)    // 外置保留不动
        #expect(itemState(at: source) == .local)               // 不算中断残留
    }
}

@Test func overwriteRefusals() throws {
    try withTempDir { root in
        // 源位是软链 → 拒绝
        let migratedSource = try makeDataDir(root: root, "c/Documents/xwechat_files")
        let base = root.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let target = WeChatPaths.targetDirectory(base: base, subdir: "Documents/xwechat_files")
        try Migrator.migrateItem(source: migratedSource, target: target)
        #expect {
            try Migrator.overwriteLocalWithExternal(source: migratedSource, target: target)
        } throws: { guard case MigrationError.sourceIsSymlink = $0 else { return false }; return true }

        // _backup 已存在 → 拒绝（不静默销毁旧快照）
        let source2 = try makeDataDir(root: root, "c2/Documents/app_data", fileSizes: [64])
        _ = try makeDataDir(root: root, "c2/Documents/app_data_backup", fileSizes: [32])
        let target2 = try makeDataDir(root: root, "e2/WeChatData/app_data", fileSizes: [64])
        #expect {
            try Migrator.overwriteLocalWithExternal(source: source2, target: target2)
        } throws: { guard case MigrationError.backupAlreadyExists = $0 else { return false }; return true }
        #expect(DiskProbe.directorySize(at: source2) == 64)    // 源未动
    }
}

@Test func overwriteCopyFailureRollsBack() throws {
    try withTempDir { root in
        let source = try makeDataDir(root: root, "container/Documents/xwechat_files",
                                     fileSizes: [128])
        let target = try makeDataDir(root: root, "external/WeChatData/xwechat_files",
                                     fileSizes: [256])
        // 外置目录里放一个不可读文件 → 拷贝中途失败
        let unreadable = target.appendingPathComponent("secret.bin")
        try Data(repeating: 1, count: 32).write(to: unreadable)
        try FileManager.default.setAttributes([.posixPermissions: 0o000],
                                              ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                       ofItemAtPath: unreadable.path) }

        #expect(throws: (any Error).self) {
            try Migrator.overwriteLocalWithExternal(source: source, target: target)
        }
        // 回滚：源位内容不变，无 _backup 残留
        #expect(itemState(at: source) == .local)
        #expect(DiskProbe.directorySize(at: source) == 128)
        #expect(!FileManager.default.fileExists(
            atPath: WeChatPaths.backupDirectory(for: source).path))
    }
}

@Test func overwriteBackupCanRestoreAndClean() throws {
    try withTempDir { root in
        let source = try makeDataDir(root: root, "container/Documents/xwechat_files",
                                     fileSizes: [128])
        let target = try makeDataDir(root: root, "external/WeChatData/xwechat_files",
                                     fileSizes: [256])
        try Migrator.overwriteLocalWithExternal(source: source, target: target)

        // 清理备份：带标记的覆盖备份允许删除
        let freed = try Migrator.deleteBackup(source: source)
        #expect(freed == 128)
        #expect(itemState(at: source) == .local)

        // 再做一次覆盖，这次还原安全网备份：当前内置数据让位，旧数据回位
        try Migrator.overwriteLocalWithExternal(source: source, target: target)
        try Migrator.restoreFromBackup(source: source)
        #expect(DiskProbe.directorySize(at: source) == 256)    // 回到覆盖前的内置数据
        #expect(itemState(at: source) == .local)
    }
}

// MARK: - 覆盖的比对与可用条件（VM 层）

@MainActor
private func makeOverwriteFixture(
    _ root: URL, externalDiffers: Bool
) throws -> (vm: AppViewModel, source: URL, target: URL) {
    // 迁移 → 还原内置备份：数据回内置，外置 WeChatData 保留
    let source = try makeDataDir(root: root, "container/Documents/xwechat_files",
                                 fileSizes: [128])
    let base = root.appendingPathComponent("external", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let target = WeChatPaths.targetDirectory(base: base, subdir: "Documents/xwechat_files")
    try Migrator.migrateItem(source: source, target: target)
    try Migrator.restoreItem(source: source, target: target)
    if externalDiffers {
        try Data(repeating: 7, count: 64).write(to: target.appendingPathComponent("new.bin"))
    }
    let vm = AppViewModel()
    vm.isWeChatRunning = { false }
    vm.resignRunner = { completion in completion(.success) }
    vm.signatureVerifier = { .adhoc }
    vm.containerRoot = root.appendingPathComponent("container", isDirectory: true)
    vm.targetBase = base
    vm.items = [ItemStatus(subdir: "Documents/xwechat_files", source: source,
                           state: .local, size: 128, hasBackup: false, backupSize: 0)]
    return (vm, source, target)
}

@MainActor @Test func overwriteAvailabilityAndDecision() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WeChatMoverTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    // 一致 → notice「无需覆盖」，不动作
    let (vmSame, source, target) = try makeOverwriteFixture(root, externalDiffers: false)
    #expect(vmSame.canOverwriteLocalWithExternal)
    vmSame.requestOverwriteWithExternal()
    #expect(await waitUntil { !vmSame.isBusy })
    #expect(vmSame.notice?.contains("一致") == true)
    #expect(vmSame.activeDialog == .notice)
    #expect(itemState(at: source) == .local)
    #expect(FileManager.default.fileExists(atPath: target.path))

    // 不一致 → 弹覆盖确认框；确认后执行：内容=外置、_backup 生成、外置保留
    let (vmDiff, source2, target2) = try makeOverwriteFixture(
        root.appendingPathComponent("case2"), externalDiffers: true)
    vmDiff.requestOverwriteWithExternal()
    #expect(await waitUntil { vmDiff.activeDialog == .overwriteConfirm && !vmDiff.isBusy })
    vmDiff.confirmOverwriteWithExternal()
    #expect(await waitUntil { !vmDiff.isBusy && vmDiff.activeDialog == .overwriteConfirm })
    #expect(DiskProbe.directorySize(at: source2) == DiskProbe.directorySize(at: target2))
    #expect(Migrator.isOverwriteBackup(WeChatPaths.backupDirectory(for: source2)))
    #expect(vmDiff.lastError == nil)

    // 迁移中（软链指向外置）→ 不可用
    let vmMigrated = AppViewModel()
    vmMigrated.targetBase = vmDiff.targetBase
    vmMigrated.items = [ItemStatus(subdir: "Documents/xwechat_files",
                                   source: source2, state: .migrated,
                                   size: 0, hasBackup: false, backupSize: 0)]
    #expect(!vmMigrated.canOverwriteLocalWithExternal)
}

// MARK: - 多档案（微信 / 企业微信）

@Test func appProfileConfiguration() {
    let ww = AppProfile.wework
    #expect(ww.bundleID == "com.tencent.WeWorkMac")
    #expect(ww.appPath == "/Applications/企业微信.app")
    // 不写死用户名：必须等于「当前用户 home + 容器相对路径」
    #expect(ww.containerRoot == FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Containers/com.tencent.WeWorkMac/Data", isDirectory: true))
    #expect(ww.candidateSubdirs == ["com.tencent.WeWorkMac-Data", "WXWork-Data"])
    #expect(ww.downloadURL.absoluteString.contains("work.weixin.qq.com"))
    #expect(ww.targetBaseDefaultsKey == "targetBasePath.wework")
    #expect(ww.lastSignedVersionDefaultsKey == "lastSignedVersion.wework")

    let wc = AppProfile.wechat
    #expect(wc.containerRoot.path.hasSuffix("Library/Containers/com.tencent.xinWeChat/Data"))
    #expect(wc.targetBaseDefaultsKey == "targetBasePath")   // 旧键名保持兼容
}

@Test func weworkItemNames() {
    #expect(Copywriting.itemName("com.tencent.WeWorkMac-Data") == "容器数据（全部）")
    #expect(Copywriting.itemName("WXWork-Data") == "应用支持数据")
}

/// 切档案：容器/候选目录/偏好键/目标位置全部跟随，展示状态清空。
@MainActor @Test func switchProfileSwapsContainerAndKeys() {
    let (defaults, cleanup) = makeIsolatedDefaults()
    defer { cleanup() }
    let vm = AppViewModel()
    vm.defaults = defaults
    // 两个档案各自独立的目标位置
    defaults.set("/Volumes/A/WeChat", forKey: AppProfile.wechat.targetBaseDefaultsKey)
    defaults.set("/Volumes/B/WeWork", forKey: AppProfile.wework.targetBaseDefaultsKey)

    vm.switchProfile(to: .wework)
    #expect(vm.profile == .wework)
    #expect(vm.containerRoot == AppProfile.wework.containerRoot)
    #expect(vm.candidateSubdirs == AppProfile.wework.candidateSubdirs)
    #expect(vm.targetBase?.path == "/Volumes/B/WeWork")
    #expect(vm.items.isEmpty && vm.wechat.signature == nil)
    #expect(vm.appName == "企业微信")

    vm.switchProfile(to: .wechat)
    #expect(vm.targetBase?.path == "/Volumes/A/WeChat")
    #expect(vm.appName == "微信")
}

/// 操作进行中禁止切档案。
@MainActor @Test func switchProfileRejectedWhileBusy() {
    let vm = AppViewModel()
    vm.isBusy = true
    vm.switchProfile(to: .wework)
    #expect(vm.profile == .wechat)
    #expect(vm.notice?.contains("操作进行中") == true)
}

/// 串档回归：切档案后，旧一代 refresh 的迟滞结果必须全部作废。
@MainActor @Test func staleGenerationResultsDiscarded() {
    let vm = AppViewModel()
    vm.switchProfile(to: .wework)
    let staleGen = vm.refreshGeneration - 1
    let fake = ItemStatus(subdir: "Documents/xwechat_files",
                          source: URL(fileURLWithPath: "/tmp/stale"),
                          state: .migrated, size: 1, hasBackup: true, backupSize: 1)
    vm.applyItems([fake], readable: true, generation: staleGen)
    #expect(vm.items.isEmpty)                       // 过期一代：丢弃
    vm.applyItems([fake], readable: true, generation: vm.refreshGeneration)
    #expect(vm.items.count == 1)                    // 当前代：生效
}

/// 串档回归：切档案后，旧档案的签名检测结果不回写。
@MainActor @Test func signatureCheckDiscardedAfterProfileSwitch() async {
    let vm = AppViewModel()
    vm.wechat.isInstalled = true
    vm.signatureVerifier = { .adhoc }   // 旧档案（微信）的检测结果
    vm.checkSignatureNow()
    vm.switchProfile(to: .wework)       // 检测未回就切档
    try? await Task.sleep(nanoseconds: 500_000_000)
    #expect(vm.wechat.signature == nil) // 旧结果作废，不回写
}

// MARK: - 企业微信问题回归

/// 回归：ensureQuit 的 isRunning 默认曾固定查微信——杀企业微信时微信在运行，
/// 导致明明杀掉了也报"退出失败"。现在默认必须跟随传入的 bundleID。
@Test func ensureQuitDefaultIsRunningFollowsBundleID() async {
    var called = false
    let ok = await WeChatQuitter.ensureQuit(
        bundleID: "com.example.definitely-not-installed-\(UUID().uuidString)",
        graceful: { called = true }, force: { called = true })
    #expect(ok)          // 未运行的 App：立即成功
    #expect(!called)     // 不触发退出动作
}

/// 回归：重签名一般性失败（非 TCC/不可写）也要弹指引并给重试入口，
/// 不能只在日志里报一句就完。
@MainActor @Test func resignGenericFailureShowsGuideWithRetry() async {
    let vm = AppViewModel()
    vm.isAppBundleWritable = { true }
    vm.resignRunner = { completion in completion(.failed("resource busy")) }
    vm.resignWeChat()
    #expect(await waitUntil { vm.activeSheet == .appManagementGuide })
    #expect(vm.resignGuideReason == .otherFailed("resource busy"))
    #expect(!vm.isResigning)
}
