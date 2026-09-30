import SwiftUI

struct MainPanelAnimationsSettingsRow: View {
    @ObservedObject var settings: MainPanelSettings

    var body: some View {
        SettingsToggleRow(
            icon: "sparkles",
            title: "settings.main-panel.animations",
            isOn: Binding(
                get: { settings.areAnimationsEnabled },
                set: { settings.setAnimationsEnabled($0) }
            )
        )
    }
}

struct TaskGlowSettingsRow: View {
    @ObservedObject var settings: TaskGlowSettings
    @ObservedObject var codexHookSettings: CodexHookSettings
    let onOptionsAction: (SettingsOptionsPanelAction) -> Void
    @State private var anchorProvider = ScreenFrameProvider()

    private var canShowOptions: Bool {
        settings.isEnabled && codexHookSettings.isOperable && !codexHookSettings.isUpdating
    }

    var body: some View {
        SettingsToggleRow(
            icon: "light.max",
            title: "settings.task-glow.title",
            isOn: Binding(
                get: { codexHookSettings.isOperable && settings.isEnabled },
                set: { settings.setEnabled($0) }
            ),
            isEnabled: codexHookSettings.isOperable && !codexHookSettings.isUpdating
        ) {
            SettingsOptionsButton(isAvailable: canShowOptions) {
                onOptionsAction(.toggle(panel: .taskGlow, anchorProvider: anchorProvider))
            }
        }
        .background {
            ScreenFrameReader(provider: anchorProvider)
        }
        .onChange(of: canShowOptions) { _, available in
            if !available {
                onOptionsAction(.close(panel: .taskGlow))
            }
        }
    }
}
