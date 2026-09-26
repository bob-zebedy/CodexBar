import AppKit
import QuartzCore

private extension CodexActivityTerminalEvent {
    var glowState: TaskGlowState {
        switch self {
        case .completed: .completed
        case .terminated: .terminated
        }
    }
}

/// 短提示只消费开启后新增的结束记录, 到期后按最新快照恢复等待或运行状态
struct TaskGlowPresentationState {
    private var snapshot = CodexActivitySnapshot.empty
    private var enabledAt: Date?
    private var briefEvent: CodexActivityTerminalEvent?
    private var briefExpiration: Date?
    private var suspendedAt: Date?
    private var resumesAt: Date?
    private var terminalEventID: UUID?
    private var terminalTimeOffset: TimeInterval = 0
    private(set) var state = TaskGlowState.hidden
    private(set) var terminal: TaskGlowTerminalPresentation?

    var isSuspended: Bool {
        suspendedAt != nil
    }

    mutating func suspend(now: Date) {
        guard suspendedAt == nil else { return }
        // 恢复过渡尚未结束就再次预览时, 撤销提前计入的收回时间
        let pendingDelay = max(0, resumesAt?.timeIntervalSince(now) ?? 0)
        terminalTimeOffset -= pendingDelay
        briefExpiration = briefExpiration?.addingTimeInterval(-pendingDelay)
        suspendedAt = now
        resumesAt = nil
    }

    /// 只平移展示期限, 不修改任务事件时间; 新事件在暂停期间保留完整时长
    mutating func resume(now: Date) {
        guard let suspendedAt else { return }
        let elapsed = max(0, now.timeIntervalSince(suspendedAt))
        terminalTimeOffset += elapsed
        briefExpiration = briefExpiration?.addingTimeInterval(elapsed)
        self.suspendedAt = nil
        resumesAt = now
        terminal = nil
    }

    mutating func update(
        snapshot: CodexActivitySnapshot,
        terminalEvents: [CodexActivityTerminalEvent],
        isEnabled: Bool,
        acceptsBriefEvents: Bool,
        now: Date
    ) {
        let latestEvent = terminalEvents.max { lhs, rhs in
            if lhs.endedAt != rhs.endedAt {
                return lhs.endedAt < rhs.endedAt
            }
            if lhs.glowState != rhs.glowState {
                return rhs.glowState == .terminated
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        if isEnabled, let enabledAt, acceptsBriefEvents,
           snapshot.hasActiveTasks,
           let latestEvent, latestEvent.endedAt >= enabledAt {
            briefEvent = latestEvent
            briefExpiration = (suspendedAt ?? now).addingTimeInterval(3)
        }
        if !isEnabled || !acceptsBriefEvents || !snapshot.hasActiveTasks {
            briefEvent = nil
            briefExpiration = nil
        }
        if !isEnabled {
            enabledAt = nil
            suspendedAt = nil
            resumesAt = nil
            terminalEventID = nil
            terminalTimeOffset = 0
        } else if enabledAt == nil {
            enabledAt = now
        }
        self.snapshot = snapshot
        if let event = snapshot.latestTerminalEvent, event.id != terminalEventID {
            terminalEventID = event.id
            terminalTimeOffset = suspendedAt.map { min(0, $0.timeIntervalSince(event.endedAt)) } ?? 0
        }
    }

    mutating func refresh(now: Date, terminalDuration: TimeInterval) {
        let now = suspendedAt ?? max(now, resumesAt ?? now)
        guard enabledAt != nil else {
            state = .hidden
            terminal = nil
            return
        }
        if let briefExpiration, now >= briefExpiration {
            briefEvent = nil
            self.briefExpiration = nil
        }
        if snapshot.hasActiveTasks, let briefEvent, let briefExpiration {
            show(briefEvent, until: briefExpiration, fadeDuration: 0.5, now: now)
            return
        }
        if snapshot.waitingCount > 0 {
            state = .waiting
        } else if snapshot.runningCount > 0 {
            state = .running
        } else if let event = snapshot.latestTerminalEvent,
                  now < event.endedAt.addingTimeInterval(terminalDuration + terminalTimeOffset) {
            show(event, until: event.endedAt.addingTimeInterval(terminalDuration + terminalTimeOffset), fadeDuration: 1, now: now)
            return
        } else {
            state = .hidden
        }
        terminal = nil
    }

    private mutating func show(_ event: CodexActivityTerminalEvent, until expiration: Date, fadeDuration: TimeInterval, now: Date) {
        terminal = TaskGlowTerminalPresentation(
            eventID: event.id,
            startedAt: terminal.flatMap { $0.eventID == event.id ? $0.startedAt : nil } ?? now,
            expiresAt: expiration,
            fadeDuration: fadeDuration
        )
        state = event.glowState
    }
}

/// 同一轮切换共用开始时刻, 收回旧光带的时间不占用目标效果的展示时长
struct TaskGlowPlayback {
    let id = UUID()
    var startsAt: Date
    var mediaStart: CFTimeInterval
}

struct TaskGlowPreviewPresentation {
    let role: TaskGlowColorRole
    let isColorPreview: Bool
    var playback: TaskGlowPlayback
    private(set) var speed: TaskGlowAnimationSpeed

    var state: TaskGlowState {
        switch role {
        case .running: .running
        case .waiting: .waiting
        case .completed: .completed
        case .terminated: .terminated
        }
    }

    var expiresAt: Date {
        let duration: TimeInterval = switch role {
        case .running: TaskGlowAnimationTiming.cycleDuration * speed.durationMultiplier
        case .waiting: TaskGlowAnimationTiming.expansionDuration + 3 * speed.durationMultiplier
        case .completed, .terminated: 3
        }
        return playback.startsAt.addingTimeInterval(duration)
    }

    var terminal: TaskGlowTerminalPresentation? {
        guard role == .completed || role == .terminated else { return nil }
        return TaskGlowTerminalPresentation(eventID: playback.id, startedAt: playback.startsAt, expiresAt: expiresAt, fadeDuration: 0.5)
    }

    mutating func setAnimationSpeed(_ speed: TaskGlowAnimationSpeed, now: Date) {
        defer { self.speed = speed }
        guard speed != self.speed, role == .running || role == .waiting else { return }
        let entrance = role == .waiting ? TaskGlowAnimationTiming.expansionDuration : 0
        let elapsed = max(0, now.timeIntervalSince(playback.startsAt) - entrance)
        let shift = elapsed * (1 - speed.durationMultiplier / self.speed.durationMultiplier)
        playback.startsAt = playback.startsAt.addingTimeInterval(shift)
        playback.mediaStart += shift
    }
}

enum TaskGlowAnimationTiming {
    static let travelDuration = 2.0
    static let offscreenDuration = 0.2
    static let centerRetractionDuration = 0.3
    static let cycleDuration = travelDuration + offscreenDuration * 2 + centerRetractionDuration
    static let edgeTraversalDuration = 0.7
    static let expansionDuration = edgeTraversalDuration / 2
    static let transitionGap = 0.06
}

enum TaskGlowState {
    case hidden
    case running
    case waiting
    case completed
    case terminated

    func color(in appearance: TaskGlowAppearance) -> NSColor {
        switch self {
        case .hidden: .clear
        case .running: appearance.color(for: .running)
        case .waiting: appearance.color(for: .waiting)
        case .completed: appearance.color(for: .completed)
        case .terminated: appearance.color(for: .terminated)
        }
    }
}

/// 终态共用墙上时间, 屏幕重建和唤醒后接续淡出, 不重新提亮
struct TaskGlowTerminalPresentation: Equatable {
    static let entranceDuration: TimeInterval = 1.2
    let eventID: UUID
    let startedAt: Date
    let expiresAt: Date
    let fadeDuration: TimeInterval

    var duration: TimeInterval {
        max(0, expiresAt.timeIntervalSince(startedAt))
    }

    var entranceDuration: TimeInterval {
        min(Self.entranceDuration, duration / 4)
    }

    var holdDuration: TimeInterval {
        max(0, duration - fadeDuration)
    }
}
