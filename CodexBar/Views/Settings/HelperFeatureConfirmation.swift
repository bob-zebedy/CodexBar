import SwiftUI

enum HelperFeatureConfirmation: Identifiable {
    case autoReset
    case keepAlive

    var id: Self {
        self
    }

    func alert(
        helperStatus: KeepAliveController.HelperStatus,
        onConfirm: @escaping () -> Void
    ) -> Alert {
        Alert(
            title: title,
            message: Text(verbatim: message(helperStatus: helperStatus)),
            primaryButton: .destructive(Text("开启"), action: onConfirm),
            secondaryButton: .cancel(Text("取消"))
        )
    }

    private var title: Text {
        switch self {
        case .autoReset:
            Text("开启自动重置?")
        case .keepAlive:
            Text("开启防止系统睡眠?")
        }
    }

    private var details: String {
        switch self {
        case .autoReset:
            String(
                localized: "开启后, CodexBar 在手动重置临近过期时, 按设置的临期时间提前自动使用重置; 并可能短暂唤醒 Mac"
            )
        case .keepAlive:
            String(
                localized: "开启后, CodexBar 会在 Codex 任务运行时防止系统睡眠, 任务结束后自动恢复"
            )
        }
    }

    private func message(helperStatus: KeepAliveController.HelperStatus) -> String {
        switch helperStatus {
        case .notRegistered, .notFound:
            "\(String(localized: "需要安装并授权 CodexBar Helper 后台运行"))\n\(details)"
        case .requiresApproval:
            "\(String(localized: "已安装 CodexBar Helper 但需要授权允许后台运行"))\n\(details)"
        case .enabled:
            details
        }
    }
}
