import Combine
import Foundation

@MainActor
final class TaskGlowSettings: ObservableObject {
    @Published private(set) var isEnabled: Bool

    var previewRequests: AnyPublisher<Void, Never> {
        previewSubject.eraseToAnyPublisher()
    }

    private let defaults: UserDefaults
    private let previewSubject = PassthroughSubject<Void, Never>()
    private static let enabledKey = "TaskGlow.isEnabled"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.enabledKey)
    }

    func refresh() {
        let enabled = defaults.bool(forKey: Self.enabledKey)
        if enabled != isEnabled {
            isEnabled = enabled
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        defaults.set(enabled, forKey: Self.enabledKey)
        isEnabled = enabled
        if enabled {
            previewSubject.send()
        }
    }
}
