import SwiftUI

struct MainPanelEntranceAnimationsSettingsRow: View {
    @ObservedObject var settings: MainPanelSettings

    var body: some View {
        SettingsToggleRow(
            icon: "sparkles",
            title: "settings.main-panel.entrance-animations",
            isOn: Binding(
                get: { settings.areEntranceAnimationsEnabled },
                set: { settings.setEntranceAnimationsEnabled($0) }
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
            title: "settings.screen-edge-indicator.title",
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
