import Foundation
import SQLite3
import Testing

struct AppServerLogTests {
    @Test func corruptPendingRowPreservesPagingAppendAndClear() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let storage = AppServerLogStore(directoryURL: directory.url)
        let first = storage.beginRequest(method: "healthy", payload: "{}")
        storage.finishRequest(first, response: "ok")
        let broken = storage.beginRequest(method: "broken", payload: "{}")
        _ = try await storage.page()
        var database: OpaquePointer?
        #expect(sqlite3_open(directory.url.appendingPathComponent(AppServerLogStore.databaseName).path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        #expect(sqlite3_exec(database, "UPDATE entries SET payload = x'7B' WHERE id = '\(broken.uuidString)'", nil, nil, nil) == SQLITE_OK)
        let reopened = AppServerLogStore(directoryURL: directory.url)
        let page = try await reopened.page(limit: 1)
        #expect(page.entries.first?.id == broken)
        #expect(page.entries.first?.method == "log/corrupt")
        #expect(page.entries.first?.detail?.hasSuffix("{") == true)
        #expect(page.hasMore)
        let next = try await reopened.page(before: #require(page.entries.first?.position), limit: 1)
        #expect(next.entries.first?.id == first)
        #expect(!next.hasMore)
        reopened.recordFailure(message: "still writes")
        #expect(try await reopened.page().total == 3)
        let again = AppServerLogStore(directoryURL: directory.url)
        #expect(try await again.page().entries.first(where: { $0.id == broken })?.detail == page.entries.first?.detail)
        try await again.clear()
        #expect(try await again.page().total == 0)
    }

    @Test func persistsBeyondFiveHundredAndRestoresOriginalPayloads() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let storage = AppServerLogStore(directoryURL: directory.url)
        for index in 0 ..< 625 {
            let id = storage.beginRequest(method: "probe/\(index)", payload: "{\"secret\":\"unchanged\",\"index\":\(index)}", connection: "activity")
            storage.finishRequest(id, response: " response \(index)\n")
        }
        let page = try await storage.page(limit: 100)
        #expect(page.total == 625)
        #expect(page.entries.count == 100)
        #expect(page.entries.first?.method == "probe/624")
        #expect(page.entries.first?.detail == " response 624\n")
        #expect(page.hasMore)
        let reopened = AppServerLogStore(directoryURL: directory.url)
        let restored = try await reopened.page(limit: 700)
        #expect(restored.total == 625)
        #expect(restored.entries.count == 625)
        #expect(restored.entries.first?.request == "{\"secret\":\"unchanged\",\"index\":624}")
        #expect(restored.entries.last?.method == "probe/0")
        #expect(restored.entries.allSatisfy { $0.status == .success && $0.connection == "activity" })
    }

    @Test func cursorRemainsStableWhileNewRequestsAndOldResponsesArrive() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let storage = AppServerLogStore(directoryURL: directory.url)
        var ids: [UUID] = []
        for index in 0 ..< 12 {
            ids.append(storage.beginRequest(method: "probe/\(index)", payload: "{}"))
        }
        let first = try await storage.page(limit: 5)
        let cursor = try #require(first.entries.last?.position)
        storage.finishRequest(ids[0], response: "late")
        let newest = storage.beginRequest(method: "new", payload: "{}")
        let second = try await storage.page(before: cursor, limit: 5)
        let third = try await storage.page(before: #require(second.entries.last?.position), limit: 5)
        let historical = first.entries + second.entries + third.entries
        #expect(Set(historical.map(\.id)) == Set(ids))
        #expect(historical.count == 12)
        #expect(!third.hasMore)
        #expect(third.entries.last?.detail == "late")
        let changes = try await storage.changes(since: first.revision)
        #expect(Set(changes.entries.map(\.id)) == Set([ids[0], newest]))
    }

    @Test func clearDoesNotResurrectAnInflightRequestAndPersists() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let storage = AppServerLogStore(directoryURL: directory.url)
        let pending = storage.beginRequest(method: "old", payload: "{}")
        let before = try await storage.page()
        try await storage.clear()
        storage.finishRequest(pending, response: "late response")
        let new = storage.beginRequest(method: "new", payload: "{}")
        storage.finishRequest(new, response: "done")
        let after = try await storage.page()
        #expect(after.total == 1)
        #expect(after.entries.first?.id == new)
        #expect(after.generation > before.generation)
        #expect(after.entries.first?.position ?? 0 > before.entries.first?.position ?? 0)
        let reopened = AppServerLogStore(directoryURL: directory.url)
        #expect(try await reopened.page().entries.map(\.id) == [new])
    }

    @Test func unfinishedPreviousRunIsNotShownAsWaitingForever() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        var writer: AppServerLogStore? = AppServerLogStore(directoryURL: directory.url)
        let id = try #require(writer).beginRequest(method: "unfinished", payload: "{}")
        _ = try await writer?.page()
        writer = nil
        let reopened = AppServerLogStore(directoryURL: directory.url)
        let entry = try #require(try await reopened.page().entries.first)
        #expect(entry.id == id)
        #expect(entry.status == .failure)
        #expect(entry.respondedAt == nil)
        #expect(entry.request == "{}")
        #expect(entry.detail != nil)
    }

    @Test func viewMergesLiveUpdatesWithoutDroppingLoadedHistory() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let storage = AppServerLogStore(directoryURL: directory.url)
        var ids: [UUID] = []
        for index in 0 ..< 9 {
            ids.append(storage.beginRequest(method: "probe/\(index)", payload: "{}"))
        }
        let store = AppServerLogViewModel(storage: storage, pageSize: 3)
        await store.refresh()
        #expect(store.entries.count == 3)
        #expect(store.totalCount == 9)
        await store.loadMore()
        let position = store.entries.last?.position
        storage.finishRequest(ids[3], response: "updated")
        let new = storage.beginRequest(method: "new", payload: "{}")
        await store.refresh()
        #expect(store.entries.count == 7)
        #expect(store.entries.first?.id == new)
        #expect(store.entries.last?.position == position)
        #expect(store.entries.last?.detail == "updated")
        await store.loadMore()
        #expect(store.entries.count == 10)
        #expect(Set(store.entries.map(\.id)).count == 10)
        #expect(!store.hasMore)
        await store.clear()
        #expect(store.entries.isEmpty)
        #expect(store.totalCount == 0)
        storage.recordFailure(message: "new failure")
        await store.refresh()
        #expect(store.entries.count == 1)
    }

    @Test func closedWindowCanReloadFromDiskWithBoundedInitialRead() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let storage = AppServerLogStore(directoryURL: directory.url)
        for _ in 0 ..< 10 {
            storage.recordFailure(message: "failure")
        }
        let store = AppServerLogViewModel(storage: storage, pageSize: 3)
        await store.refresh()
        await store.loadMore()
        #expect(store.entries.count == 6)
        store.stop()
        #expect(store.entries.isEmpty)
        storage.recordFailure(message: "closed-window failure")
        await store.refresh()
        #expect(store.entries.count == 3)
        #expect(store.totalCount == 11)
        #expect(store.entries.first?.detail == "closed-window failure")
    }

    @Test func terminationDrainsQueuedWritesAndRejectsLateCallbacks() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let storage = AppServerLogStore(directoryURL: directory.url)
        let id = storage.beginRequest(method: "last", payload: "{}")
        storage.finishRequest(id, response: "saved")
        try await storage.finish()
        storage.recordFailure(message: "after shutdown")
        let reopened = AppServerLogStore(directoryURL: directory.url)
        let page = try await reopened.page()
        #expect(page.total == 1)
        #expect(page.entries.first?.detail == "saved")
    }

    @Test func storageFailureIsVisibleAndDoesNotBreakRequestRecordingCallers() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let file = try directory.write("not a directory", to: "blocked")
        let storage = AppServerLogStore(directoryURL: file)
        storage.recordFailure(message: "recording remains nonthrowing")
        let store = AppServerLogViewModel(storage: storage)
        await store.refresh()
        #expect(store.errorMessage != nil)
        #expect(store.entries.isEmpty)
    }
}

extension AppServerLogTests {
    @Test func retentionPrunesOldPendingRequestsAndLateRepliesStayDeleted() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let storage = AppServerLogStore(directoryURL: directory.url, limits: .init(entries: 10))
        let first = storage.beginRequest(method: "old", payload: "{}")
        let initial = try await storage.page()
        for index in 0 ..< 40 {
            storage.recordFailure(message: "failure-\(index)")
        }
        let retained = try await storage.page()
        #expect(retained.total <= 10)
        #expect(retained.entries.first?.detail == "failure-39")
        #expect(!retained.entries.contains { $0.id == first })
        #expect(retained.generation > initial.generation)
        storage.finishRequest(first, response: "late")
        #expect(try await storage.page().total == retained.total)
    }

    @Test func byteLimitAndUnicodeBodyTruncationAreBoundedAcrossReopen() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let limits = AppServerLogStore.Limits(entries: 100, bytes: 4096, bodyBytes: 256, pageEntries: 10)
        let storage = AppServerLogStore(directoryURL: directory.url, limits: limits)
        let text = String(repeating: "你好🙂", count: 300)
        for index in 0 ..< 30 {
            let id = storage.beginRequest(method: "large-\(index)", payload: text)
            _ = try await storage.page()
            storage.finishRequest(id, response: text)
            _ = try await storage.page()
        }
        let page = try await storage.page(limit: 100)
        #expect(page.total < 30)
        #expect(page.entries.count <= 10)
        for entry in page.entries {
            #expect(entry.requestOriginalBytes == text.utf8.count)
            #expect(entry.detailOriginalBytes == text.utf8.count)
            #expect((entry.request?.utf8.count ?? 0) <= 256)
            #expect((entry.detail?.utf8.count ?? 0) <= 256)
            #expect(entry.request?.contains("Truncated") == true)
            #expect(entry.request?.contains("�") == false)
        }
        try await storage.finish()
        let reopened = AppServerLogStore(directoryURL: directory.url, limits: limits)
        #expect(try await reopened.page().total == page.total)
        let size = try directory.url.appendingPathComponent(AppServerLogStore.databaseName)
            .resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        #expect(size < 128 * 1024)
    }

    @Test func changeOverflowReloadsAndHistoryWindowRemainsBounded() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let storage = AppServerLogStore(directoryURL: directory.url, limits: .init(pageEntries: 5))
        let model = AppServerLogViewModel(storage: storage, pageSize: 3, maximumEntries: 6)
        await model.refresh()
        for index in 0 ..< 20 {
            storage.recordFailure(message: "entry-\(index)")
        }
        await model.refresh()
        #expect(model.entries.count == 3)
        #expect(model.entries.first?.detail == "entry-19")
        var visited = Set(model.entries.map(\.id))
        while model.hasMore {
            await model.loadMore()
            #expect(model.entries.count <= 6)
            visited.formUnion(model.entries.map(\.id))
        }
        #expect(visited.count == 20)
        let historyIDs = model.entries.map(\.id)
        storage.recordFailure(message: "latest")
        await model.refresh()
        #expect(model.entries.count <= 6)
        #expect(model.entries.map(\.id) == historyIDs)
        model.stop()
        await model.refresh()
        #expect(model.entries.first?.detail == "latest")
    }
}

extension AppServerLogTests {
    @Test func requestSourceSurvivesBothSuccessfulAndFailedCompletion() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let storage = AppServerLogStore(directoryURL: directory.url)
        let success = storage.beginRequest(method: "success", payload: "{}")
        let failure = storage.beginRequest(method: "failure", payload: "{}")
        let pending = try await storage.page().entries
        #expect(pending.allSatisfy { $0.source == .request && $0.status == .pending })
        storage.finishRequest(success, response: "{}")
        storage.failRequest(failure, message: "timeout")
        let completed = try await storage.page().entries
        #expect(completed.count == 2)
        #expect(completed.allSatisfy { $0.source == .request })
        #expect(completed.first { $0.id == success }?.status == .success)
        #expect(completed.first { $0.id == failure }?.status == .failure)
    }

    @Test func messageDirectionAndLocalErrorsHaveIndependentStatuses() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let storage = AppServerLogStore(directoryURL: directory.url)
        storage.recordSent(method: "initialized", payload: "{}")
        storage.recordSent(method: "websocket/pong", payload: "ping", error: "disconnected")
        storage.recordReceived(method: "turn/completed", payload: #"{"status":"failed"}"#, connection: "activity")
        storage.recordFailure(method: "activity/storage", message: "disk full")
        let entries = try await storage.page().entries
        #expect(entries.first { $0.method == "initialized" }?.source == .sent)
        #expect(entries.first { $0.method == "initialized" }?.status == .success)
        #expect(entries.first { $0.method == "websocket/pong" }?.source == .sent)
        #expect(entries.first { $0.method == "websocket/pong" }?.status == .failure)
        #expect(entries.first { $0.method == "turn/completed" }?.source == .received)
        #expect(entries.first { $0.method == "turn/completed" }?.status == .information)
        #expect(entries.first { $0.method == "activity/storage" }?.source == .local)
        #expect(entries.first { $0.method == "activity/storage" }?.status == .failure)
    }

    @Test func connectionAttemptFinishesInPlaceAndClosedConnectionIsInformational() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let storage = AppServerLogStore(directoryURL: directory.url)
        let attempt = storage.recordConnection(method: "connection/open", detail: "socket", connection: "activity", status: .pending)
        #expect(try await storage.page().entries.first?.status == .pending)
        storage.finishRequest(attempt, response: "socket")
        let handshake = storage.beginRequest(method: "websocket/handshake", payload: "GET /", source: .connection)
        storage.failRequest(handshake, message: "handshake failed")
        storage.recordConnection(method: "connection/closed", detail: "socket", connection: "activity", status: .information)
        let entries = try await storage.page().entries
        #expect(entries.allSatisfy { $0.source == .connection })
        #expect(entries.first { $0.id == attempt }?.status == .success)
        #expect(entries.first { $0.id == handshake }?.status == .failure)
        #expect(entries.first { $0.method == "connection/closed" }?.status == .information)
        let reopened = AppServerLogStore(directoryURL: directory.url)
        #expect(try await reopened.page().entries == entries)
    }
}
