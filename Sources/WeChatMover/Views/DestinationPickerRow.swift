import SwiftUI

/// 目标位置整行选择器（规范 5.4）：路径只读、中间截断、悬停显示完整路径；
/// 未选择时为同卡片样式的占位行（与已选择视觉统一）；校验失败行内提示（横幅同步说明）。
struct DestinationPickerRow: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text("目标位置")
                .font(.headline)

            if let base = vm.targetBase {
                selectedRow(base)
            } else {
                emptyRow
            }

            if let problem = inlineProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(DesignTokens.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 已选择：卷名 + 只读路径 + 格式/余量 + 更改按钮。
    private func selectedRow(_ base: URL) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "externaldrive.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(vm.destinationName)
                    .font(.body.weight(.medium))
                Text(base.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(base.path)
                Text("\(vm.targetFSType ?? "未知格式") · 可用 \(vm.targetFreeSpace.map(DiskProbe.formatBytes) ?? "—")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer()

            Button("更改…") { vm.chooseTarget() }
        }
        .cardStyle()
    }

    /// 未选择：与已选择相同的卡片样式（实线），占位文案 + 选择入口，整行可点。
    private var emptyRow: some View {
        Button { vm.chooseTarget() } label: {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: "externaldrive")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 32)
                Text("选择一个外置硬盘文件夹")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("选择…")
                    .foregroundStyle(DesignTokens.Colors.accent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cardStyle()
    }

    /// 行内校验提示（不弹连续 Alert）。
    private var inlineProblem: String? {
        guard vm.targetBase != nil else { return nil }
        if !vm.isTargetAPFS {
            return "目标磁盘不是 APFS 格式，可能出现存储膨胀、性能下降等问题，建议改用 APFS 磁盘。"
        }
        if vm.sizesLoaded, !vm.localItems.isEmpty,
           let free = vm.targetFreeSpace, free < vm.totalLocalSize {
            return "空间不足：至少需要 \(DiskProbe.formatBytes(vm.totalLocalSize))，当前可用 \(DiskProbe.formatBytes(free))。"
        }
        return nil
    }
}
