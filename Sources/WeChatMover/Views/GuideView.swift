import SwiftUI

/// 迁移后「权限重新授权」图文指引。
/// 重签名后系统里旧的微信权限记录会失效，简单关闭再打开开关有时不生效，
/// 需要先移除再重新添加。
struct GuideView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("迁移完成，还需重新授权").font(.headline)

            Text("重签名后，系统里旧的\(vm.appName)权限记录会失效，单纯关闭再打开开关有时不生效，需要在设置里**先移除、再重新添加**：")
                .font(.callout)

            VStack(alignment: .leading, spacing: 8) {
                step(1, "打开 系统设置 → 隐私与安全性 → 屏幕录制（\(vm.appName)的截图功能需要它）")
                step(2, "在列表中选中「\(vm.appName)」，点列表下方的「−」按钮将其移除")
                step(3, "再点「+」按钮，在应用程序文件夹中重新选中「\(vm.appName)」添加回来")
                step(4, "对「麦克风」重复同样的移除再添加（语音/视频通话需要它）")
                step(5, "完全退出\(vm.appName)（⌘Q）再重新打开，权限才会生效")
            }

            HStack(spacing: 12) {
                Button("打开屏幕录制设置") { PermissionHelper.openScreenRecording() }
                Button("打开麦克风设置") { PermissionHelper.openMicrophone() }
            }

            Text("提示：外置盘未连接时请不要启动\(vm.appName)，否则\(vm.appName)会在原位新建空数据目录。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("知道了") { dismiss() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(n).").bold().frame(width: 18, alignment: .trailing)
            Text(text)
        }
        .font(.callout)
    }
}
