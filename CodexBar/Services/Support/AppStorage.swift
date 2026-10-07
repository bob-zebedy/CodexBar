import Foundation

nonisolated enum AppStorage {
    #if DEBUG
        static let directoryName = "CodexBar Data Debug"
    #else
        static let directoryName = "CodexBar Data"
    #endif

    static func directoryURL(fileManager: FileManager = .default) -> URL {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        return applicationSupport.appendingPathComponent(directoryName, isDirectory: true)
    }
}
