import Foundation

nonisolated enum BridgeTurnStatus: String, CaseIterable {
    case idle, running, waiting, completed, interrupted, failed, unknown

    static let active: [Self] = [.running, .waiting]

    var isActive: Bool {
        Self.active.contains(self)
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .interrupted, .failed: true
        case .idle, .running, .waiting, .unknown: false
        }
    }

    init(upstream value: BridgeJSON) {
        switch value {
        case "inProgress": self = .running
        case "completed": self = .completed
        case "interrupted": self = .interrupted
        case "failed": self = .failed
        default: self = .unknown
        }
    }
}

nonisolated struct BridgeTurnKey: Hashable {
    let task: String
    let turn: String
}
