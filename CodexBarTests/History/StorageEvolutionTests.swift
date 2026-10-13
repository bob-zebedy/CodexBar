import Foundation
import Testing

struct StorageEvolutionTests {
    @Test func unsupportedTokenUsageAlgorithmCannotEnterLocalSnapshots() throws {
        let first = TestFixtures.tokenUsageAggregate(at: Date())
        var unsupported = first
        unsupported.aggregationVersion = 999
        #expect(throws: StorageCompatibilityError.self) { try TokenUsageSyncRecord.dailyRecords(local: [first, unsupported], deviceID: "device") }
        #expect(throws: StorageCompatibilityError.self) {
            try JSONLines.decoder.decode(TokenUsageAggregate.self, from: JSONLines.stableEncoder.encode(unsupported))
        }
    }

    @Test func protocolBoundaryNormalizesStatusAndTimeUnits() throws {
        let input = try TestFixtures.decode(ActivityInput.self, """
        {"method":"turn/completed","params":{"threadId":"thread","turn":{"id":"turn","status":"completed","startedAt":1000,"completedAt":1002,"durationMs":1500}}}
        """)
        #expect(input.kind == .turnFinished)
        #expect(input.params.turn?.status == .completed)
        #expect(input.params.turn?.startedAt == Date(timeIntervalSince1970: 1000))
        #expect(input.params.turn?.duration == 1.5)
        let unknown = try TestFixtures.decode(ActivityInput.self, "{\"method\":\"future/event\",\"params\":{}}")
        #expect(unknown.kind == .ignored)
    }
}
