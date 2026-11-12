import Foundation

extension ActivityMonitor {
    func resetTerminalPresentationCutoff() {
        terminalPresentationNotBefore = Date()
    }

    func clearCollectedActivityState() {
        resetTerminalPresentationCutoff()
        cancelAllProtectionAttempts()
        let taskIDs = Set(tasks.values.map(\.displayID)).union(pendingTerminalTasks.values.map(\.task.displayID))
        for taskID in taskIDs {
            invalidateProtectionNotification(for: taskID)
        }
        suppressedTasks.removeAll()
        graph = ActivityTaskGraph()
    }
}
