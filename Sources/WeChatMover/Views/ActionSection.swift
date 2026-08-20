import SwiftUI

/// 操作区（规范 5.5/5.6）：迁移中是进度面板；平时是居中的单一主按钮，
/// 按状态切换（迁移 / 还原外置数据 / 还原内置备份），同一时刻只显示一个。
struct ActionSection: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        if vm.busyKind == .migrating {
            progressPanel
        } else {
            primaryButton
        }
    }

    /// 迁移进度面板：与页面内容区等宽（横向拉满，与状态横幅同宽）；
    /// 只保留步骤与说明文字，进度条与百分比以顶部横幅为准（不重复展示）。
    private var progressPanel: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text("正在复制\(vm.appName)数据")
                .font(.headline)
            Text("迁移期间请不要退出\(vm.appName)或拔出硬盘")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    /// 居中的单一主按钮（微信绿大按钮，高约 40pt）。
    @ViewBuilder
    private var primaryButton: some View {
        HStack {
            Spacer()
            switch vm.primaryAction {
            case .migrate:
                Button(vm.primaryActionTitle) { vm.requestMigration() }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignTokens.Colors.accent)
                    .controlSize(.large)
                    .frame(minWidth: 220, minHeight: 40)
                    .disabled(!vm.canMigrate)
                    .keyboardShortcut(.defaultAction)
            case .restore:
                Button("还原外置存储数据到 Mac…") { vm.requestRestore() }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignTokens.Colors.accent)
                    .controlSize(.large)
                    .frame(minWidth: 220, minHeight: 40)
                    .disabled(!vm.canRestore)
            case .restoreBackups:
                Button("还原内置存储数据到 Mac…") { vm.requestRestoreBackups() }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignTokens.Colors.accent)
                    .controlSize(.large)
                    .frame(minWidth: 220, minHeight: 40)
                    .disabled(!vm.canRestoreBackups)
            case .none:
                EmptyView()
            }
            Spacer()
        }
    }
}

/// 管理行（次级入口，弱化小号按钮）：本地备份（占用 + 恢复 + 清理）/ 还原 / 清理外置数据。
struct ManageSection: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        if showRestoreRow || !vm.backupItems.isEmpty || vm.hasExternalData {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                if showRestoreRow {
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        Image(systemName: "arrow.uturn.backward")
                            .foregroundStyle(.secondary)
                        Text("部分数据已外置，可从外置硬盘还原回 Mac")
                            .font(.callout)
                        Spacer()
                        Button("还原外置存储数据到 Mac…") { vm.requestRestore() }
                            .controlSize(.small)
                            .disabled(!vm.canRestore)
                    }
                }
                // 本地备份行：占用大小 +（适用时）恢复 + 清理，同一行承载
                if !vm.backupItems.isEmpty {
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        Image(systemName: "internaldrive")
                            .foregroundStyle(.secondary)
                        Text("本地备份占用 \(DiskProbe.formatBytes(vm.totalBackupSize))")
                            .font(.callout)
                            .monospacedDigit()
                        Spacer()
                        // 「还原内置存储数据到 Mac…」是中央主按钮时（backupOnly 状态）这里不重复显示
                        if showRestoreBackupsButton {
                            Button("还原内置存储数据到 Mac…") { vm.requestRestoreBackups() }
                                .controlSize(.small)
                                .disabled(!vm.canRestoreBackups)
                                .help("从本地备份还原：放弃迁移，回到 Mac 上的旧数据（不需要外置硬盘）")
                        }
                        Button("清理备份…") { vm.activeDialog = .backupConfirm }
                            .controlSize(.small)
                            .disabled(!vm.canDeleteBackups)
                    }
                }
                if vm.hasExternalData {
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        Image(systemName: "externaldrive")
                            .foregroundStyle(.secondary)
                        Text("外置数据占用 \(vm.externalDataSize.map(DiskProbe.formatBytes) ?? "统计中…")"
                             + (vm.canCleanExternalData || vm.isBusy ? "" : " · 还原数据到 Mac 后可清理"))
                            .font(.callout)
                            .monospacedDigit()
                        Spacer()
                        Button("用外置数据覆盖内置…") { vm.requestOverwriteWithExternal() }
                            .controlSize(.small)
                            .disabled(!vm.canOverwriteLocalWithExternal)
                            .help(vm.canOverwriteLocalWithExternal
                                  ? "用外置硬盘上的数据覆盖 Mac 内置盘现有数据（先备份为 _backup）"
                                  : "还原数据到 Mac 后可用")
                        Button("清理外置数据…") { vm.requestCleanExternalData() }
                            .controlSize(.small)
                            .disabled(!vm.canCleanExternalData)
                            .help(vm.canCleanExternalData
                                  ? "删除外置硬盘上的 WeChatData"
                                  : "还原数据到 Mac 后可清理")
                    }
                }
            }
            .cardStyle()
        }
    }

    /// 「还原内置存储数据到 Mac…」是中央主按钮时（backupOnly 状态），行内不重复显示。
    private var showRestoreBackupsButton: Bool {
        !vm.restorableBackupItems.isEmpty && vm.primaryAction != .restoreBackups
    }

    /// 部分外置（还有待迁移）时主按钮是「更新迁移」，还原降级到管理行。
    private var showRestoreRow: Bool {
        !vm.migratedItems.isEmpty && vm.primaryAction != .restore
    }
}
