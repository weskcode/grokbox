import Foundation

/// Turns the phrases a model extracts ("by Friday", "the 28th", "in 5 days")
/// into dates. Deliberately conservative: an unparseable hint yields nil
/// rather than a guess, because a wrong deadline is worse than none.
public enum DueDateParser {
    public static func parse(_ hint: String?, relativeTo anchor: Date, calendar: Calendar = .current) -> Date? {
        guard let raw = hint?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let text = raw
            .replacingOccurrences(of: "by ", with: "")
            .replacingOccurrences(of: "before ", with: "")
            .replacingOccurrences(of: "on ", with: "")
            .replacingOccurrences(of: "until ", with: "")
            .replacingOccurrences(of: "due ", with: "")
            .trimmingCharacters(in: .whitespaces)

        func endOfDay(_ date: Date) -> Date {
            var parts = calendar.dateComponents([.year, .month, .day], from: date)
            parts.hour = 17; parts.minute = 0
            return calendar.date(from: parts) ?? date
        }
        func addDays(_ n: Int) -> Date { endOfDay(calendar.date(byAdding: .day, value: n, to: anchor) ?? anchor) }

        if text == "today" || text == "eod" || text.contains("end of day") || text.contains("end of the day") || text == "tonight" || text.contains("asap") {
            return endOfDay(anchor)
        }
        if text == "tomorrow" || text.hasPrefix("tomorrow") { return addDays(1) }
        if text.contains("end of week") || text.contains("end of the week") || text == "this week" || text.contains("week-end") || text.contains("weekend") {
            return endOfDay(next(weekday: 6, from: anchor, calendar: calendar, allowSameDay: true))
        }
        if text.contains("next week") { return addDays(7) }
        if text.contains("end of month") || text.contains("end of the month") {
            guard let range = calendar.range(of: .day, in: .month, for: anchor) else { return nil }
            var parts = calendar.dateComponents([.year, .month], from: anchor)
            parts.day = range.count
            return calendar.date(from: parts).map(endOfDay)
        }

        // "in 5 days", "within 14 days", "in 2 weeks", "5 days"
        if let match = firstNumber(in: text) {
            if text.contains("week") { return addDays(match * 7) }
            if text.contains("day") { return addDays(match) }
            if text.contains("hour") { return calendar.date(byAdding: .hour, value: match, to: anchor) }
        }

        // Weekday names: "friday", "next monday", "thu"
        let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        for (index, name) in weekdays.enumerated() {
            if text.contains(name) || text.split(separator: " ").contains(where: { $0.hasPrefix(String(name.prefix(3))) && $0.count <= 4 }) {
                let target = next(weekday: index + 1, from: anchor, calendar: calendar, allowSameDay: false)
                return endOfDay(text.contains("next") ? (calendar.date(byAdding: .day, value: 7, to: target) ?? target) : target)
            }
        }

        // "the 28th", "28th", "the 5th"
        if let day = ordinalDay(in: text) {
            var parts = calendar.dateComponents([.year, .month], from: anchor)
            parts.day = day
            guard let thisMonth = calendar.date(from: parts) else { return nil }
            if thisMonth >= calendar.startOfDay(for: anchor) { return endOfDay(thisMonth) }
            return calendar.date(byAdding: .month, value: 1, to: thisMonth).map(endOfDay)
        }

        // "sep 12", "12 september", "september 12th"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        let year = calendar.component(.year, from: anchor)
        let cleaned = text.replacingOccurrences(of: #"(\d+)(st|nd|rd|th)"#, with: "$1", options: .regularExpression)
        for format in ["MMM d yyyy", "MMMM d yyyy", "d MMM yyyy", "d MMMM yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: "\(cleaned) \(year)") {
                return date < anchor ? calendar.date(byAdding: .year, value: 1, to: date).map(endOfDay) : endOfDay(date)
            }
        }
        return nil
    }

    private static func next(weekday: Int, from date: Date, calendar: Calendar, allowSameDay: Bool) -> Date {
        let current = calendar.component(.weekday, from: date)
        var delta = (weekday - current + 7) % 7
        if delta == 0 && !allowSameDay { delta = 7 }
        return calendar.date(byAdding: .day, value: delta, to: date) ?? date
    }

    private static func firstNumber(in text: String) -> Int? {
        let words = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "ten": 10, "fourteen": 14]
        for (word, value) in words where text.split(separator: " ").contains(Substring(word)) { return value }
        guard let range = text.range(of: #"\d+"#, options: .regularExpression) else { return nil }
        return Int(text[range])
    }

    private static func ordinalDay(in text: String) -> Int? {
        guard let range = text.range(of: #"\b(\d{1,2})(st|nd|rd|th)\b"#, options: .regularExpression) else { return nil }
        let digits = text[range].prefix { $0.isNumber }
        guard let day = Int(digits), (1...31).contains(day) else { return nil }
        return day
    }
}

/// The prioritisation itself. Every point is named, so a row can say why it
/// sits where it does — for an ADHD reader, "why is this first?" answered
/// instantly is the difference between trust and a list that gets ignored.
public enum PriorityScorer {
    public struct Signals: Sendable {
        public var importance: Importance?
        public var actionType: ActionType
        public var dueAt: Date?
        public var receivedAt: Date
        public var isUnread: Bool
        public var isFlagged: Bool
        public var isQuick: Bool
        /// How many times the reader has written to this sender.
        public var timesContacted: Int
        public var now: Date
        /// Needed to spot mail whose value expires — a one-time code, a reset
        /// link. Empty is fine; it only ever removes urgency, never adds it.
        public var subject: String
        public var summary: String?

        public init(importance: Importance?, actionType: ActionType = .none, dueAt: Date? = nil, receivedAt: Date,
                    isUnread: Bool = true, isFlagged: Bool = false, isQuick: Bool = false, timesContacted: Int = 0, now: Date = .now,
                    subject: String = "", summary: String? = nil) {
            self.importance = importance
            self.actionType = actionType
            self.dueAt = dueAt
            self.receivedAt = receivedAt
            self.isUnread = isUnread
            self.isFlagged = isFlagged
            self.isQuick = isQuick
            self.timesContacted = timesContacted
            self.now = now
            self.subject = subject
            self.summary = summary
        }
    }

    public struct Result: Sendable, Equatable {
        public var score: Int
        public var reasons: [String]
        public var dueLabel: String?
        public var isOverdue: Bool
    }

    public static func score(_ s: Signals, calendar: Calendar = .current) -> Result {
        var score = 0
        var reasons: [String] = []
        var dueLabel: String?
        var overdue = false

        switch s.importance {
        case .needsYou: score += 50
        case .worthKnowing: score += 20
        default: break
        }

        if let due = s.dueAt {
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: s.now), to: calendar.startOfDay(for: due)).day ?? 0
            switch days {
            case ..<0: score += 25; overdue = true; dueLabel = "Overdue"; reasons.append("past its deadline")
            case 0: score += 30; dueLabel = "Due today"; reasons.append("due today")
            case 1: score += 25; dueLabel = "Due tomorrow"; reasons.append("due tomorrow")
            case 2...3: score += 18; dueLabel = "Due in \(days) days"; reasons.append("due in \(days) days")
            case 4...7: score += 10; dueLabel = "Due \(weekdayName(due, calendar))"; reasons.append("due this week")
            default: score += 3; dueLabel = "Due \(shortDate(due, calendar))"
            }
        }

        switch s.actionType {
        case .pay: score += 15; reasons.append("money")
        case .decide: score += 12; reasons.append("a decision is waiting")
        case .reply: score += 10; reasons.append("someone is waiting on a reply")
        case .attend: score += 10; reasons.append("an appointment")
        case .review: score += 8; reasons.append("something to review")
        case .none: break
        }

        if s.isFlagged { score += 20; reasons.append("you flagged it") }

        if s.timesContacted >= 3 { score += 15; reasons.append("someone you talk to often") }
        else if s.timesContacted > 0 { score += 10; reasons.append("someone you have written to") }

        // Mail whose value expires goes the other way: a verification code from
        // three months ago is not urgent, it is rubbish. The adjustment itself
        // happens at the end, so nothing can append a reason after it.
        let expired = EphemeralMail.hasExpired(subject: s.subject, summary: s.summary,
                                               receivedAt: s.receivedAt, now: s.now, calendar: calendar)

        // Unanswered mail gets heavier with age, up to a point — nagging, not
        // screaming. Never for mail that has expired.
        if s.isUnread, s.importance == .needsYou, expired == nil {
            let age = calendar.dateComponents([.day], from: s.receivedAt, to: s.now).day ?? 0
            if age >= 7 { score += 8; reasons.append("unanswered for a week") }
            else if age >= 3 { score += 5; reasons.append("unanswered for \(age) days") }
        }

        if s.isQuick { score += 5; reasons.append("quick") }

        // Last word: a message whose value has expired is not urgent, whatever
        // else was counted above. Its reason replaces the rest, because "quick,
        // someone is waiting on a reply" is a lie about a dead code.
        if let expired {
            score -= 60
            reasons = [expired.expiredReason]
            dueLabel = nil
            overdue = false
        }

        return Result(score: score, reasons: reasons, dueLabel: dueLabel, isOverdue: overdue)
    }

    private static func weekdayName(_ date: Date, _ calendar: Calendar) -> String {
        let f = DateFormatter(); f.calendar = calendar; f.dateFormat = "EEEE"; return f.string(from: date)
    }
    private static func shortDate(_ date: Date, _ calendar: Calendar) -> String {
        let f = DateFormatter(); f.calendar = calendar; f.dateFormat = "MMM d"; return f.string(from: date)
    }
}
