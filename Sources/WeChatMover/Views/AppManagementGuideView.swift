import SwiftUI
import AppKit

/// 重签名受阻指引：
/// - appManagementDenied：TCC「App 管理」未授权，codesign 报 Operation not permitted，
///   引导去系统设置给 WeChatMover 授权一次；
/// - notWritable：/Applications/WeChat.app 当前用户不可写（罕见，所有者非同用户），
///   引导在终端执行 sudo 兜底命令。
struct AppManagementGuideView: View {
    @EnvironmentObject var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(vm.resignGuideReason == .notWritable ? "需要在终端手动重签名" : "需要「App 管理」权限")
                .font(.headline)

            if vm.resignGuideReason == .notWritable {
                Text("/Applications/WeChat.app 的所有者不是当前用户，WeChatMover 无法直接重签名。请在「终端」App 里执行以下命令：")
                    .font(.callout)
                commandBlock
            } else {
                Text("重签名由 WeChatMover 直接执行（无需管理员密码），但 macOS 要求显式允许它修改其他 App，否则会被系统拒绝（Operation not permitted）。授权只需一次：")
                    .font(.callout)

                VStack(alignment: .leading, spacing: 6) {
                    Text("1. 点击下方按钮，打开 系统设置 → 隐私与安全性 → App 管理")
                    Text("2. 打开 WeChatMover 的开关（列表中没有就点「+」添加）")
                    Text("3. 回到这里点「重试重签名」")
                }
                .font(.callout)

                Button("打开「App 管理」设置") { PermissionHelper.openAppManagement() }
                    .buttonStyle(.borderedProminent)

                Divider()

                Text("兜底方案：在「终端」App 里执行以下命令（终端通常已有该权限，一般能成功）：")
                    .font(.callout)
                commandBlock
            }

            HStack {
                Button("以后再说") { dismiss() }
                Spacer()
                if vm.resignGuideReason != .notWritable {
                    Button("重试重签名") {
                        dismiss()
                        vm.resignWeChat()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.isResigning)
                }
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var commandBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(CodeSigner.terminalCommand(appPath: vm.profile.appPath))
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            Button(copied ? "已复制 ✅" : "复制命令") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(CodeSigner.terminalCommand(appPath: vm.profile.appPath), forType: .string)
                copied = true
            }
        }
    }
}
