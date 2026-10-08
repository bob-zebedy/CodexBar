import SwiftUI

enum RebuildLayoutMetrics {
    static let pickerWidth: CGFloat = 190
    static let controlHeight: CGFloat = 26
    static let actionMinimumWidth: CGFloat = 42
}

struct RebuildDatePicker: View {
    @Binding var selection: RebuildDateRange?
    let dataDateKeys: Set<String>
    let isEnabled: Bool

    @State private var isPresented = false
    @State private var displayedMonth = Date()

    private enum Metrics {
        static let daySize: CGFloat = 28
        static let columnSpacing: CGFloat = 6
        static let visibleWeekCount = 6
        static let popoverWidth: CGFloat = 260
        static let popoverHeight: CGFloat = 296
    }

    private static let columns = Array(
        repeating: GridItem(.fixed(Metrics.daySize), spacing: Metrics.columnSpacing),
        count: 7
    )
    var body: some View {
        Button {
            let focusedDateKey = selection?.endDateKey ?? selection?.startDateKey
            if let focusedDateKey,
               let selectedDate = CodexDateFormat.dayDate(from: focusedDateKey) {
                displayedMonth = startOfMonth(for: selectedDate)
            }
            isPresented.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "calendar")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tint)

                Group {
                    if let selection {
                        Text(verbatim: selection.displayText)
                    } else {
                        Text("date-picker.select-range")
                    }
                }
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(Color.codexLabel)
                .numericTransition(value: selection?.displayText)
                .lineLimit(1)
                .minimumScaleFactor(0.9)

                Spacer(minLength: 0)

                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, minHeight: RebuildLayoutMetrics.controlHeight)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.72))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(
                        isPresented ? Color.accentColor.opacity(0.70) : Color.primary.opacity(0.12),
                        lineWidth: isPresented ? 1.2 : 0.8
                    )
            }
            .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help("date-picker.select-range")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            calendarPopover
        }
    }

    private var calendarPopover: some View {
        let weekdaySymbols = weekdaySymbols

        return VStack(spacing: 10) {
            HStack(spacing: 8) {
                monthNavigationButton(
                    systemImage: "chevron.left",
                    help: "date-picker.previous-month",
                    offset: -1
                )

                Spacer()

                Text(monthTitle)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.codexLabel)
                    .numericTransition(value: monthTitle, comparison: displayedMonth.timeIntervalSinceReferenceDate)

                Spacer()

                monthNavigationButton(
                    systemImage: "chevron.right",
                    help: "date-picker.next-month",
                    offset: 1
                )
            }

            LazyVGrid(columns: Self.columns, spacing: 5) {
                ForEach(weekdaySymbols.indices, id: \.self) { index in
                    Text(verbatim: weekdaySymbols[index])
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: Metrics.daySize, height: 18)
                }

                ForEach(monthDates, id: \.self) { date in
                    dayButton(for: date)
                }
            }

            Group {
                if selection?.isComplete == false {
                    Text("date-picker.select-end")
                } else {
                    Text("date-picker.select-start")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(height: 14)
        }
        .padding(12)
        .frame(width: Metrics.popoverWidth, height: Metrics.popoverHeight)
    }

    private func monthNavigationButton(
        systemImage: String,
        help: LocalizedStringResource,
        offset: Int
    ) -> some View {
        Button {
            guard let nextMonth = calendar.date(byAdding: .month, value: offset, to: displayedMonth) else {
                return
            }
            displayedMonth = nextMonth
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 24, height: 22)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.055))
                }
        }
        .buttonStyle(.plain)
        .disabled(!canMoveMonth(by: offset))
        .help(help)
    }

    private func dayButton(for date: Date) -> some View {
        let dateKey = HistoryStorage.dateKey(for: date)
        let isSelectable = selectableDateRange.contains(calendar.startOfDay(for: date))
        let hasData = dataDateKeys.contains(dateKey)
        let isInDisplayedMonth = calendar.isDate(
            date,
            equalTo: displayedMonth,
            toGranularity: .month
        )
        let isStart = selection?.startDateKey == dateKey
        let isEnd = selection?.endDateKey == dateKey
        let isEndpoint = isStart || isEnd
        let isInCompletedRange = selection?.contains(dateKey) == true
        let day = calendar.component(.day, from: date)

        return Button {
            select(dateKey)
        } label: {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(dayBackgroundColor(
                        isEndpoint: isEndpoint,
                        isInCompletedRange: isInCompletedRange
                    ))

                Text(String(day))
                    .font(.system(size: 11, weight: isEndpoint ? .semibold : .regular))
                    .foregroundStyle(dayTextColor(
                        isSelectable: isSelectable,
                        isEndpoint: isEndpoint,
                        isInDisplayedMonth: isInDisplayedMonth
                    ))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if hasData, !isEndpoint {
                    Circle()
                        .fill(Color.accentColor.opacity(0.75))
                        .frame(width: 2.5, height: 2.5)
                        .padding(.bottom, 2)
                }
            }
            .frame(width: Metrics.daySize, height: Metrics.daySize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isSelectable)
    }

    private var monthTitle: String {
        Self.monthFormatter.string(from: displayedMonth)
    }

    private var monthDates: [Date] {
        let monthStart = startOfMonth(for: displayedMonth)
        let leadingDayCount = (
            calendar.component(.weekday, from: monthStart) - calendar.firstWeekday + 7
        ) % 7
        guard let gridStart = calendar.date(
            byAdding: .day,
            value: -leadingDayCount,
            to: monthStart
        ) else {
            return []
        }

        let visibleDayCount = Self.columns.count * Metrics.visibleWeekCount
        return (0 ..< visibleDayCount).compactMap { dayOffset in
            calendar.date(byAdding: .day, value: dayOffset, to: gridStart)
        }
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = .autoupdatingCurrent
        calendar.timeZone = .autoupdatingCurrent
        return calendar
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols

        let firstIndex = max(0, min(symbols.count - 1, calendar.firstWeekday - 1))
        return Array(symbols[firstIndex...] + symbols[..<firstIndex])
    }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("yyyyMMMM")
        return formatter
    }()

    private var selectableDateRange: ClosedRange<Date> {
        let today = calendar.startOfDay(for: Date())
        let cutoff = HistoryStorage.retentionCutoffDate(today: today, calendar: calendar)
        return cutoff ... today
    }

    private func startOfMonth(for date: Date) -> Date {
        let components = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: components) ?? date
    }

    private func canMoveMonth(by offset: Int) -> Bool {
        guard let candidate = calendar.date(byAdding: .month, value: offset, to: displayedMonth) else {
            return false
        }

        let month = startOfMonth(for: candidate)
        return month >= startOfMonth(for: selectableDateRange.lowerBound)
            && month <= startOfMonth(for: selectableDateRange.upperBound)
    }

    private func select(_ dateKey: String) {
        if let selection, !selection.isComplete {
            self.selection = selection.completing(with: dateKey)
            isPresented = false
        } else {
            selection = .starting(at: dateKey)
        }
    }

    private func dayBackgroundColor(
        isEndpoint: Bool,
        isInCompletedRange: Bool
    ) -> Color {
        if isEndpoint {
            return .accentColor
        }
        return isInCompletedRange ? Color.accentColor.opacity(0.16) : .clear
    }

    private func dayTextColor(
        isSelectable: Bool,
        isEndpoint: Bool,
        isInDisplayedMonth: Bool
    ) -> Color {
        if isEndpoint {
            return .white
        }
        if !isInDisplayedMonth {
            return .codexSecondaryLabel.opacity(isSelectable ? 0.58 : 0.24)
        }
        return isSelectable ? .codexLabel : .codexSecondaryLabel.opacity(0.36)
    }
}
