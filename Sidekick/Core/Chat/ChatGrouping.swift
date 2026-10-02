import Foundation

/// Sidebar sections: Today / Yesterday / Previous 7 days / Older.
enum ChatSection: String, CaseIterable, Identifiable {
    case today = "today", yesterday = "yesterday", week = "previous 7 days", older = "older"
    var id: String { rawValue }

    static func of(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> ChatSection {
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) { return .yesterday }
        let startToday = calendar.startOfDay(for: now)
        if let w = calendar.date(byAdding: .day, value: -7, to: startToday), date >= w { return .week }
        return .older
    }
}
