nonisolated enum CountResolution {
    static func preferredCount(
        compactedCount: Int?,
        identifiers: [String]? = nil
    ) -> Int? {
        if let compactedCount, compactedCount > 0 {
            return compactedCount
        }

        if let identifiers {
            return Set(identifiers).count
        }

        return compactedCount == 0 ? 0 : nil
    }
}
