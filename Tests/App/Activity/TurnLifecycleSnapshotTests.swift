import Foundation
import Testing

struct TurnLifecycleSnapshotTests {
    @Test func unavailableChildInvalidatesAncestorsButNotOtherThreads() {
        let now = Date()
        var states: [ActivityTurnReference: TurnLifecycleState] = [:]
        for id in ["root", "child", "grandchild", "other"] {
            let reference = ActivityTurnReference(threadID: id, turnID: "turn")
            var state = TurnLifecycleState(
                requestedThreadID: id, turnID: "turn", startedAt: now, effort: nil, lastProgressAt: now, terminal: nil
            )
            state.parentThreadID = id == "grandchild" ? "child" : id == "child" ? "root" : nil
            state.rootThreadID = id == "grandchild" || id == "child" ? "root" : nil
            state.rootTurnID = "turn"
            states[reference] = state
        }
        let verified = Dictionary(uniqueKeysWithValues: ["root", "child", "other"].map {
            (ActivityTurnReference(threadID: $0, turnID: "turn"), now)
        })
        let snapshot = TurnLifecycleSnapshot(states: states, verifiedTurns: verified)
        let result = snapshot.lifecycleStates(for: Array(states.keys), now: now)
        #expect(result.first { $0.requestedThreadID == "other" }?.readStatus == .complete)
        #expect(result.filter { $0.requestedThreadID != "other" }.allSatisfy { $0.readStatus == .unavailable })
    }

    @Test func missingVerificationAndCoverageExpiryInvalidateLifecycle() {
        let now = TestFixtures.now
        let reference = ActivityTurnReference(threadID: "thread", turnID: "turn")
        let state = TurnLifecycleState(
            requestedThreadID: "thread", turnID: "turn", startedAt: now, effort: "high", lastProgressAt: now, terminal: nil
        )
        let verified = TurnLifecycleSnapshot(states: [reference: state], verifiedTurns: [reference: now])
        #expect(verified.lifecycleStates(for: [reference], now: now).first?.readStatus == .complete)
        #expect(verified.lifecycleStates(for: [reference], now: now.addingTimeInterval(16)).first?.readStatus == .unavailable)
        let disconnected = TurnLifecycleSnapshot(states: [reference: state], verifiedTurns: [:])
        #expect(disconnected.lifecycleStates(for: [reference], now: now).first?.readStatus == .unavailable)
        let missing = TurnLifecycleSnapshot(states: [:], verifiedTurns: [reference: now])
        #expect(missing.lifecycleStates(for: [reference], now: now).first?.readStatus == .notFound)
        let unavailable = TurnLifecycleSnapshot(states: [:], verifiedTurns: [:])
        #expect(unavailable.lifecycleStates(for: [reference], now: now).first?.readStatus == .unavailable)
    }
}

extension TurnLifecycleSnapshotTests {
    @Test func lifecycleVerificationDoesNotRefreshOtherThreads() {
        let now = TestFixtures.now
        func reference(_ id: String) -> ActivityTurnReference {
            .init(threadID: id, turnID: "turn")
        }
        func state(_ id: String) -> TurnLifecycleState {
            .init(
                requestedThreadID: id,
                turnID: "turn",
                startedAt: now,
                effort: nil,
                lastProgressAt: now,
                terminal: nil
            )
        }
        let snapshot = TurnLifecycleSnapshot(
            states: [reference("a"): state("a"), reference("b"): state("b")],
            verifiedTurns: [reference("a"): now, reference("b"): now.addingTimeInterval(-16)]
        )
        #expect(snapshot.lifecycleStates(for: [reference("a")], now: now).first?.readStatus == .complete)
        #expect(snapshot.lifecycleStates(for: [reference("b")], now: now).first?.readStatus == .unavailable)
    }
}

extension TurnLifecycleSnapshotTests {
    @Test(arguments: [false, true])
    func finishedChildCannotExpireRunningRoot(previousTurn: Bool) {
        let now = TestFixtures.now
        let root = ActivityTurnReference(threadID: "root", turnID: "current")
        let child = ActivityTurnReference(threadID: "child", turnID: "child")
        let rootState = TurnLifecycleState(
            requestedThreadID: "root",
            turnID: "current",
            startedAt: now,
            effort: nil,
            lastProgressAt: now,
            terminal: nil
        )
        let childState = TurnLifecycleState(
            requestedThreadID: "child",
            turnID: "child",
            startedAt: now,
            effort: nil,
            lastProgressAt: now,
            terminal: .completed(at: nil, duration: nil),
            rootTurnID: previousTurn ? "old" : "current",
            rootThreadID: "root",
            parentThreadID: "root"
        )
        let snapshot = TurnLifecycleSnapshot(states: [root: rootState, child: childState], verifiedTurns: [root: now])
        let states = snapshot.lifecycleStates(for: [root], now: now)
        #expect(states.first { $0.requestedThreadID == "root" }?.readStatus == .complete)
        #expect(states.allSatisfy { $0.readStatus == .complete })
    }

    @Test func unavailablePreviousTurnDoesNotInvalidateCurrentTurn() {
        let now = TestFixtures.now
        func reference(_ thread: String, _ turn: String) -> ActivityTurnReference {
            .init(threadID: thread, turnID: turn)
        }
        var states: [ActivityTurnReference: TurnLifecycleState] = [:]
        for turn in ["old", "current"] {
            states[reference("root", turn)] = TurnLifecycleState(
                requestedThreadID: "root",
                turnID: turn,
                startedAt: now,
                effort: nil,
                lastProgressAt: now,
                terminal: nil
            )
        }
        states[reference("child", "child")] = TurnLifecycleState(
            requestedThreadID: "child",
            turnID: "child",
            startedAt: now,
            effort: nil,
            lastProgressAt: now,
            terminal: nil,
            rootTurnID: "old",
            rootThreadID: "root",
            parentThreadID: "root"
        )
        let snapshot = TurnLifecycleSnapshot(states: states, verifiedTurns: [reference("root", "old"): now, reference("root", "current"): now])
        let result = snapshot.lifecycleStates(for: [reference("root", "old"), reference("root", "current")], now: now)
        #expect(result.first { $0.turnID == "old" }?.readStatus == .unavailable)
        #expect(result.first { $0.turnID == "current" }?.readStatus == .complete)
        let verified = TurnLifecycleSnapshot(states: states, verifiedTurns: Dictionary(uniqueKeysWithValues: states.keys.map { ($0, now) }))
        #expect(verified.lifecycleStates(for: Array(states.keys), now: now).allSatisfy { $0.readStatus == .complete })
    }
}

extension TurnLifecycleSnapshotTests {
    @Test func verifyingNewTurnDoesNotRefreshOmittedTurnInSameThread() {
        let now = TestFixtures.now
        let old = ActivityTurnReference(threadID: "thread", turnID: "old")
        let current = ActivityTurnReference(threadID: "thread", turnID: "current")
        let states = Dictionary(uniqueKeysWithValues: [old, current].map {
            ($0, TurnLifecycleState(
                requestedThreadID: $0.threadID,
                turnID: $0.turnID,
                startedAt: now,
                effort: nil,
                lastProgressAt: now,
                terminal: nil
            ))
        })
        let snapshot = TurnLifecycleSnapshot(states: states, verifiedTurns: [current: now])
        let result = snapshot.lifecycleStates(for: [old, current], now: now)
        #expect(result.first { $0.turnID == "old" }?.readStatus == .unavailable)
        #expect(result.first { $0.turnID == "current" }?.readStatus == .complete)
    }
}

extension TurnLifecycleSnapshotTests {
    @Test func unresolvedChildrenRespectKnownRootIdentityAcrossNestedThreads() {
        let now = TestFixtures.now
        let a = ActivityTurnReference(threadID: "parent", turnID: "a")
        let b = ActivityTurnReference(threadID: "parent", turnID: "b")
        func child(_ id: String, parent: String, root: String?) -> TurnLifecycleState {
            TurnLifecycleState(
                requestedThreadID: id, turnID: id, startedAt: now, effort: nil,
                lastProgressAt: now, terminal: nil, rootTurnID: root, parentThreadID: parent
            )
        }
        let states = [
            child("child-a", parent: "parent", root: "a"),
            child("grandchild-a", parent: "child-a", root: "a"),
            child("child-b", parent: "parent", root: "b"),
            child("unknown", parent: "parent", root: nil)
        ]
        func ids(_ roots: Set<ActivityTurnReference>) -> Set<String> {
            Set(TurnLifecycleState.subagentStates(for: roots, in: states).map(\.requestedThreadID))
        }
        #expect(ids([a]) == ["child-a", "grandchild-a", "unknown"])
        #expect(ids([b]) == ["child-b", "unknown"])
        #expect(ids([a, b]) == Set(states.map(\.requestedThreadID)))
    }
}
