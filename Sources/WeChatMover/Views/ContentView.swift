import SwiftUI
import AppKit

/// 仪表盘根视图：PageHeader → ReadinessBanner → 摘要卡片 → 目标选择器
/// → 单一主操作区 → 可折叠日志；窗口底部固定 GitHub 链接条。
/// View 只消费展示模型。
struct ContentView: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                    profileTabs
                    pageHeader
                    ReadinessBanner(model: vm.banner)
                    StatusSummaryGrid()
                    DestinationPickerRow()
                    ActionSection()
                    ManageSection()
                    LogDisclosureGroup()
                }
                .padding(DesignTokens.Spacing.xl)
                .frame(maxWidth: 960)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            githubFooter
        }
        .background(DesignTokens.Colors.background)
        // 切档案时整体重建视图树：部分视图（如目标磁盘卡片）的展示模型跨档案可能逐字段相等，
        // SwiftUI 会跳过重绘导致主题色陈旧；.id 强制重建，颜色/文案全部按新档案重取。
        .id(vm.profile)
        .tint(vm.profile.accent)   // 控件强调色跟随档案（微信绿/企业微信蓝）
        .toolbar { toolbarItems }
        .alert(item: alertOnlyDialog, content: dialog)
        // 三选项弹窗用 confirmationDialog（Alert 只支持两个按钮），
        // 仍由 ActiveDialog 单一枚举驱动，这里只是按呈现方式拆绑定。
        .confirmationDialog(
            "更改目标位置",
            isPresented: relocateConfirmPresented,
            titleVisibility: .visible
        ) {
            Button("转移数据到新位置…") { vm.confirmRelocateChoose() }
            Button("不转移，只改目标位置…") { vm.confirmNoTransferChoose() }
            Button("取消", role: .cancel) {}
        } message: {
            let size = vm.externalDataSize.map { "约 \(DiskProbe.formatBytes($0))" } ?? "大小统计中"
            Text("当前\(vm.appName)数据位于：\n\(vm.targetBase?.path ?? "")（\(size)）\n\n「转移」会把数据完整拷贝到新位置，校验通过后清除原位置数据（期间请勿打开\(vm.appName)或拔出硬盘）。\n「不转移」不拷贝任何数据，仅切换指向或更新记录，原位置数据保留不动。")
        }
        .confirmationDialog(
            "新位置怎么用？",
            isPresented: repointChoicePresented,
            titleVisibility: .visible
        ) {
            Button("新位置已有数据，直接改指过去") { vm.confirmRepoint() }
            Button("只更新记录，数据和链接不动") { vm.confirmRecordOnly() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(vm.repointChoiceMessage)
        }
        .confirmationDialog(
            "目标位置已有数据",
            isPresented: existingTargetPresented,
            titleVisibility: .visible
        ) {
            Button("直接使用外置数据（本地数据转为备份）") { vm.adoptExistingTargetsAndMigrate() }
            Button("删除旧数据并重新迁移", role: .destructive) { vm.removeConflictingTargetAndMigrate() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("以下 \(vm.conflictingTargetPaths.count) 个位置已存在数据，可能来自上次迁移中断或重复迁移：\n\(vm.conflictingTargetPaths.joined(separator: "\n"))\n\n可直接使用外置已有数据（本地数据备份为 _backup，无需拷贝），或删除旧数据后重新迁移（删除不可恢复）。")
        }
        .confirmationDialog(
            "外置数据与内置备份一致",
            isPresented: restoreSameChoicePresented,
            titleVisibility: .visible
        ) {
            Button("使用内置备份（更快）") { vm.confirmRestoreBackups() }
            Button("仍从外置硬盘拷贝") { vm.confirmRestoreFromExternal() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("两侧数据内容一致。使用内置备份无需拷贝、速度更快，外置硬盘上的数据保留不动。")
        }
        .confirmationDialog(
            "外置数据比内置备份新",
            isPresented: restoreNewerChoicePresented,
            titleVisibility: .visible
        ) {
            Button("改用外置数据还原（推荐）") { vm.confirmRestoreFromExternal() }
            Button("仍使用内置备份（将丢失外置盘上的新数据）", role: .destructive) { vm.confirmRestoreBackups() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("外置硬盘上的数据比内置备份新（通常是迁移后有新聊天记录写入外置盘），建议优先还原外置数据。")
        }
        .sheet(item: $vm.activeSheet, content: sheet)
    }

    /// .alert 绑定：多选项弹窗走 confirmationDialog，这里过滤掉避免双弹。
    private var alertOnlyDialog: Binding<ActiveDialog?> {
        Binding(
            get: {
                switch vm.activeDialog {
                case .restoreSameChoice, .restoreNewerChoice, .existingTarget,
                     .relocateConfirm, .repointChoice: return nil
                default: return vm.activeDialog
                }
            },
            set: { vm.activeDialog = $0 }
        )
    }

    private var existingTargetPresented: Binding<Bool> {
        Binding(
            get: { vm.activeDialog == .existingTarget },
            set: { if !$0 { vm.activeDialog = nil } }
        )
    }

    private var relocateConfirmPresented: Binding<Bool> {
        Binding(
            get: { vm.activeDialog == .relocateConfirm },
            set: { if !$0 { vm.activeDialog = nil } }
        )
    }

    private var repointChoicePresented: Binding<Bool> {
        Binding(
            get: { vm.activeDialog == .repointChoice },
            set: { if !$0 { vm.cancelRepointChoice() } }
        )
    }

    private var restoreSameChoicePresented: Binding<Bool> {
        Binding(
            get: { vm.activeDialog == .restoreSameChoice },
            set: { if !$0 { vm.activeDialog = nil } }
        )
    }

    private var restoreNewerChoicePresented: Binding<Bool> {
        Binding(
            get: { vm.activeDialog == .restoreNewerChoice },
            set: { if !$0 { vm.activeDialog = nil } }
        )
    }

    /// 规范 5.1：标题 + 副标题，不重复完整产品名。
    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            Text("\(vm.appName)数据迁移")
                .font(.title2.weight(.semibold))
            Text("将\(vm.appName)数据安全迁移到外置硬盘，释放 Mac 空间。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// 顶部档案切换页签：微信 / 企业微信，带真实 App 图标。
    /// 有操作进行中（迁移/还原/重签名等）时禁用，防止状态错乱。
    private var profileTabs: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            ForEach(AppProfile.allCases) { p in
                let selected = vm.profile == p
                Button {
                    vm.switchProfile(to: p)
                } label: {
                    HStack(spacing: 6) {
                        Image(nsImage: Self.appIcon(for: p))
                            .resizable()
                            .frame(width: 18, height: 18)
                        Text(p.displayName)
                            .font(.callout.weight(.medium))
                    }
                    .padding(.horizontal, DesignTokens.Spacing.sm)
                    .padding(.vertical, DesignTokens.Spacing.xs)
                    .background(
                        Capsule().fill(selected ? vm.profile.accent.opacity(0.15) : Color.clear)
                    )
                    .overlay(
                        Capsule().stroke(
                            selected ? vm.profile.accent : DesignTokens.Colors.separator,
                            lineWidth: 1)
                    )
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(vm.isBusy || vm.isResigning || vm.isQuittingWeChat)
                .accessibilityLabel("切换到\(p.displayName)")
            }
        }
    }

    /// 页签图标：目标 App 的真实图标（未安装时系统给通用图标兜底）。
    private static func appIcon(for profile: AppProfile) -> NSImage {
        NSWorkspace.shared.icon(forFile: profile.appPath)
    }

    /// 窗口底部固定的 GitHub 仓库链接（mark 为模板渲染，深浅色自适应）。
    private var githubFooter: some View {
        Button {
            NSWorkspace.shared.open(URL(string: "https://github.com/pipipiper/WeChatMover")!)
        } label: {
            HStack(spacing: 6) {
                if let mark = Self.githubMark {
                    Image(nsImage: mark)
                        .resizable()
                        .frame(width: 14, height: 14)
                }
                Text("github.com/pipipiper/WeChatMover")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DesignTokens.Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("在 GitHub 上查看源码与使用指南")
    }

    /// GitHub mark（黑色透明底，模板渲染后跟随前景色）。
    private static let githubMark: NSImage? = {
        guard let url = Bundle.main.url(forResource: "GitHub-Mark", withExtension: "png"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.isTemplate = true
        return img
    }()

    /// Toolbar 右侧：刷新（图标 + Tooltip）、帮助。
    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { vm.refresh() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("刷新")
            .accessibilityLabel("刷新")

            Menu {
                Button("权限重新授权指南") { vm.activeSheet = .guide }
                Button("App 管理授权指南") {
                    vm.resignGuideReason = .appManagementDenied
                    vm.activeSheet = .appManagementGuide
                }
            } label: {
                Image(systemName: "questionmark.circle")
            }
            .help("帮助")
            .accessibilityLabel("帮助")
        }
    }

    @ViewBuilder
    private func sheet(_ sheet: ActiveSheet) -> some View {
        switch sheet {
        case .guide:
            GuideView()
        case .appManagementGuide:
            AppManagementGuideView().environmentObject(vm)
        }
    }

    /// 所有确认/提示弹窗由 ActiveDialog 单一枚举驱动。
    private func dialog(_ dialog: ActiveDialog) -> Alert {
        switch dialog {
        case .migrateConfirm:
            return Alert(
                title: Text("迁移\(vm.appName)数据到“\(vm.destinationName)”？"),
                message: Text(vm.migrateConfirmMessage),
                primaryButton: .default(Text("退出\(vm.appName)并开始迁移")) { vm.confirmMigration() },
                secondaryButton: .cancel())
        case .relocateConfirm, .repointChoice:
            // 由 confirmationDialog 呈现（Alert 只支持两个按钮），不会走到这里
            return Alert(title: Text("更改目标位置"))
        case .relocateExecute:
            let size = vm.externalDataSize.map { "约 \(DiskProbe.formatBytes($0))" } ?? ""
            var msg = "将把\(vm.appName)数据（\(size)）转移到：\n\(vm.pendingRelocateBase?.path ?? "")\n\n数据量较大，转移可能需要几分钟到几十分钟，期间请保持硬盘连接、不要打开\(vm.appName)。转移完成并校验通过后，原位置数据会自动清除。"
            if let fs = vm.pendingRelocateNonAPFS {
                msg += "\n\n⚠️ 注意：新位置的磁盘格式为 \(fs)，不是 APFS。非 APFS 磁盘可能出现存储膨胀、性能下降等问题，强烈建议改用 APFS 磁盘。"
            }
            return Alert(
                title: Text("确认转移\(vm.appName)数据？"),
                message: Text(msg),
                primaryButton: .default(Text("开始转移")) { vm.confirmRelocate() },
                secondaryButton: .cancel(Text("取消")) {
                    vm.pendingRelocateBase = nil
                    vm.pendingRelocateNonAPFS = nil
                })
        case .restoreConfirm:
            return Alert(
                title: Text("还原外置存储数据到 Mac？"),
                message: Text((vm.restoreNote.map { $0 + "\n\n" } ?? "")
                    + "来源：外置硬盘上的 WeChatData → 目标：Mac 内置盘原位置。如\(vm.appName)正在运行，将先自动退出。"),
                primaryButton: .destructive(Text("确认还原")) { vm.confirmRestore() },
                secondaryButton: .cancel())
        case .restoreSameChoice, .restoreNewerChoice:
            // 由 confirmationDialog 呈现（Alert 不支持三个按钮），不会走到这里
            return Alert(title: Text("还原方式选择"))
        case .backupRestoreConfirm:
            return Alert(
                title: Text("还原内置存储数据到 Mac？"),
                message: Text("来源：Mac 内置盘上的本地备份（_backup）→ 目标：Mac 内置盘原位置。将删除符号链接、把备份改回原名：放弃迁移，回到 Mac 上的旧数据。全程不访问外置硬盘（不插盘也能用），外置数据保留不动，可之后用「清理外置数据…」删除。如需保留外置盘上的最新数据，请改用「还原外置存储数据到 Mac…」。如\(vm.appName)正在运行，将先自动退出。"),
                primaryButton: .destructive(Text("确认还原")) { vm.confirmRestoreBackups() },
                secondaryButton: .cancel())
        case .backupConfirm:
            return Alert(
                title: Text("清理本地备份？"),
                message: Text("将删除 \(vm.backupItems.count) 个备份目录，释放约 \(DiskProbe.formatBytes(vm.totalBackupSize))。已逐项确认软链有效后才会删除，但删除后不可恢复。"),
                primaryButton: .destructive(Text("删除")) { vm.deleteAllBackups() },
                secondaryButton: .cancel())
        case .existingTarget:
            // 由 confirmationDialog 呈现（三个选项），不会走到这里
            return Alert(title: Text("目标位置已有数据"))
        case .cleanExternal:
            return Alert(
                title: Text("清理外置数据？"),
                message: Text("将删除外置硬盘上的 \(vm.externalDataURL?.path ?? "")（约 \(DiskProbe.formatBytes(vm.externalDataSize ?? 0))）。删除后不可恢复；本机数据不受影响。"),
                primaryButton: .destructive(Text("删除")) { vm.cleanExternalData() },
                secondaryButton: .cancel())
        case .overwriteConfirm:
            return Alert(
                title: Text("用外置数据覆盖内置？"),
                message: Text("将用外置硬盘上的数据覆盖 Mac 内置盘上的现有数据。覆盖前会先把当前内置数据备份为 _backup（安全网，可事后用「还原内置存储数据到 Mac…」恢复，或确认无误后用「清理备份…」释放空间）；外置硬盘上的数据保留不动。如\(vm.appName)正在运行，将先自动退出。"),
                primaryButton: .destructive(Text("确认覆盖")) { vm.confirmOverwriteWithExternal() },
                secondaryButton: .cancel())
        case .error:
            return Alert(
                title: Text("操作失败"),
                message: Text(vm.lastError ?? ""),
                dismissButton: .default(Text("好")) { vm.lastError = nil })
        case .notice:
            return Alert(
                title: Text("提示"),
                message: Text(vm.notice ?? ""),
                dismissButton: .default(Text("好")) { vm.notice = nil })
        }
    }
}
