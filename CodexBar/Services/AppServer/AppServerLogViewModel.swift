import Combine
import Foundation

@MainActor
final class AppServerLogViewModel: ObservableObject {
    @Published private(set) var entries: [AppServerLogEntry] = []
    @Published private(set) var totalCount = 0
    @Published private(set) var hasMore = false
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var selectedMethods: Set<String> = []

    private let storage: AppServerLogStore
    private let pageSize: Int
    private let maximumEntries: Int
    private var isFollowingLatest = true
    private var needsLatestReload = false
    private var revision: Int64 = 0
    private var generation: Int64 = 0
    private var isLoaded = false
    private var isReading = false
    private var isPaging = false
    private var observation: Task<Void, Never>?
    private var observationGeneration = 0

    init(storage: AppServerLogStore, pageSize: Int = 100, maximumEntries: Int = 1000) {
        self.storage = storage
        self.pageSize = min(pageSize, maximumEntries)
        self.maximumEntries = maximumEntries
    }

    func start() {
        guard observation == nil else { return }
        observation = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await refresh()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func stop() {
        // 只在停止观察时使在途读取失效, 启动轮询继续复用当前读取
        observationGeneration += 1
        observation?.cancel()
        observation = nil
        entries = []
        totalCount = 0
        hasMore = false
        isFollowingLatest = true
        needsLatestReload = false
        isLoaded = false
        isReading = false
        isPaging = false
        isLoading = false
    }

    func refresh() async {
        guard !isReading else { return }
        let current = observationGeneration
        isReading = true
        if !isLoaded {
            isLoading = true
        }
        defer {
            if current == observationGeneration {
                isReading = false
                if isLoading {
                    isLoading = false
                }
            }
        }
        do {
            if !isLoaded {
                try await loadFirst(current: current)
            } else {
                let changes = try await storage.changes(since: revision, methods: selectedMethods)
                guard current == observationGeneration else { return }
                let invalidated = changes.generation != generation || changes.hasMore
                if invalidated, isFollowingLatest {
                    try await loadFirst(current: current)
                } else if changes.revision != revision {
                    needsLatestReload = needsLatestReload || invalidated
                    let previousOldest = entries.last?.position
                    mergeEntries(changes.entries)
                    if invalidated || entries.last?.position != previousOldest {
                        let oldest = try await storage.page(before: entries.last?.position, limit: 1, methods: selectedMethods)
                        guard current == observationGeneration else { return }
                        let more = !oldest.entries.isEmpty
                        if hasMore != more {
                            hasMore = more
                        }
                    }
                    revision = changes.revision
                    generation = changes.generation
                    if totalCount != changes.total {
                        totalCount = changes.total
                    }
                }
            }
            if errorMessage != nil {
                errorMessage = nil
            }
        } catch {
            if current == observationGeneration, errorMessage != error.localizedDescription {
                errorMessage = error.localizedDescription
            }
        }
    }

    func setSelectedMethods(_ methods: Set<String>) {
        guard selectedMethods != methods else { return }
        // 切换筛选使旧分页失效, 轮询任务继续读取新的筛选结果
        observationGeneration += 1
        selectedMethods = methods
        entries = []
        hasMore = false
        isFollowingLatest = true
        needsLatestReload = false
        isLoaded = false
        isReading = false
        isPaging = false
        isLoading = true
        errorMessage = nil
    }

    func availableMethods() async throws -> [String] {
        try await storage.methods()
    }

    private func mergeEntries(_ updates: [AppServerLogEntry]) {
        guard !updates.isEmpty else { return }
        let newest = entries.first?.position ?? 0
        if !isFollowingLatest, updates.contains(where: { $0.position > newest }) {
            needsLatestReload = true
        }
        var byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        for entry in updates where byID[entry.id] != nil || (isFollowingLatest && entry.position > newest) {
            byID[entry.id] = entry
        }
        let updated = Array(byID.values.sorted { $0.position > $1.position }.prefix(maximumEntries))
        if entries != updated {
            entries = updated
        }
    }

    func pauseFollowingLatest() {
        isFollowingLatest = false
    }

    func resumeFollowingLatest() async {
        let current = observationGeneration
        while isReading {
            do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
            guard current == observationGeneration else { return }
        }
        guard !Task.isCancelled, isLoaded else { return }
        isFollowingLatest = true
        guard needsLatestReload else { return }
        // 历史分页会移除较新的缓存, 增量游标也已越过浏览期间的新日志
        isLoaded = false
        await refresh()
    }

    func loadMore() async {
        guard !Task.isCancelled, !isPaging, hasMore, let cursor = entries.last?.position else { return }
        let waitingGeneration = observationGeneration
        // 等待后台刷新时也标记为正在分页, 避免重复请求排队加载后续页
        isPaging = true
        defer {
            if waitingGeneration == observationGeneration {
                isPaging = false
            }
        }
        while isReading {
            do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
            guard waitingGeneration == observationGeneration else { return }
        }
        guard !Task.isCancelled, hasMore, entries.last?.position == cursor else { return }
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
            let page = try await storage.page(before: cursor, limit: pageSize, methods: selectedMethods)
            guard current == observationGeneration else { return }
            if page.generation != generation, isFollowingLatest {
                try await loadFirst(current: current)
            } else {
                if page.generation != generation {
                    needsLatestReload = true
                }
                let existing = Set(entries.map(\.id))
                entries.append(contentsOf: page.entries.filter { !existing.contains($0.id) })
                if entries.count > maximumEntries {
                    entries.removeFirst(entries.count - maximumEntries)
                    isFollowingLatest = false
                    needsLatestReload = true
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
            guard current == observationGeneration else { return }
            isLoaded = false
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
        let page = try await storage.page(limit: pageSize, methods: selectedMethods)
        guard current == observationGeneration else { return }
        // 读取最新页期间可能已开始浏览, 后台重载不能替换正在阅读的内容
        if isLoaded, !isFollowingLatest {
            needsLatestReload = true
            return
        }
        entries = page.entries
        isFollowingLatest = true
        needsLatestReload = false
        revision = page.revision
        generation = page.generation
        totalCount = page.total
        hasMore = page.hasMore
        isLoaded = true
    }
}
