import AppKit
import Combine
import Foundation

enum TaskGlowColorRole: String, CaseIterable {
    case running, waiting, completed, terminated

    var title: LocalizedStringResource {
        switch self {
        case .running: "task-glow.color.running"
        case .waiting: "task-glow.color.waiting"
        case .completed: "task-glow.color.completed"
        case .terminated: "task-glow.color.terminated"
        }
    }

    var defaultColor: NSColor {
        switch self {
        case .running: .systemCyan
        case .waiting: .systemOrange
        case .completed: .systemGreen
        case .terminated: .systemRed
        }
    }
}

enum TaskGlowAnimationSpeed: String, CaseIterable {
    case slow, standard, fast

    var title: String {
        switch self {
        case .slow: String(localized: "task-glow.speed.slow")
        case .standard: String(localized: "task-glow.speed.standard")
        case .fast: String(localized: "task-glow.speed.fast")
        }
    }

    var durationMultiplier: Double {
        switch self {
        case .slow: 1.5
        case .standard: 1
        case .fast: 0.7
        }
    }
}

struct TaskGlowAppearance: Equatable {
    var colors: [TaskGlowColorRole: String] = [:]
    var animationSpeed = TaskGlowAnimationSpeed.standard
    var terminalDuration: TimeInterval = 10
    var brightness = 1.0

    func color(for role: TaskGlowColorRole) -> NSColor {
        colors[role].flatMap(Self.decodeColor) ?? role.defaultColor
    }

    static func normalizedColorHex(_ input: String) -> String? {
        var hex = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") {
            hex.removeFirst()
        }
        guard hex.count == 6, hex.allSatisfy(\.isHexDigit), UInt32(hex, radix: 16) != nil else { return nil }
        return hex.uppercased()
    }

    static func decodeColor(_ hex: String) -> NSColor? {
        guard hex.count == 6, hex.allSatisfy(\.isHexDigit), let rgb = UInt32(hex, radix: 16) else { return nil }
        return NSColor(
            displayP3Red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255,
            alpha: 1
        )
    }

    static func encodeColor(_ color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.displayP3) else { return nil }
        let components = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
        guard components.allSatisfy(\.isFinite) else { return nil }
        return components.map { String(format: "%02X", Int((min(1, max(0, $0)) * 255).rounded())) }.joined()
    }
}

@MainActor
final class TaskGlowSettings: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var appearance: TaskGlowAppearance

    nonisolated static let terminalDurationOptions: [TimeInterval] = [3, 5, 10, 15, 30, 60]
    static let brightnessRange = 0.2 ... 1.0

    var previewRequests: AnyPublisher<Void, Never> {
        previewSubject.eraseToAnyPublisher()
    }

    private let defaults: UserDefaults
    private let previewSubject = PassthroughSubject<Void, Never>()
    private static let enabledKey = "TaskGlow.isEnabled"
    private static let speedKey = "TaskGlow.animationSpeed"
    private static let durationKey = "TaskGlow.terminalDuration"
    private static let brightnessKey = "TaskGlow.brightness"

    private static func colorKey(_ role: TaskGlowColorRole) -> String {
        "TaskGlow.color.\(role.rawValue)"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        appearance = Self.loadAppearance(from: defaults)
    }

    func refresh() {
        let enabled = defaults.bool(forKey: Self.enabledKey)
        if enabled != isEnabled {
            isEnabled = enabled
        }
        let appearance = Self.loadAppearance(from: defaults)
        if appearance != self.appearance {
            self.appearance = appearance
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

    func setColorHex(_ input: String, for role: TaskGlowColorRole) {
        if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            defaults.removeObject(forKey: Self.colorKey(role))
            appearance.colors[role] = nil
            return
        }
        guard let hex = TaskGlowAppearance.normalizedColorHex(input), appearance.colors[role] != hex else { return }
        defaults.set(hex, forKey: Self.colorKey(role))
        appearance.colors[role] = hex
    }

    func setAnimationSpeed(_ speed: TaskGlowAnimationSpeed) {
        guard appearance.animationSpeed != speed else { return }
        defaults.set(speed.rawValue, forKey: Self.speedKey)
        appearance.animationSpeed = speed
    }

    func setTerminalDuration(_ duration: TimeInterval) {
        guard Self.terminalDurationOptions.contains(duration), appearance.terminalDuration != duration else { return }
        defaults.set(duration, forKey: Self.durationKey)
        appearance.terminalDuration = duration
    }

    func setBrightness(_ brightness: Double) {
        guard brightness.isFinite else { return }
        let value = min(Self.brightnessRange.upperBound, max(Self.brightnessRange.lowerBound, brightness))
        guard appearance.brightness != value else { return }
        defaults.set(value, forKey: Self.brightnessKey)
        appearance.brightness = value
    }

    private static func loadAppearance(from defaults: UserDefaults) -> TaskGlowAppearance {
        var appearance = TaskGlowAppearance()
        for role in TaskGlowColorRole.allCases {
            if let hex = defaults.string(forKey: colorKey(role)), TaskGlowAppearance.decodeColor(hex) != nil {
                appearance.colors[role] = hex
            }
        }
        if let rawSpeed = defaults.string(forKey: speedKey), let speed = TaskGlowAnimationSpeed(rawValue: rawSpeed) {
            appearance.animationSpeed = speed
        }
        let duration = defaults.double(forKey: durationKey)
        if terminalDurationOptions.contains(duration) {
            appearance.terminalDuration = duration
        }
        if defaults.object(forKey: brightnessKey) != nil {
            let brightness = defaults.double(forKey: brightnessKey)
            if brightness.isFinite, brightnessRange.contains(brightness) {
                appearance.brightness = brightness
            }
        }
        return appearance
    }
}
