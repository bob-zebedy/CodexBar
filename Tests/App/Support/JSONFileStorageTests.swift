import Darwin
import Foundation
import Testing

struct JSONFileStorageTests {
    @Test nonisolated func nonblockingLockRejectsAnotherOwnerAndCanBeReacquired() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }

        do {
            let descriptor = try #require(try JSONFileStorage.acquireLock(at: directory.url.appendingPathComponent("sync.lock"), nonblocking: true))
            defer { JSONFileStorage.releaseLock(descriptor) }

            let started = ContinuousClock.now
            let duplicate = try JSONFileStorage.acquireLock(at: directory.url.appendingPathComponent("sync.lock"), nonblocking: true)
            defer {
                if let duplicate {
                    JSONFileStorage.releaseLock(duplicate)
                }
            }
            #expect(duplicate == nil)
            #expect(started.duration(to: .now) < .seconds(1))
            try JSONFileStorage.withLock(at: directory.url.appendingPathComponent("store.lock")) {}
        }

        let replacement = try #require(try JSONFileStorage.acquireLock(at: directory.url.appendingPathComponent("sync.lock"), nonblocking: true))
        JSONFileStorage.releaseLock(replacement)
    }

    @Test nonisolated func lockDoesNotSurviveExec() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let descriptor = try #require(try JSONFileStorage.acquireLock(at: directory.url.appendingPathComponent("store.lock"), nonblocking: true))
        defer { JSONFileStorage.releaseLock(descriptor) }

        let flags = fcntl(descriptor, F_GETFD)
        #expect(flags >= 0)
        #expect(flags & FD_CLOEXEC != 0)
    }

    @Test nonisolated func independentDirectoriesDoNotBlockEachOther() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }

        let first = try #require(try JSONFileStorage.acquireLock(at: directory.url.appendingPathComponent("first/store.lock"), nonblocking: true))
        defer { JSONFileStorage.releaseLock(first) }
        let second = try #require(try JSONFileStorage.acquireLock(at: directory.url.appendingPathComponent("second/store.lock"), nonblocking: true))
        defer { JSONFileStorage.releaseLock(second) }
    }

    @Test nonisolated func storageFailureIsDistinctFromLockContention() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let fileURL = try directory.write(Data(), to: "file")

        #expect(throws: (any Error).self) {
            try JSONFileStorage.acquireLock(at: fileURL.appendingPathComponent("store.lock"), nonblocking: true)
        }
    }
}
