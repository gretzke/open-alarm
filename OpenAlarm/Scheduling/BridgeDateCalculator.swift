import Foundation

enum BridgeDateCalculator {

    struct Result {
        var bridgeDates: [Date]        // 5 dates, ordered by fire time
        var restoreAnchorDate: Date
    }

    /// Compute 5 bridge alarm fire dates for an override on a repeating alarm.
    ///
    /// - Parameters:
    ///   - hour: The alarm's canonical hour
    ///   - minute: The alarm's canonical minute
    ///   - repeatDays: The alarm's repeat weekdays (must not be empty)
    ///   - overrideKind: `.skipNext` or `.modifyNext`
    ///   - modifiedTime: For `.modifyNext`, the new (hour, minute). Ignored for `.skipNext`.
    ///   - referenceDate: The current date (used to find "next" occurrences)
    ///   - calendar: Calendar for date math
    static func bridgeDates(
        hour: Int,
        minute: Int,
        repeatDays: [AlarmWeekday],
        overrideKind: OverrideKind,
        modifiedTime: (hour: Int, minute: Int)?,
        referenceDate: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Result {
        precondition(!repeatDays.isEmpty, "Override requires a repeating alarm")

        let neededOccurrences = overrideKind == .skipNext ? 6 : 5
        let occurrences = nextOccurrences(
            count: neededOccurrences,
            hour: hour, minute: minute,
            repeatDays: repeatDays,
            after: referenceDate,
            calendar: calendar
        )

        let firstOccurrence = occurrences[0]
        var bridgeDates: [Date]
        var restoreAnchorDate: Date

        switch overrideKind {
        case .skipNext:
            bridgeDates = Array(occurrences[1...5])
            restoreAnchorDate = firstOccurrence

        case .modifyNext:
            guard let modifiedTime else {
                preconditionFailure("modifyNext requires modifiedTime")
            }
            var modifiedComponents = calendar.dateComponents([.year, .month, .day], from: firstOccurrence)
            modifiedComponents.hour = modifiedTime.hour
            modifiedComponents.minute = modifiedTime.minute
            modifiedComponents.second = 0
            // `date(from:)` can fail for nonexistent wall-clock times (DST
            // spring-forward gap). Fall back to the first valid moment at/after
            // the requested time on that day instead of crashing.
            let modifiedDate: Date
            if let direct = calendar.date(from: modifiedComponents) {
                modifiedDate = direct
            } else {
                var matching = DateComponents()
                matching.hour = modifiedTime.hour
                matching.minute = modifiedTime.minute
                let dayStart = calendar.startOfDay(for: firstOccurrence)
                modifiedDate = calendar.nextDate(
                    after: dayStart,
                    matching: matching,
                    matchingPolicy: .nextTime,
                    repeatedTimePolicy: .first,
                    direction: .forward
                ) ?? firstOccurrence
            }

            bridgeDates = [modifiedDate] + Array(occurrences[1...4])
            restoreAnchorDate = max(firstOccurrence, modifiedDate)
        }

        return Result(bridgeDates: bridgeDates, restoreAnchorDate: restoreAnchorDate)
    }

    private static func nextOccurrences(
        count: Int,
        hour: Int,
        minute: Int,
        repeatDays: [AlarmWeekday],
        after referenceDate: Date,
        calendar: Calendar
    ) -> [Date] {
        var dates: [Date] = []
        let searchStart = referenceDate.addingTimeInterval(1)

        var nextPerDay: [(weekday: AlarmWeekday, date: Date)] = repeatDays.compactMap { weekday in
            var components = DateComponents()
            components.weekday = weekday.rawValue
            components.hour = hour
            components.minute = minute
            components.second = 0

            guard let next = calendar.nextDate(
                after: searchStart,
                matching: components,
                matchingPolicy: .nextTime,
                repeatedTimePolicy: .first,
                direction: .forward
            ) else { return nil }

            return (weekday, next)
        }

        while dates.count < count {
            guard let minIndex = nextPerDay.indices.min(by: { nextPerDay[$0].date < nextPerDay[$1].date }) else {
                break
            }

            let earliest = nextPerDay[minIndex]
            dates.append(earliest.date)

            if let nextWeek = calendar.date(byAdding: .day, value: 7, to: earliest.date) {
                nextPerDay[minIndex] = (earliest.weekday, nextWeek)
            } else {
                nextPerDay.remove(at: minIndex)
            }
        }

        return dates
    }
}
