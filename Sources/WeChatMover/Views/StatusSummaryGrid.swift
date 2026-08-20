import SwiftUI
import AppKit

/// 三张摘要卡片（规范 5.3）：微信数据 / 目标磁盘 / 安全检查。
/// 窄窗口（<820pt 等效）时由 ViewThatFits 自动从三列退化为单列。
struct StatusSummaryGrid: View {
    @EnvironmentObject var vm: AppViewModel
    @State private var showSafetyDetails = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DesignTokens.Spacing.sm) { cards }
            VStack(spacing: DesignTokens.Spacing.sm) { cards }
        }

        if showSafetyDetails {
            safetyDetails
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var cards: some View {
        ForEach(vm.summaryCards) { card in
            if card.id == "safety" {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showSafetyDetails.toggle()
                    }
                } label: {
                    StatusCard(model: card)
                }
                .buttonStyle(.plain)
                .help("点击查看安全检查详情")
            } else {
                StatusCard(model: card)
            }
        }
    }

    /// 安全检查卡片点开的技术详情（规范 5.3）。
    private var safetyDetails: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            detailRow("\(vm.appName)来源", Copywriting.sourceName(isAppStoreVersion: vm.wechat.isAppStoreVersion))
            detailRow("\(vm.appName)版本", vm.wechat.version ?? "未安装")
            HStack {
                detailRow("应用签名", vm.signatureDisplayText)
                if vm.wechat.signature == nil && vm.wechat.isInstalled {
                    Button("检测") { vm.checkSignatureNow() }.controlSize(.small)
                }
                if vm.wechat.isInstalled {
                    // 常驻入口：微信/系统更新后微信打不开时，一键重签名修复
                    Button("重新签名\(vm.appName)") { vm.resignWeChat() }
                        .controlSize(.small)
                        .disabled(vm.isBusy || vm.isResigning)
                        .help("\(vm.appName)或 macOS 更新后\(vm.appName)无法打开时，点此重新签名修复")
                }
            }
            detailRow("目标磁盘格式", vm.targetFSType ?? "未选择")
            detailRow("内置盘剩余", vm.homeFreeSpace.map(DiskProbe.formatBytes) ?? "—")
            if !vm.safetyIssues.isEmpty {
                ForEach(vm.safetyIssues, id: \.self) { issue in
                    Label(issue, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(DesignTokens.Colors.warning)
                }
            }
        }
        .cardStyle()
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.callout)
    }
}

/// 单张摘要卡片：左上标签、左下主值+副文案、右上图标（支持真实微信图标）。
struct StatusCard: View {
    let model: StatusCardModel

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack {
                Text(model.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                icon
            }
            Spacer(minLength: 0)
            Text(model.value)
                .font(.title3.weight(.semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(model.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var icon: some View {
        if model.customIcon == .weChatApp {
            // 运行时取微信 App 真实图标，无需打包资源
            Image(nsImage: NSWorkspace.shared.icon(forFile: model.customIconPath ?? CodeSigner.wechatAppPath))
                .resizable()
                .frame(width: 24, height: 24)
        } else {
            Image(systemName: model.symbol)
                .font(.title2)
                .foregroundStyle(iconColor)
        }
    }

    private var iconColor: Color {
        if model.iconUsesAccent, model.tone == .neutral || model.tone == .info {
            return DesignTokens.Colors.accent
        }
        return DesignTokens.toneColor(model.tone)
    }
}
