import SwiftUI

struct BridgeSettingsView: View {
    let host: BridgeHost
    @State private var listening = false
    @State private var listState = ConfigurationListState.loading
    @State private var loadAttempt = 0
    @State private var page = Page.configurations
    @State private var configurationToDelete: BridgeConfiguration?
    @State private var busy = false
    @State private var errorMessage: String?

    private enum ConfigurationListState {
        case loading, loaded([BridgeConfiguration]), unavailable
    }

    private enum Page {
        case configurations, editor(BridgeConfiguration?)
        case detail(BridgeConfiguration)

        var showsBackButton: Bool {
            if case .configurations = self {
                return false
            }
            return true
        }

        var title: String {
            switch self {
            case .configurations: String(localized: "bridge.configuration.list.title")
            case .editor(nil): String(localized: "bridge.configuration.new")
            case .editor: String(localized: "bridge.configuration.edit")
            case let .detail(configuration): configuration.name
            }
        }
    }

    init(host: BridgeHost = .shared) {
        self.host = host
    }

    var body: some View {
        VStack(spacing: 0) {
            switch listState {
            case let .loaded(configurations):
                header
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                Divider()
                content(configurations)
            case .loading:
                BridgeSettingsPage {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .unavailable:
                BridgeSettingsPage {
                    ContentUnavailableView {
                        Label("bridge.configuration.list.unavailable", systemImage: "exclamationmark.circle")
                    } actions: {
                        Button("common.action.retry") { loadAttempt += 1 }
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .disabled(busy)
        .alert(
            Text("bridge.configuration.delete.confirmation.title \(configurationToDelete?.name ?? "")"),
            isPresented: Binding(
                get: { configurationToDelete != nil },
                set: {
                    if !$0 {
                        configurationToDelete = nil
                    }
                }
            ),
            presenting: configurationToDelete
        ) { configuration in
            Button("common.action.cancel", role: .cancel) {}
            Button("bridge.configuration.delete.action", role: .destructive) {
                perform {
                    try await host.deleteConfiguration(configuration.id)
                    navigate(to: .configurations)
                }
            }
        } message: { _ in
            Text("bridge.configuration.delete.confirmation.message")
        }
        .environment(\.bridgeListening, listening)
        .task {
            for await value in await host.listeningUpdates() {
                listening = value
            }
        }
        .task(id: loadAttempt) { await observeConfigurations() }
    }

    @ViewBuilder private func content(_ configurations: [BridgeConfiguration]) -> some View {
        switch page {
        case .configurations:
            BridgeSettingsPage(errorMessage: errorMessage) {
                BridgeConfigurationList(
                    configurations: configurations,
                    showDetails: { navigate(to: .detail($0)) },
                    editConfiguration: { navigate(to: .editor($0)) },
                    requestDeletion: { configurationToDelete = $0 }
                )
            }
        case let .editor(configuration):
            BridgeConfigurationForm(configuration: configuration, errorMessage: errorMessage) { name, permissions in
                perform {
                    if let configuration {
                        try await host.runtime.updateConfiguration(configuration.id, name: name, permissions: permissions)
                    } else {
                        _ = try await host.runtime.createConfiguration(name: name, permissions: permissions)
                    }
                    navigate(to: .configurations)
                }
            }
        case let .detail(configuration):
            BridgeSettingsPage(errorMessage: errorMessage) {
                BridgeConfigurationDetailView(configuration: configuration, host: host)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            if page.showsBackButton {
                Button { navigate(to: .configurations) } label: {
                    Label("common.action.back", systemImage: "chevron.backward")
                        .labelStyle(.iconOnly)
                        .frame(width: 16, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            Text(verbatim: page.title)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 12)
            switch page {
            case .configurations:
                Button("bridge.configuration.new", systemImage: "plus") { navigate(to: .editor(nil)) }
                    .buttonStyle(.borderedProminent)
            case let .detail(configuration):
                Button("bridge.configuration.delete.action", systemImage: "trash", role: .destructive) { configurationToDelete = configuration }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .fixedSize()
            case .editor:
                EmptyView()
            }
        }
        .frame(minHeight: 26)
    }

    private func navigate(to nextPage: Page) {
        page = nextPage
        errorMessage = nil
    }

    private func observeConfigurations() async {
        listState = .loading
        do {
            let updates = try await host.runtime.configurationUpdates()
            for await configurations in updates {
                guard !Task.isCancelled else { return }
                listState = .loaded(configurations)
            }
        } catch {
            guard !Task.isCancelled else { return }
            listState = .unavailable
        }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        errorMessage = nil
        Task {
            defer { busy = false }
            do { try await action() } catch { errorMessage = error.localizedDescription }
        }
    }
}
