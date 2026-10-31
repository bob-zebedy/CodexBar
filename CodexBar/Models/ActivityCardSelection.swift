import Foundation

/// 只管理主卡片选择, 不改变采集, 通知或任务中心的排序
nonisolated struct ActivityCardSelection: Equatable {
    private(set) var activities: [CodexPrimaryActivity] = []
    private(set) var selectedID: String?
    private(set) var pinnedID: String?
    private(set) var manualViewingDeadline: Date?
    private(set) var transitionDirection: Int?
    private(set) var isVisible = false
    private var orderedIDs: [String] = []
    private var automaticID: String?
    private var gestureBeganAt: Date?
    private var gestureActivities: [CodexPrimaryActivity]?

    var carouselActivities: [CodexPrimaryActivity] {
        gestureActivities ?? activities
    }

    var isGestureActive: Bool {
        gestureBeganAt != nil
    }

    var current: CodexPrimaryActivity? {
        carouselActivities.first { $0.cardSelectionID == selectedID }
    }

    func positionText(for id: String?) -> String? {
        let carousel = carouselActivities
        guard carousel.count > 1,
              let index = carousel.firstIndex(where: { $0.cardSelectionID == id }) else { return nil }
        return "\(index + 1)/\(carousel.count)"
    }

    var returnDeadline: Date? {
        isVisible && gestureBeganAt == nil ? manualViewingDeadline : nil
    }

    var waitingSides: WaitingSides {
        let carousel = carouselActivities
        guard let origin = carousel.firstIndex(where: { $0.cardSelectionID == selectedID }) else { return WaitingSides() }
        var sides = WaitingSides()
        for (index, activity) in carousel.enumerated() where activity.isCardWaiting && index != origin {
            let forward = (index - origin + carousel.count) % carousel.count
            let backward = carousel.count - forward
            // 高亮对应等待卡片所在侧, 下一项从右侧进入
            sides.left = sides.left || backward <= forward
            sides.right = sides.right || forward <= backward
        }
        return sides
    }

    mutating func update(snapshot: ActivitySnapshot, isHealthy: Bool, now: Date) {
        guard isHealthy else {
            activities = []
            automaticID = nil
            manualViewingDeadline = nil
            gestureBeganAt = nil
            gestureActivities = nil
            transitionDirection = nil
            // 断连期间保留会话顺序和固定关系, 恢复后再根据完整快照裁剪
            return
        }
        let terminals = (snapshot.recentCompletions.map(CodexPrimaryActivity.completed)
            + snapshot.recentTerminations.map(CodexPrimaryActivity.terminated))
            .filter { $0.cardEndedAt.map { now.timeIntervalSince($0) < ActivityRetention.terminalDisplayWindow } == true }
            .sorted { ($0.cardEndedAt ?? .distantPast) > ($1.cardEndedAt ?? .distantPast) }
        let candidates = snapshot.panelWaitingTasks.map(CodexPrimaryActivity.waiting)
            + snapshot.panelRunningTasks.map(CodexPrimaryActivity.running) + terminals
        var latest: [String: CodexPrimaryActivity] = [:]
        var incomingIDs: [String] = []
        for activity in candidates {
            guard let id = activity.cardSelectionID, latest[id] == nil else { continue }
            latest[id] = activity
            incomingIDs.append(id)
        }
        orderedIDs.removeAll { latest[$0] == nil }
        let retainedIDs = Set(orderedIDs)
        orderedIDs += incomingIDs.filter { !retainedIDs.contains($0) }
        activities = orderedIDs.compactMap { latest[$0] }
        if snapshot.hasActiveTasks {
            automaticID = incomingIDs.first
        } else {
            automaticID = snapshot.primaryActivity.cardSelectionID
        }
        if let gestureActivities,
           !Set(gestureActivities.compactMap(\.cardSelectionID)).isSubset(of: Set(incomingIDs)) {
            // 消失的卡片不能继续提交, 让视图取消这轮手势
            setGestureActive(false, now: now)
        } else {
            reconcile(at: now)
        }
    }

    mutating func setVisible(_ visible: Bool, now: Date) {
        guard visible != isVisible else { return }
        isVisible = visible
        manualViewingDeadline = nil
        gestureBeganAt = nil
        gestureActivities = nil
        transitionDirection = nil
        if visible {
            reconcile(at: now)
        }
    }

    mutating func swipe(_ step: Int, now: Date) {
        let carousel = carouselActivities
        guard isVisible, carousel.count > 1,
              let index = carousel.firstIndex(where: { $0.cardSelectionID == selectedID }) else { return }
        let direction = step < 0 ? -1 : 1
        transitionDirection = direction
        selectedID = carousel[(index + direction + carousel.count) % carousel.count].cardSelectionID
        beginManualViewing(at: now)
    }

    mutating func selectAfterSwipe(_ id: String, now: Date) {
        guard isVisible, activities.contains(where: { $0.cardSelectionID == id }) else { return }
        selectedID = id
        transitionDirection = nil
        beginManualViewing(at: now)
    }

    mutating func togglePin(now: Date) {
        guard isVisible, let current, let id = current.cardSelectionID else { return }
        if pinnedID == id {
            pinnedID = nil
            beginManualViewing(at: now)
        } else {
            pinnedID = id
            manualViewingDeadline = nil
        }
    }

    mutating func setGestureActive(_ active: Bool, now: Date) {
        guard isVisible else { return }
        if active {
            if gestureBeganAt == nil {
                gestureBeganAt = now
                // 连续手势接管收尾动画时沿用同一快照, 保持卡片, 位置数字和高亮一致
                gestureActivities = activities
            }
        } else if let began = gestureBeganAt {
            manualViewingDeadline = manualViewingDeadline?.addingTimeInterval(max(0, now.timeIntervalSince(began)))
            gestureBeganAt = nil
            gestureActivities = nil
            reconcile(at: now)
        }
    }

    mutating func reconcile(at now: Date) {
        if current != nil, gestureBeganAt != nil || manualViewingDeadline.map({ $0 > now }) == true {
            return
        }
        manualViewingDeadline = nil
        let available = Set(activities.compactMap(\.cardSelectionID))
        let next = pinnedID.flatMap { available.contains($0) ? $0 : nil }
            ?? automaticID.flatMap { available.contains($0) ? $0 : nil }
            ?? activities.first?.cardSelectionID
        guard next != selectedID else { return }
        transitionDirection = nil
        selectedID = next
    }

    private mutating func beginManualViewing(at now: Date) {
        // 停留期限按最新等待状态计算, 不沿用手势开始时的展示状态
        let activity = activities.first { $0.cardSelectionID == selectedID }
        manualViewingDeadline = now.addingTimeInterval(activity?.isCardWaiting == true ? 15 : 10)
        if gestureBeganAt != nil {
            gestureBeganAt = now
        }
    }

    struct WaitingSides: Equatable {
        var left = false
        var right = false
    }
}

extension CodexPrimaryActivity {
    nonisolated var cardSelectionID: String? {
        switch self {
        case let .waiting(task), let .running(task): task.threadID
        case let .completed(task): task.threadID
        case let .terminated(task): task.threadID
        case .idle: nil
        }
    }

    nonisolated var isCardWaiting: Bool {
        if case .waiting = self {
            true
        } else {
            false
        }
    }

    nonisolated var cardEndedAt: Date? {
        switch self {
        case let .completed(task): task.completedAt
        case let .terminated(task): task.terminatedAt
        default: nil
        }
    }
}
