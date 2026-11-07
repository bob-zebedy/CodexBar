import Combine
import Foundation
import Testing

struct TUINotificationSettingsTests {
    @Test func unavailableConnectionDoesNotReadOrWriteConfiguration() {
        let connection = CurrentValueSubject<Bool, Never>(false)
        let settings = TUINotificationSettings(
            connectionAvailability: connection.eraseToAnyPublisher(),
            read: { Issue.record("Unavailable connection must not read configuration")
                return true
            },
            write: { _ in Issue.record("Unavailable connection must not write configuration") }
        )
        settings.refresh()
        settings.setEnabled(false)
        settings.setEnabled(true)
        #expect(!settings.isAvailable)
        #expect(settings.isEnabled == nil)
        #expect(!settings.isUpdating)
        #expect(settings.errorMessage == nil)
    }

    @Test(arguments: [false, true])
    func reconnectReadsActualSettingWithoutWritingPlaceholder(_ initialValue: Bool) async throws {
        let connection = CurrentValueSubject<Bool, Never>(false)
        let configuration = Configuration()
        configuration.isEnabled = initialValue
        var reads = 0
        let settings = TUINotificationSettings(
            connectionAvailability: connection.eraseToAnyPublisher(),
            read: { reads += 1
                return configuration.isEnabled
            },
            write: { _ in Issue.record("Connection changes must not write configuration") }
        )
        connection.send(true)
        #expect(!settings.isAvailable)
        #expect(settings.isUpdating)
        #expect(try await waitForCondition(timeout: .seconds(2), pollInterval: .milliseconds(5)) { !settings.isUpdating })
        #expect(settings.isAvailable)
        #expect(settings.isEnabled == initialValue)
        connection.send(true)
        #expect(reads == 1)

        connection.send(false)
        #expect(!settings.isAvailable)
        #expect(settings.isEnabled == nil)
        settings.setEnabled(!initialValue)
        configuration.isEnabled = !initialValue
        connection.send(true)
        #expect(try await waitForCondition(timeout: .seconds(2), pollInterval: .milliseconds(5)) { !settings.isUpdating })
        #expect(settings.isAvailable)
        #expect(settings.isEnabled == !initialValue)
        #expect(reads == 2)
    }

    @Test(arguments: [false, true])
    func oldReadCannotRestoreAvailabilityOrOverwriteReconnectedValue(reconnect: Bool) async throws {
        let connection = CurrentValueSubject<Bool, Never>(true)
        let started = TestCheckpoint()
        let release = TestCheckpoint()
        let completed = TestCheckpoint()
        defer { release.signal() }
        var reads = 0
        let settings = TUINotificationSettings(
            connectionAvailability: connection.eraseToAnyPublisher(),
            read: {
                reads += 1
                if reads == 1 {
                    started.signal()
                    await release.waitIgnoringCancellation()
                    completed.signal()
                    return true
                }
                return false
            },
            write: { _ in Issue.record("Recovery must not write configuration") }
        )
        try #require(try await started.wait())
        connection.send(false)
        #expect(!settings.isAvailable)
        #expect(!settings.isUpdating)
        if reconnect {
            connection.send(true)
            #expect(try await waitForCondition(timeout: .seconds(2), pollInterval: .milliseconds(5)) { !settings.isUpdating })
            #expect(settings.isAvailable)
            #expect(settings.isEnabled == false)
        }

        release.signal()
        try #require(try await completed.wait())
        await Task.yield()
        #expect(settings.isAvailable == reconnect)
        #expect(settings.isEnabled == (reconnect ? false : nil))
        #expect(!settings.isUpdating)
        #expect(settings.errorMessage == nil)
    }

    @Test func onlyExplicitAvailableChangeWritesAndVerifiesConfiguration() async throws {
        let connection = CurrentValueSubject<Bool, Never>(true)
        var serverValue = true
        var writes: [Bool] = []
        var reads = 0
        let settings = TUINotificationSettings(
            connectionAvailability: connection.eraseToAnyPublisher(),
            read: { reads += 1
                return serverValue
            },
            write: { value in writes.append(value)
                serverValue = value
            }
        )
        settings.setEnabled(false)
        #expect(writes.isEmpty)
        #expect(try await waitForCondition(timeout: .seconds(2), pollInterval: .milliseconds(5)) { !settings.isUpdating })
        settings.setEnabled(false)
        #expect(try await waitForCondition(timeout: .seconds(2), pollInterval: .milliseconds(5)) { !settings.isUpdating })
        #expect(writes == [false])
        #expect(reads == 2)
        #expect(settings.isAvailable)
        #expect(settings.isEnabled == false)
        connection.send(false)
        settings.setEnabled(true)
        #expect(writes == [false])
    }

    @Test func failedReadRemainsUnavailableAndCanBeRefreshed() async throws {
        enum Failure: Error { case unavailable }
        let connection = CurrentValueSubject<Bool, Never>(true)
        let configuration = Configuration()
        configuration.fails = true
        let settings = TUINotificationSettings(
            connectionAvailability: connection.eraseToAnyPublisher(),
            read: {
                if configuration.fails {
                    throw Failure.unavailable
                }
                return true
            },
            write: { _ in Issue.record("Read failure must not write configuration") }
        )
        #expect(try await waitForCondition(timeout: .seconds(2), pollInterval: .milliseconds(5)) { !settings.isUpdating })
        #expect(!settings.isAvailable)
        #expect(settings.errorMessage != nil)
        settings.setEnabled(false)
        configuration.fails = false
        settings.refresh()
        #expect(try await waitForCondition(timeout: .seconds(2), pollInterval: .milliseconds(5)) { !settings.isUpdating })
        #expect(settings.isAvailable)
        #expect(settings.isEnabled == true)
        #expect(settings.errorMessage == nil)
    }

    @Test(arguments: [false, true])
    func failedRefreshClearsPreviousValueAndCanRecover(_ initialValue: Bool) async throws {
        enum Failure: Error { case unavailable }
        let connection = CurrentValueSubject<Bool, Never>(true)
        let configuration = Configuration()
        let settings = TUINotificationSettings(
            connectionAvailability: connection.eraseToAnyPublisher(),
            read: {
                if configuration.fails {
                    throw Failure.unavailable
                }
                return initialValue
            },
            write: { _ in Issue.record("Refresh must not write configuration") }
        )
        #expect(try await waitForCondition(timeout: .seconds(2), pollInterval: .milliseconds(5)) { !settings.isUpdating })
        #expect(settings.isEnabled == initialValue)

        configuration.fails = true
        settings.refresh()
        #expect(settings.isUpdating)
        #expect(settings.isEnabled == initialValue)
        settings.setEnabled(!initialValue)
        #expect(try await waitForCondition(timeout: .seconds(2), pollInterval: .milliseconds(5)) { !settings.isUpdating })
        #expect(settings.isEnabled == nil)
        #expect(!settings.isAvailable)
        #expect(settings.errorMessage == String(localized: "codex-tui-notifications.error.read-failed"))
        settings.setEnabled(!initialValue)

        configuration.fails = false
        settings.refresh()
        #expect(try await waitForCondition(timeout: .seconds(2), pollInterval: .milliseconds(5)) { !settings.isUpdating })
        #expect(settings.isEnabled == initialValue)
        #expect(settings.isAvailable)
        #expect(settings.errorMessage == nil)
    }

    @Test(arguments: WriteFailure.allCases, [false, true])
    func failedWriteKeepsPreviousValueAndCanBeRetried(failure: WriteFailure, initialValue: Bool) async throws {
        let connection = CurrentValueSubject<Bool, Never>(true)
        let configuration = Configuration()
        configuration.isEnabled = initialValue
        configuration.fails = true
        var writes: [Bool] = []
        var reads = 0
        let settings = TUINotificationSettings(
            connectionAvailability: connection.eraseToAnyPublisher(),
            read: {
                reads += 1
                if !writes.isEmpty, configuration.fails, failure == .verificationRead {
                    throw failure
                }
                return configuration.isEnabled
            },
            write: { value in
                writes.append(value)
                if configuration.fails, failure == .write {
                    throw failure
                }
                if !configuration.fails || failure != .verificationMismatch {
                    configuration.isEnabled = value
                }
            }
        )
        #expect(try await waitForCondition(timeout: .seconds(2), pollInterval: .milliseconds(5)) { !settings.isUpdating })
        settings.setEnabled(!initialValue)
        #expect(settings.isUpdating)
        #expect(settings.isEnabled == initialValue)
        #expect(try await waitForCondition(timeout: .seconds(2), pollInterval: .milliseconds(5)) { !settings.isUpdating })
        #expect(settings.isAvailable)
        #expect(settings.isEnabled == initialValue)
        #expect(settings.errorMessage == String(localized: "codex-tui-notifications.error.write-failed"))
        #expect(writes == [!initialValue])
        #expect(reads == (failure == .write ? 1 : 2))

        configuration.fails = false
        settings.setEnabled(!initialValue)
        #expect(try await waitForCondition(timeout: .seconds(2), pollInterval: .milliseconds(5)) { !settings.isUpdating })
        #expect(settings.isAvailable)
        #expect(settings.isEnabled == !initialValue)
        #expect(settings.errorMessage == nil)
        #expect(writes == [!initialValue, !initialValue])
    }

    enum WriteFailure: CaseIterable, Error {
        case write
        case verificationRead
        case verificationMismatch
    }

    @MainActor
    private final class Configuration {
        var isEnabled = true
        var fails = false
    }
}
