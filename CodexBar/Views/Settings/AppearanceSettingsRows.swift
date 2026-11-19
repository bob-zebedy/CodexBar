import SwiftUI

struct MainPanelAnimationsSettingsRow: View {
    @ObservedObject var settings: MainPanelSettings

    var body: some View {
        SettingsToggleRow(
            icon: "sparkles",
            title: "settings.main-panel.animations",
            help: "settings.main-panel.animations.help",
            isOn: Binding(
                get: { settings.areAnimationsEnabled },
                set: { settings.setAnimationsEnabled($0) }
            )
        )
    }
}

struct TaskGlowSettingsRow: View {
    @ObservedObject var settings: TaskGlowSettings
    let onOptionsAction: (SettingsOptionsPanelAction) -> Void
    @State private var anchorProvider = ScreenFrameProvider()

    var body: some View {
        SettingsToggleRow(
            icon: "light.max",
            title: "settings.task-glow.title",
            help: "settings.task-glow.title.help",
            isOn: Binding(
                get: { settings.isEnabled },
                set: { settings.setEnabled($0) }
            )
        ) {
            SettingsOptionsButton(
                panel: .taskGlow,
                isAvailable: settings.isEnabled,
                anchorProvider: anchorProvider,
                onOptionsAction: onOptionsAction
            )
        }
        .background {
            ScreenFrameReader(provider: anchorProvider)
        }
    }
}
