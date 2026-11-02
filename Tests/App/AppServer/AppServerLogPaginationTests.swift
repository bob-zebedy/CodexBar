import Foundation
import Testing

@Suite(.tags(.integration))
struct AppServerLogPaginationTests {
    @Test(arguments: [false, true])
    func interruptedWaitingRequestAllowsLaterPagination(stopObservation: Bool) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let readGate = AppServerLogReadGate()
        let storage = AppServerLogStore(directoryURL: directory.url, now: { readGate.now() })
        defer { await #expect(throws: Never.self) { try await storage.close() } }
        defer { readGate.release() }
        for index in 0 ..< 9 {
            storage.recordFailure(message: "entry-\(index)")
        }
        let model = AppServerLogViewModel(storage: storage, pageSize: 3)
        await model.refresh()
        readGate.arm()
        let refresh = Task { await model.refresh() }
        defer { refresh.cancel() }
        try #require(try await waitForCondition(timeout: .seconds(1), pollInterval: .milliseconds(5)) {
            readGate.didBlock
        })
        var didRequestPage = false
        let request = Task {
            didRequestPage = true
            await model.loadMore()
        }
        defer { request.cancel() }
        try #require(try await waitForCondition(timeout: .seconds(1), pollInterval: .milliseconds(5)) {
            didRequestPage
        })
        if stopObservation {
            model.stop()
        } else {
            request.cancel()
        }
        await request.value
        readGate.release()
        await refresh.value
        await model.refresh()
        #expect(model.entries.count == 3)
        await model.loadMore()
        #expect(model.entries.count == 6)
        #expect(model.entries.last?.detail == "entry-3")
        #expect(!model.isLoading)
    }

    @Test(arguments: [false, true])
    func overlappingRequestsLoadOnlyOnePage(waitingForRefresh: Bool) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let readGate = AppServerLogReadGate()
        let storage = AppServerLogStore(directoryURL: directory.url, now: { readGate.now() })
        defer { await #expect(throws: Never.self) { try await storage.close() } }
        defer { readGate.release() }
        for index in 0 ..< 15 {
            storage.recordFailure(message: "entry-\(index)")
        }
        let model = AppServerLogViewModel(storage: storage, pageSize: 3)
        await model.refresh()
        readGate.arm()
        let firstRead = Task {
            if waitingForRefresh {
                await model.refresh()
            } else {
                await model.loadMore()
            }
        }
        defer { firstRead.cancel() }
        try #require(try await waitForCondition(timeout: .seconds(1), pollInterval: .milliseconds(5)) {
            readGate.didBlock
        })
        var startedRequests = 0
        let requests = (0 ..< 3).map { _ in
            Task {
                startedRequests += 1
                await model.loadMore()
            }
        }
        defer { requests.forEach { $0.cancel() } }
        try #require(try await waitForCondition(timeout: .seconds(1), pollInterval: .milliseconds(5)) {
            startedRequests == requests.count
        })
        readGate.release()
        await firstRead.value
        for request in requests {
            await request.value
        }
        #expect(model.entries.count == 6)
        #expect(model.entries.last?.detail == "entry-9")
        #expect(model.hasMore)
        #expect(!model.isLoading)
        await model.loadMore()
        #expect(model.entries.count == 9)
        #expect(model.entries.last?.detail == "entry-6")
    }
}
