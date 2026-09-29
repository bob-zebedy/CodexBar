import Foundation

struct RebuildDateRange: Equatable {
    let startDateKey: String
    let endDateKey: String?

    static func starting(at dateKey: String) -> RebuildDateRange {
        RebuildDateRange(startDateKey: dateKey, endDateKey: nil)
    }

    var isComplete: Bool {
        endDateKey != nil
    }

    var dayCount: Int {
        guard let endDateKey,
              let startDate = CodexDateFormat.dayDate(from: startDateKey),
              let endDate = CodexDateFormat.dayDate(from: endDateKey) else {
            return 0
        }

        guard let dayDifference = CodexDateFormat.localGregorianCalendar.dateComponents(
            [.day],
            from: startDate,
            to: endDate
        ).day else {
            return 0
        }
        return dayDifference + 1
    }

    var dateKeys: [String] {
        guard isComplete, dayCount > 0, let start = CodexDateFormat.dayDate(from: startDateKey) else { return [] }
        return (0 ..< dayCount).compactMap { offset in
            CodexDateFormat.localGregorianCalendar.date(byAdding: .day, value: offset, to: start)
                .map(CodexDateFormat.dayString(from:))
        }
    }

    var displayText: String {
        guard let startDate = CodexDateFormat.dayDate(from: startDateKey) else {
            return startDateKey
        }
        let startText = CodexDateFormat.localDayDisplayString(from: startDate)
        guard let endDateKey else {
            return String(localized: "date-range.open-ended", defaultValue: "\(startText)")
        }
        guard startDateKey != endDateKey,
              let endDate = CodexDateFormat.dayDate(from: endDateKey) else {
            return startText
        }
        let endText = CodexDateFormat.localDayDisplayString(from: endDate)
        return String(localized: "date-range.closed", defaultValue: "\(startText)\(endText)")
    }

    func completing(with dateKey: String) -> RebuildDateRange {
        RebuildDateRange(
            startDateKey: min(startDateKey, dateKey),
            endDateKey: max(startDateKey, dateKey)
        )
    }

    func contains(_ dateKey: String) -> Bool {
        guard let endDateKey else {
            return false
        }
        return dateKey >= startDateKey && dateKey <= endDateKey
    }
}
