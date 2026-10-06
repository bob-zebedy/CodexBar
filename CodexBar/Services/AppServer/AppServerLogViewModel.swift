import Combine
import Foundation

@MainActor
final class AppServerLogViewModel: ObservableObject {
    static let shared = AppServerLogViewModel()

    @Published private(set) var entries: [AppServerLogEntry] = []
    @Published private(set) var totalCount = 0
    @Published private(set) var hasMore = false
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let storage: AppServerLogStore
    private let pageSize: Int
    private let maximumEntries: Int
    @Published private(set) var browsingHistory = false
    private var revision: Int64 = 0
    private var generation: Int64 = 0
    private var isLoaded = false
    private var isReading = false
    private var observation: Task<Void, Never>?
    private var observationGeneration = 0

    init(storage: AppServerLogStore = .shared, pageSize: Int = 100, maximumEntries: Int = 1000) {
        self.storage = storage
        self.pageSize = min(pageSize, maximumEntries)
        self.maximumEntries = maximumEntries
    }

    func start() {
        guard observation == nil else { return }
        observationGeneration += 1
        observation = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await refresh()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func stop() {
        observationGeneration += 1
        observation?.cancel()
        observation = nil
        entries = []
        totalCount = 0
        hasMore = false
        isLoaded = false
        isReading = false
        isLoading = false
    }

    func refresh() async {
        guard !isReading else { return }
        let current = observationGeneration
        isReading = true
        isLoading = !isLoaded
        defer {
            if current == observationGeneration {
                isReading = false
                isLoading = false
            }
        }
        do {
            if !isLoaded {
                try await loadFirst(current: current)
            } else {
                let changes = try await storage.changes(since: revision)
                guard current == observationGeneration else { return }
                if changes.generation != generation || changes.hasMore {
                    try await loadFirst(current: current)
                } else {
                    if !changes.entries.isEmpty {
                        let newest = entries.first?.position ?? 0
                        var byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
                        for entry in changes.entries where byID[entry.id] != nil || (!browsingHistory && entry.position > newest) {
                            byID[entry.id] = entry
                        }
                        entries = Array(byID.values.sorted { $0.position > $1.position }.prefix(maximumEntries))
                    }
                    revision = changes.revision
                    totalCount = changes.total
                    let oldest = try await storage.page(before: entries.last?.position, limit: 1)
                    guard current == observationGeneration else { return }
                    hasMore = !oldest.entries.isEmpty
                }
            }
            errorMessage = nil
        } catch {
            if current == observationGeneration {
                errorMessage = error.localizedDescription
            }
        }
    }

    func loadMore() async {
        let waitingGeneration = observationGeneration
        while isReading {
            do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
            guard waitingGeneration == observationGeneration else { return }
        }
        guard !Task.isCancelled, hasMore, let cursor = entries.last?.position else { return }
        let current = observationGeneration
        isReading = true
        isLoading = true
        defer {
            if current == observationGeneration {
                isReading = false
                isLoading = false
            }
        }
        do {
            let page = try await storage.page(before: cursor, limit: pageSize)
            guard current == observationGeneration else { return }
            if page.generation != generation {
                try await loadFirst(current: current)
            } else {
                let existing = Set(entries.map(\.id))
                entries.append(contentsOf: page.entries.filter { !existing.contains($0.id) })
                if entries.count > maximumEntries {
                    entries.removeFirst(entries.count - maximumEntries)
                    browsingHistory = true
                }
                hasMore = page.hasMore
                totalCount = page.total
            }
            errorMessage = nil
        } catch {
            if current == observationGeneration {
                errorMessage = error.localizedDescription
            }
        }
    }

    func showLatest() async {
        guard !isReading else { return }
        isLoaded = false
        await refresh()
    }

    func clear() async {
        let waitingGeneration = observationGeneration
        while isReading {
            do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
            guard waitingGeneration == observationGeneration else { return }
        }
        guard !Task.isCancelled else { return }
        let current = observationGeneration
        isReading = true
        isLoading = true
        defer {
            if current == observationGeneration {
                isReading = false
                isLoading = false
            }
        }
        do {
            try await storage.clear()
            try await loadFirst(current: current)
            if current == observationGeneration {
                errorMessage = nil
            }
        } catch {
            if current == observationGeneration {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func loadFirst(current: Int) async throws {
        let page = try await storage.page(limit: pageSize)
        guard current == observationGeneration else { return }
        entries = page.entries
        browsingHistory = false
        revision = page.revision
        generation = page.generation
        totalCount = page.total
        hasMore = page.hasMore
        isLoaded = true
    }
}
