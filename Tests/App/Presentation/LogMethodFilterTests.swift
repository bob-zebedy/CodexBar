import AppKit
import SwiftUI
import Testing

struct LogMethodFilterTests {
    @Test(.tags(.integration)) func emptyMessageFollowsStoreCountWhileFilterStaysSelected() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let storage = AppServerLogStore(directoryURL: directory.url)
        defer { await #expect(throws: Never.self) { try await storage.close() } }
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let model = AppServerLogViewModel(storage: storage)
        let view = LogView(viewModel: model, mainPanelSettings: MainPanelSettings(defaults: preferences.defaults))
        model.setSelectedMethods(["thread/read"])
        await model.refresh()
        #expect(view.emptyStateTitle.key == "log.empty.no-entries")
        storage.recordSent(method: "account/read", payload: "{}")
        await model.refresh()
        #expect(model.entries.isEmpty && model.totalCount == 1)
        #expect(view.emptyStateTitle.key == "log.empty.no-filter-matches")
    }

    @Test(arguments: [CGFloat(120), 320, 600], [1, 8])
    func selectionsKeepTheHeaderCompact(width: CGFloat, selectionCount: Int) throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let storage = AppServerLogStore(directoryURL: directory.url)
        let model = AppServerLogViewModel(storage: storage)
        let emptyHost = NSHostingView(rootView: LogMethodFilter(viewModel: model).frame(width: width))
        let emptySize = emptyHost.fittingSize
        model.setSelectedMethods(Set((0 ..< selectionCount).map { "thread/long-method-name/\($0)" }))
        let host = NSHostingView(rootView: LogMethodFilter(viewModel: model).frame(width: width))
        #expect(host.fittingSize.width == width)
        #expect(host.fittingSize.height > 0)
        #expect(host.fittingSize.height <= 40)
        #expect(host.fittingSize.height == emptySize.height)
    }
}
