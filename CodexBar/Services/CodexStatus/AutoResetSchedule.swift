import Foundation

/// 同一凭证的尝试预算独立于快照刷新和定时任务生命周期
nonisolated struct AutoResetSchedule {
    enum Phase: Equatable {
        case initial
        case cooldown
        case final
    }

    struct Attempt: Equatable {
        let phase: Phase
        let deadline: Date
    }

    struct Plan: Equatable {
        let evaluationDate: Date
        let wakeDate: Date?
    }

    private var initialStartedAt: Date?
    private var initialAttempts = 0
    private var initialFinished = false
    private var nextAttemptAt: Date?
    private var finalExpirationDate: Date?
    private var finalAttempts = 0
    private var finalFinished = false

    static let finalLeadTime: TimeInterval = 180
    static let cutoffLeadTime: TimeInterval = 60
    private static let initialWindow: TimeInterval = 300
    private static let initialDelays: [TimeInterval] = [15, 30, 60, 120]
    private static let finalDelays: [TimeInterval] = [15, 30]

    static func cooldown(for leadTime: TimeInterval) -> TimeInterval {
        min(900, leadTime / 3)
    }

    static func cutoff(for expirationDate: Date) -> Date {
        expirationDate.addingTimeInterval(-cutoffLeadTime)
    }

    mutating func plan(expirationDate: Date, leadTime: TimeInterval, now: Date) -> Plan? {
        guard now < Self.cutoff(for: expirationDate) else { return nil }
        let threshold = expirationDate.addingTimeInterval(-leadTime)
        let finalDate = expirationDate.addingTimeInterval(-Self.finalLeadTime)
        if finalExpirationDate != expirationDate {
            // 到期时间变化只重排最终机会, 不恢复已耗尽的初始预算
            if let finalExpirationDate, expirationDate < finalExpirationDate {
                self.finalExpirationDate = expirationDate
            } else {
                finalAttempts = 0
                finalFinished = false
            }
        }
        if finalExpirationDate == expirationDate, finalFinished {
            return nil
        }
        if now >= finalDate {
            guard !finalFinished else { return nil }
            let date = finalAttempts == 0 ? now : max(now, nextAttemptAt ?? now)
            guard date < Self.cutoff(for: expirationDate) else { return nil }
            return Plan(evaluationDate: date, wakeDate: finalAttempts == 0 ? finalDate : nil)
        }
        if let start = initialStartedAt, !initialFinished,
           now >= start.addingTimeInterval(Self.initialWindow) {
            finishInitialWindow(now: start.addingTimeInterval(Self.initialWindow), leadTime: leadTime)
        }
        let next = max(threshold, nextAttemptAt ?? threshold)
        let date = min(next, finalDate)
        let wakeDate = initialStartedAt == nil && !initialFinished ? min(threshold, finalDate) : finalDate
        return Plan(evaluationDate: max(now, date), wakeDate: wakeDate)
    }

    mutating func begin(expirationDate: Date, leadTime: TimeInterval, now: Date) -> Attempt? {
        guard let plan = plan(expirationDate: expirationDate, leadTime: leadTime, now: now),
              plan.evaluationDate <= now else { return nil }
        let cutoff = Self.cutoff(for: expirationDate)
        if now >= expirationDate.addingTimeInterval(-Self.finalLeadTime) {
            if finalExpirationDate != expirationDate {
                finalExpirationDate = expirationDate
                finalAttempts = 0
                finalFinished = false
            }
            guard !finalFinished, finalAttempts < 3 else { return nil }
            initialFinished = true
            finalAttempts += 1
            return Attempt(phase: .final, deadline: cutoff)
        }
        if !initialFinished {
            initialStartedAt = initialStartedAt ?? now
            initialAttempts += 1
            return Attempt(
                phase: .initial,
                deadline: min(cutoff, initialStartedAt!.addingTimeInterval(Self.initialWindow))
            )
        }
        return Attempt(phase: .cooldown, deadline: min(cutoff, now.addingTimeInterval(Self.initialWindow)))
    }

    mutating func finish(_ attempt: Attempt, transientFailure: Bool, leadTime: TimeInterval, now: Date) {
        switch attempt.phase {
        case .initial:
            if transientFailure, initialAttempts <= Self.initialDelays.count {
                let next = now.addingTimeInterval(Self.initialDelays[initialAttempts - 1])
                if next < attempt.deadline {
                    nextAttemptAt = next
                    return
                }
            }
            if transientFailure {
                finishInitialWindow(now: now, leadTime: leadTime)
            } else {
                initialFinished = true
                nextAttemptAt = now.addingTimeInterval(Self.cooldown(for: leadTime))
            }
        case .cooldown:
            nextAttemptAt = now.addingTimeInterval(Self.cooldown(for: leadTime))
        case .final:
            if transientFailure, finalAttempts <= Self.finalDelays.count {
                let next = now.addingTimeInterval(Self.finalDelays[finalAttempts - 1])
                if next < attempt.deadline {
                    nextAttemptAt = next
                    return
                }
            }
            finalFinished = true
            nextAttemptAt = nil
        }
    }

    /// 普通评估跨过最终复查点时, 该评估承接最终机会, 不额外发起并行请求
    mutating func coverFinalIfNeeded(_ attempt: Attempt, expirationDate: Date, transientFailure: Bool, now: Date) {
        guard attempt.phase != .final,
              now >= expirationDate.addingTimeInterval(-Self.finalLeadTime) else { return }
        finalExpirationDate = expirationDate
        finalAttempts = 1
        initialFinished = true
        let next = now.addingTimeInterval(Self.finalDelays[0])
        let canRetry = transientFailure && next < Self.cutoff(for: expirationDate)
        finalFinished = !canRetry
        nextAttemptAt = canRetry ? next : nil
    }

    private mutating func finishInitialWindow(now: Date, leadTime: TimeInterval) {
        initialFinished = true
        let end = initialStartedAt?.addingTimeInterval(Self.initialWindow) ?? now
        nextAttemptAt = max(end, now).addingTimeInterval(Self.cooldown(for: leadTime))
    }
}
