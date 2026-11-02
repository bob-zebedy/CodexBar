import AppKit
import SwiftUI
import Testing

struct LogMethodFilterTests {
    @Test(arguments: [CGFloat(120), 320, 600], [0, 1, 8])
    func selectionsKeepTheHeaderCompact(width: CGFloat, selectionCount: Int) throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let storage = AppServerLogStore(directoryURL: directory.url)
        let model = AppServerLogViewModel(storage: storage)
        let emptyHost = NSHostingView(rootView: LogMethodFilter(store: model).frame(width: width))
        let emptySize = emptyHost.fittingSize
        model.setSelectedMethods(Set((0 ..< selectionCount).map { "thread/long-method-name/\($0)" }))
        let host = NSHostingView(rootView: LogMethodFilter(store: model).frame(width: width))
        #expect(host.fittingSize.width == width)
        #expect(host.fittingSize.height > 0)
        #expect(host.fittingSize.height <= 40)
        #expect(host.fittingSize.height == emptySize.height)
    }
}
