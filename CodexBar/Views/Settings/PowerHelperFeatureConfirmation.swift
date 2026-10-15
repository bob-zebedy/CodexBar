import SwiftUI

enum PowerHelperFeatureConfirmation {
    case autoReset
    case keepAlive

    var title: Text {
        switch self {
        case .autoReset:
            Text("auto-reset.confirmation.title")
        case .keepAlive:
            Text("keep-alive.confirmation.title")
        }
    }

    private var details: String {
        switch self {
        case .autoReset:
            String(localized: "auto-reset.confirmation.message")
        case .keepAlive:
            String(localized: "keep-alive.confirmation.message")
        }
    }

    func message(powerHelperStatus: KeepAliveController.PowerHelperStatus) -> String {
        switch powerHelperStatus {
        case .notRegistered, .notFound:
            "\(String(localized: "power-helper.status.install-and-authorize"))\n\(details)"
        case .requiresApproval:
            "\(String(localized: "power-helper.status.installed-needs-authorization"))\n\(details)"
        case .enabled:
            details
        }
    }
}
