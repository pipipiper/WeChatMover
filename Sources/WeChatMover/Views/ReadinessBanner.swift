import SwiftUI

/// 就绪状态横幅（规范 5.2）：颜色 + 图标 + 文案三重表达，主按钮禁用时在此说明原因。
struct ReadinessBanner: View {
    @EnvironmentObject var vm: AppViewModel
    let model: BannerModel

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            Image(systemName: model.symbol)
                .font(.title2)
                .foregroundStyle(DesignTokens.toneColor(model.tone))
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(model.title)
                    .font(.headline)
                Text(model.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let progress = model.progress {
                    ProgressView(value: progress)
                        .accessibilityValue("\(Int((progress * 100).rounded()))%")
                }

                if case .succeeded = vm.appStatus {
                    successActions
                }
            }

            Spacer(minLength: DesignTokens.Spacing.sm)

            if let fix = model.fix {
                fixButton(fix)
            }
        }
        .padding(DesignTokens.Spacing.md)
        .frame(minHeight: 60)
        .background(
            DesignTokens.toneColor(model.tone).opacity(0.08),
            in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.card)
                .stroke(DesignTokens.toneColor(model.tone).opacity(0.35), lineWidth: 1)
        )
    }

    /// 成功态的低优先级动作（规范 6.5）。
    private var successActions: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Button("在 Finder 中显示") { vm.revealExternalData() }
            Button("复制报告") { vm.copyMigrationReport() }
            Button("完成") { vm.dismissOutcome() }
        }
        .controlSize(.small)
        .padding(.top, DesignTokens.Spacing.xxs)
    }

    @ViewBuilder
    private func fixButton(_ fix: FixAction) -> some View {
        switch fix {
        case .chooseDestination:
            Button("选择位置…") { vm.chooseTarget() }
        case .openFullDiskAccess:
            Button("打开系统设置") { PermissionHelper.openFullDiskAccess() }
        case .openOfficialDownload:
            Button("打开\(vm.appName)官网") {
                NSWorkspace.shared.open(vm.profile.downloadURL)
            }
        case .retryMigration:
            Button("重试") { vm.requestMigration() }
        }
    }
}
