import SwiftUI

struct SettingsHelpLabel: View {
    let title: LocalizedStringResource
    let help: LocalizedStringResource
    @State private var anchorProvider = ScreenFrameProvider()
    @State private var helpPresenter = SettingsHelpPresenter()

    var body: some View {
        HStack(spacing: 4) {
            Text(title)

            Image(systemName: "questionmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
                .fixedSize()
                .background {
                    ScreenFrameReader(provider: anchorProvider) { frame in
                        helpPresenter.updateAnchorFrame(frame)
                    }
                }
                .onHover { isHovered in
                    if isHovered {
                        helpPresenter.show(help, anchorProvider: anchorProvider)
                    } else {
                        helpPresenter.hide()
                    }
                }
        }
        .onDisappear {
            helpPresenter.hide()
        }
    }
}
