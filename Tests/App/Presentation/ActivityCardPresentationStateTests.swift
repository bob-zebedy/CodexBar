import Foundation
import Testing

struct ActivityCardPresentationStateTests {
    @Test func presentationUsesCommittedReconnectSnapshotWithoutLosingOrder() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let monitor = ActivityMonitor(
            protectionSettings: ProtectionSettings(defaults: preferences.defaults),
            protectionStore: ProtectionStore(directoryURL: directory.url), activityDataDirectoryURL: directory.url
        )
        defer { monitor.stop() }
        monitor.isStarted = true
        monitor.protectionLoadState = .available
        monitor.isActivitySourceHealthy = true
        let date = Date()
        monitor.consume(.live([
            TestFixtures.event(at: date.addingTimeInterval(-2), thread: "a"),
            TestFixtures.event(at: date.addingTimeInterval(-1), thread: "b")
        ]))
        let presentation = ActivityCardPresentationState(activityMonitor: monitor)
        presentation.setVisible(true)
        defer { presentation.setVisible(false) }
        presentation.togglePin()
        let pinnedID = presentation.selection.pinnedID
        let order = presentation.selection.activities.compactMap(\.cardSelectionID)
        #expect(order.count == 2)
        presentation.swipe(1)
        presentation.setVisible(false)
        monitor.consume(.sourceUnavailable)
        #expect(presentation.selection.activities.isEmpty)
        #expect(presentation.selection.pinnedID == pinnedID)
        monitor.consume(.bootstrapStart)
        monitor.consume(.snapshotEvents([
            TestFixtures.event(at: date, thread: "a"),
            TestFixtures.event(at: date.addingTimeInterval(-1), thread: "b")
        ]))
        monitor.consume(.bootstrapEnd)
        presentation.setVisible(true)
        #expect(presentation.selection.activities.compactMap(\.cardSelectionID) == order)
        #expect(presentation.selection.selectedID == pinnedID)
        #expect(presentation.selection.returnDeadline == nil)
    }

    @Test func staleHostCannotFinishOrCommitANewHostsGesture() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let monitor = ActivityMonitor(
            protectionSettings: ProtectionSettings(defaults: preferences.defaults),
            protectionStore: ProtectionStore(directoryURL: directory.url), activityDataDirectoryURL: directory.url
        )
        defer { monitor.stop() }
        monitor.isActivitySourceHealthy = true
        monitor.protectionLoadState = .available
        monitor.consume(.live([
            TestFixtures.event(at: Date(), thread: "a"),
            TestFixtures.event(at: Date(), thread: "b")
        ]))
        let presentation = ActivityCardPresentationState(activityMonitor: monitor)
        presentation.setVisible(true)
        defer { presentation.setVisible(false) }
        presentation.togglePin()
        let pinnedID = presentation.selection.pinnedID
        let firstHost = UUID(), secondHost = UUID()
        presentation.setGestureActive(true, owner: firstHost)
        presentation.setVisible(false)
        presentation.setVisible(true)
        presentation.setGestureActive(true, owner: secondHost)
        let preview = try #require(presentation.selection.activities.first { $0.cardSelectionID != pinnedID }?.cardSelectionID)
        presentation.selectAfterSwipe(preview, owner: secondHost)
        presentation.setGestureActive(false, owner: firstHost)
        try presentation.selectAfterSwipe(#require(pinnedID), owner: firstHost)
        #expect(presentation.selection.selectedID == preview)
        #expect(presentation.selection.returnDeadline == nil)
        presentation.setGestureActive(false, owner: secondHost)
        #expect(presentation.selection.returnDeadline != nil)
    }
}
