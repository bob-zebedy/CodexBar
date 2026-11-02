import Foundation
import SQLite3
import Testing

@Suite(.tags(.integration))
struct AppServerLogFilterTests {
    @Test func methodChoicesAndFilteredPagesCoverUnloadedHistory() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let storage = AppServerLogStore(directoryURL: directory.url)
        defer { await #expect(throws: Never.self) { try await storage.close() } }
        let quoted = "test/'\"接口"
        let oldest = storage.beginRequest(method: quoted, payload: "{}")
        storage.recordFailure(message: "without method")
        for index in 0 ..< 9 {
            storage.recordReceived(method: index.isMultiple(of: 2) ? "thread/read" : "account/read", payload: "{}", connection: "test")
        }
        let methods = try await storage.methods()
        #expect(methods == ["account/read", quoted, "thread/read"])
        #expect(try await storage.page(limit: 2, methods: [quoted]).entries.map(\.id) == [oldest])

        let first = try await storage.page(limit: 2, methods: ["account/read", quoted])
        #expect(first.entries.map(\.method) == ["account/read", "account/read"])
        #expect(first.hasMore)
        #expect(first.total == 11)
        let second = try await storage.page(before: first.entries.last?.position, limit: 2, methods: ["account/read", quoted])
        let third = try await storage.page(before: second.entries.last?.position, limit: 2, methods: ["account/read", quoted])
        #expect(second.entries.count == 2)
        #expect(second.hasMore)
        #expect(third.entries.map(\.id) == [oldest])
        #expect(!third.hasMore)
        let missing = try await storage.page(methods: ["missing"])
        #expect(missing.entries.isEmpty)
        #expect(!missing.hasMore)
        #expect(try await storage.page().entries.count == 11)

        storage.finishRequest(oldest, response: "completed")
        storage.recordReceived(method: "ignored", payload: "{}", connection: "test")
        let changes = try await storage.changes(since: first.revision, methods: [quoted])
        #expect(changes.entries.map(\.id) == [oldest])
        #expect(changes.entries.first?.detail == "completed")
        #expect(changes.total == 12)
        #expect(try await storage.changes(since: changes.revision, methods: [quoted]).entries.isEmpty)
    }

    @Test func filteredHistoryResumesLiveUpdatesAndRemovingSelectionsRestoresAll() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let storage = AppServerLogStore(directoryURL: directory.url)
        defer { await #expect(throws: Never.self) { try await storage.close() } }
        for index in 0 ..< 18 {
            storage.recordReceived(method: index.isMultiple(of: 2) ? "selected" : "other", payload: "entry-\(index)", connection: "test")
        }
        let model = AppServerLogViewModel(storage: storage, pageSize: 3, maximumEntries: 6)
        model.setSelectedMethods(["selected"])
        await model.refresh()
        #expect(model.entries.first?.detail == "entry-16")
        await model.loadMore()
        await model.loadMore()
        #expect(model.entries.count == 6)
        #expect(model.entries.allSatisfy { $0.method == "selected" })
        #expect(!model.hasMore)
        storage.recordReceived(method: "selected", payload: "latest match", connection: "test")
        storage.recordReceived(method: "other", payload: "latest other", connection: "test")
        await model.refresh()
        #expect(model.entries.first?.detail != "latest match")
        await model.resumeFollowingLatest()
        #expect(model.entries.first?.detail == "latest match")
        #expect(model.entries.count == 3)
        #expect(model.hasMore)
        storage.recordReceived(method: "other", payload: "ignored", connection: "test")
        await model.refresh()
        #expect(model.entries.count == 3)
        #expect(model.totalCount == 21)

        model.setSelectedMethods(["missing"])
        #expect(model.entries.isEmpty)
        await model.refresh()
        #expect(model.entries.isEmpty)
        #expect(!model.hasMore)
        storage.recordReceived(method: "missing", payload: "first match", connection: "test")
        await model.refresh()
        #expect(model.entries.first?.detail == "first match")

        model.setSelectedMethods([])
        await model.refresh()
        #expect(model.entries.map(\.method) == ["missing", "other", "other"])
        #expect(model.totalCount == 22)
        await model.clear()
        #expect(model.entries.isEmpty)
        #expect(try await model.availableMethods().isEmpty)
    }

    @Test func changingSelectionDiscardsInFlightPages() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let readGate = AppServerLogReadGate()
        let storage = AppServerLogStore(directoryURL: directory.url, now: { readGate.now() })
        defer { await #expect(throws: Never.self) { try await storage.close() } }
        defer { readGate.release() }
        storage.recordReceived(method: "selected", payload: "oldest", connection: "test")
        for _ in 0 ..< 6 {
            storage.recordReceived(method: "other", payload: "{}", connection: "test")
        }
        let model = AppServerLogViewModel(storage: storage, pageSize: 2)
        await model.refresh()
        readGate.arm()
        let page = Task { await model.loadMore() }
        defer { page.cancel() }
        try #require(try await waitForCondition(timeout: .seconds(1), pollInterval: .milliseconds(5)) {
            readGate.didBlock
        })
        model.setSelectedMethods(["selected"])
        let refresh = Task { await model.refresh() }
        defer { refresh.cancel() }
        readGate.release()
        await page.value
        await refresh.value
        #expect(model.entries.count == 1)
        #expect(model.entries.first?.method == "selected")
        #expect(!model.isLoading)
        #expect(!model.hasMore)
    }

    @Test func corruptPayloadDoesNotBreakMethodDiscoveryOrFiltering() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let storage = AppServerLogStore(directoryURL: directory.url)
        defer { await #expect(throws: Never.self) { try await storage.close() } }
        let corrupt = storage.beginRequest(method: "broken", payload: "{}")
        storage.recordReceived(method: "healthy", payload: "{}", connection: "test")
        _ = try await storage.page()
        var database: OpaquePointer?
        #expect(sqlite3_open(directory.url.appendingPathComponent(AppServerLogStore.databaseName).path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        #expect(sqlite3_exec(database, "UPDATE entries SET payload = x'7B' WHERE id = '\(corrupt.uuidString)'", nil, nil, nil) == SQLITE_OK)
        #expect(try await storage.methods() == ["healthy", "log/corrupt"])
        #expect(try await storage.page(methods: ["healthy"]).entries.count == 1)
        let page = try await storage.page(methods: ["log/corrupt"])
        #expect(page.entries.map(\.id) == [corrupt])
        #expect(page.entries.first?.method == "log/corrupt")
    }
}
