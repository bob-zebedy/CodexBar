import Foundation
import Testing

struct SessionLifecycleCacheTests {
    @Test func unavailableChildInvalidatesAncestorsButNotOtherThreads() async {
        let reader = SessionLifecycleCache()
        let now = Date()
        var states: [ActivityTurnReference: SessionLifecycleState] = [:]
        for id in ["root", "child", "grandchild", "other"] {
            let reference = ActivityTurnReference(threadID: id, turnID: "turn", startedAt: now)
            var state = SessionLifecycleState(
                requestedThreadID: id, turnID: "turn", startedAt: now, approvalReviewer: nil,
                effort: nil, lastProgressAt: now, terminal: nil
            )
            state.parentThreadID = id == "grandchild" ? "child" : id == "child" ? "root" : nil
            state.rootSessionID = id == "grandchild" || id == "child" ? "root" : nil
            state.rootTurnID = "turn"
            states[reference] = state
        }
        await reader.replace(states, verifiedThreads: ["root": now, "child": now, "other": now])
        let result = await reader.lifecycleStates(for: Array(states.keys), now: now)
        #expect(result.first { $0.requestedThreadID == "other" }?.readStatus == .complete)
        #expect(result.filter { $0.requestedThreadID != "other" }.allSatisfy { $0.readStatus == .unavailable })
    }

    @Test func disconnectAndCoverageExpiryInvalidateCachedLifecycle() async {
        let reader = SessionLifecycleCache()
        let now = TestFixtures.now
        let reference = ActivityTurnReference(threadID: "thread", turnID: "turn", startedAt: now)
        let state = SessionLifecycleState(
            requestedThreadID: "thread", turnID: "turn", startedAt: now, approvalReviewer: .user,
            effort: "high", lastProgressAt: now, terminal: nil, hasContext: true
        )
        await reader.replace([reference: state], verifiedThreads: [reference.threadID: now])
        #expect(await reader.lifecycleStates(for: [reference], now: now).first?.readStatus == .complete)
        #expect(await reader.lifecycleStates(for: [reference], now: now.addingTimeInterval(16)).first?.readStatus == .unavailable)
        await reader.invalidate()
        #expect(await reader.lifecycleStates(for: [reference], now: now).first?.readStatus == .unavailable)
        await reader.replace([:], verifiedThreads: [reference.threadID: now])
        #expect(await reader.lifecycleStates(for: [reference], now: now).first?.readStatus == .notFound)
        await reader.replace([:], verifiedThreads: [:])
        #expect(await reader.lifecycleStates(for: [reference], now: now).first?.readStatus == .unavailable)
    }
}

extension SessionLifecycleCacheTests {
    @Test func lifecycleVerificationDoesNotRefreshOtherThreads() async {
        let reader = SessionLifecycleCache()
        let now = TestFixtures.now
        func reference(_ id: String) -> ActivityTurnReference {
            .init(threadID: id, turnID: "turn", startedAt: now)
        }
        func state(_ id: String) -> SessionLifecycleState {
            .init(
                requestedThreadID: id,
                turnID: "turn",
                startedAt: now,
                approvalReviewer: .user,
                effort: nil,
                lastProgressAt: now,
                terminal: nil
            )
        }
        await reader.replace([reference("a"): state("a"), reference("b"): state("b")], verifiedThreads: ["a": now, "b": now.addingTimeInterval(-16)])
        #expect(await reader.lifecycleStates(for: [reference("a")], now: now).first?.readStatus == .complete)
        #expect(await reader.lifecycleStates(for: [reference("b")], now: now).first?.readStatus == .unavailable)
    }
}

extension SessionLifecycleCacheTests {
    @Test(arguments: [false, true])
    func finishedChildCannotExpireRunningRoot(previousTurn: Bool) async {
        let cache = SessionLifecycleCache()
        let now = TestFixtures.now
        let root = ActivityTurnReference(threadID: "root", turnID: "current", startedAt: now)
        let child = ActivityTurnReference(threadID: "child", turnID: "child", startedAt: now)
        let rootState = SessionLifecycleState(
            requestedThreadID: "root",
            turnID: "current",
            startedAt: now,
            approvalReviewer: nil,
            effort: nil,
            lastProgressAt: now,
            terminal: nil
        )
        let childState = SessionLifecycleState(
            requestedThreadID: "child",
            turnID: "child",
            startedAt: now,
            approvalReviewer: nil,
            effort: nil,
            lastProgressAt: now,
            terminal: .completed(at: nil, duration: nil),
            rootTurnID: previousTurn ? "old" : "current",
            rootSessionID: "root",
            parentThreadID: "root"
        )
        await cache.replace([root: rootState, child: childState], verifiedThreads: ["root": now])
        let states = await cache.lifecycleStates(for: [root], now: now)
        #expect(states.first { $0.requestedThreadID == "root" }?.readStatus == .complete)
        #expect(states.allSatisfy { $0.readStatus == .complete })
    }

    @Test func unavailablePreviousTurnDoesNotInvalidateCurrentTurn() async {
        let cache = SessionLifecycleCache()
        let now = TestFixtures.now
        func reference(_ thread: String, _ turn: String) -> ActivityTurnReference {
            .init(threadID: thread, turnID: turn, startedAt: now)
        }
        var states: [ActivityTurnReference: SessionLifecycleState] = [:]
        for turn in ["old", "current"] {
            states[reference("root", turn)] = SessionLifecycleState(
                requestedThreadID: "root",
                turnID: turn,
                startedAt: now,
                approvalReviewer: nil,
                effort: nil,
                lastProgressAt: now,
                terminal: nil
            )
        }
        states[reference("child", "child")] = SessionLifecycleState(
            requestedThreadID: "child",
            turnID: "child",
            startedAt: now,
            approvalReviewer: nil,
            effort: nil,
            lastProgressAt: now,
            terminal: nil,
            rootTurnID: "old",
            rootSessionID: "root",
            parentThreadID: "root"
        )
        await cache.replace(states, verifiedThreads: ["root": now])
        let result = await cache.lifecycleStates(for: [reference("root", "old"), reference("root", "current")], now: now)
        #expect(result.first { $0.turnID == "old" }?.readStatus == .unavailable)
        #expect(result.first { $0.turnID == "current" }?.readStatus == .complete)
        await cache.replace(states, verifiedThreads: ["root": now, "child": now])
        #expect(await cache.lifecycleStates(for: Array(states.keys), now: now).allSatisfy { $0.readStatus == .complete })
    }
}
