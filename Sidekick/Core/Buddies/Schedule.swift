import Foundation

/// Routine schedules. Accepted forms (case-insensitive):
///   "daily 21:00", "weekdays 09:30", "weekends 10:00", "weekly mon 08:00", "monday 08:00",
///   "every 3 hours", "every 30 minutes", or 5-field cron "m h * * dow" (dow 0–6, Sun=0; lists/ranges ok).
enum Schedule: Equatable {
    case daily(hour: Int, minute: Int)
    case weekdays(Set<Int>, hour: Int, minute: Int)        // Calendar weekday numbers 1=Sun…7=Sat
    case interval(TimeInterval)
    case cron(minutes: Set<Int>, hours: Set<Int>, weekdays: Set<Int>)   // weekdays 1…7

    static let dayNames: [String: Int] = ["sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7]

    static func parse(_ raw: String) -> Schedule? {
        let s = raw.lowercased().trimmingCharacters(in: .whitespaces)
        let parts = s.split(separator: " ").map(String.init)
        guard !parts.isEmpty else { return nil }

        if parts.count == 5, parts.allSatisfy({ $0.range(of: #"^[\d*,\-/]+$"#, options: .regularExpression) != nil }) {
            guard let m = field(parts[0], 0...59), let h = field(parts[1], 0...23), let d = field(parts[4], 0...6) else { return nil }
            return .cron(minutes: m, hours: h, weekdays: Set(d.map { $0 + 1 }))
        }
        if parts[0] == "every", parts.count >= 2 {
            let n = parts.count == 3 ? Double(parts[1]) : 1
            let unit = parts.last!
            guard let n, n > 0 else { return nil }
            if unit.hasPrefix("min") { return .interval(max(5, n) * 60) }
            if unit.hasPrefix("hour") { return .interval(n * 3600) }
            if unit.hasPrefix("day") { return .interval(n * 86_400) }
            return nil
        }
        guard let (h, m) = time(parts.last!) else { return nil }
        switch parts[0] {
        case "daily", "everyday": return .daily(hour: h, minute: m)
        case "weekdays": return .weekdays([2, 3, 4, 5, 6], hour: h, minute: m)
        case "weekends": return .weekdays([1, 7], hour: h, minute: m)
        case "weekly":
            guard parts.count == 3, let d = day(parts[1]) else { return nil }
            return .weekdays([d], hour: h, minute: m)
        default:
            if let d = day(parts[0]) { return .weekdays([d], hour: h, minute: m) }
            if parts.count == 1 { return .daily(hour: h, minute: m) }
            return nil
        }
    }

    static func day(_ s: String) -> Int? { dayNames[String(s.prefix(3))] }

    /// "21:00", "9pm", "9:30am", "0930".
    static func time(_ s: String) -> (Int, Int)? {
        var t = s
        var pm = false, am = false
        if t.hasSuffix("pm") { pm = true; t.removeLast(2) } else if t.hasSuffix("am") { am = true; t.removeLast(2) }
        let comps = t.split(separator: ":").map(String.init)
        var h: Int?, m = 0
        if comps.count == 2 { h = Int(comps[0]); m = Int(comps[1]) ?? -1 }
        else if comps.count == 1, t.count == 4, let v = Int(t) { h = v / 100; m = v % 100 }
        else if comps.count == 1 { h = Int(t) }
        guard var hour = h, (0...59).contains(m) else { return nil }
        if pm, hour < 12 { hour += 12 }
        if am, hour == 12 { hour = 0 }
        guard (0...23).contains(hour) else { return nil }
        return (hour, m)
    }

    static func field(_ f: String, _ range: ClosedRange<Int>) -> Set<Int>? {
        var out = Set<Int>()
        for item in f.split(separator: ",") {
            var step = 1
            var base = String(item)
            if let slash = base.firstIndex(of: "/") {
                step = Int(base[base.index(after: slash)...]) ?? 0
                base = String(base[..<slash])
                guard step > 0 else { return nil }
            }
            let lo: Int, hi: Int
            if base == "*" { lo = range.lowerBound; hi = range.upperBound }
            else if let dash = base.firstIndex(of: "-") {
                guard let a = Int(base[..<dash]), let b = Int(base[base.index(after: dash)...]) else { return nil }
                lo = a; hi = b
            } else {
                guard let v = Int(base) else { return nil }
                lo = v; hi = v
            }
            guard range.contains(lo), range.contains(hi), lo <= hi else { return nil }
            out.formUnion(stride(from: lo, through: hi, by: step))
        }
        return out.isEmpty ? nil : out
    }

    /// Next fire time strictly after `date`.
    func next(after date: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .interval(let s):
            return date.addingTimeInterval(s)
        case .daily(let h, let m):
            return calendar.nextDate(after: date, matching: DateComponents(hour: h, minute: m, second: 0), matchingPolicy: .nextTime)
        case .weekdays(let days, let h, let m):
            return days.compactMap {
                calendar.nextDate(after: date, matching: DateComponents(hour: h, minute: m, second: 0, weekday: $0), matchingPolicy: .nextTime)
            }.min()
        case .cron(let mins, let hours, let days):
            // Walk minute by minute over at most 8 days (bounded; cron sets are tiny).
            var t = calendar.date(bySetting: .second, value: 0, of: date.addingTimeInterval(60)) ?? date.addingTimeInterval(60)
            if t <= date { t = t.addingTimeInterval(60) }
            for _ in 0..<(8 * 24 * 60) {
                let c = calendar.dateComponents([.minute, .hour, .weekday], from: t)
                if mins.contains(c.minute!), hours.contains(c.hour!), days.contains(c.weekday!) { return t }
                t = t.addingTimeInterval(60)
            }
            return nil
        }
    }

    var label: String {
        switch self {
        case .daily(let h, let m): String(format: "every day at %02d:%02d", h, m)
        case .weekdays(let d, let h, let m):
            d == [2, 3, 4, 5, 6] ? String(format: "weekdays at %02d:%02d", h, m)
            : "\(d.sorted().compactMap { n in Self.dayNames.first { $0.value == n }?.key }.joined(separator: ", ")) " + String(format: "at %02d:%02d", h, m)
        case .interval(let s): s >= 3600 ? "every \(Int(s / 3600)) h" : "every \(Int(s / 60)) min"
        case .cron: "custom schedule"
        }
    }
}

/// Binary min-heap: O(log n) push/pop, O(1) peek.
struct MinHeap<T> {
    private var items: [T] = []
    private let less: (T, T) -> Bool
    init(_ less: @escaping (T, T) -> Bool) { self.less = less }

    var count: Int { items.count }
    var isEmpty: Bool { items.isEmpty }
    var peek: T? { items.first }

    mutating func push(_ x: T) {
        items.append(x)
        var i = items.count - 1
        while i > 0 {
            let p = (i - 1) / 2
            guard less(items[i], items[p]) else { break }
            items.swapAt(i, p); i = p
        }
    }

    @discardableResult
    mutating func pop() -> T? {
        guard !items.isEmpty else { return nil }
        items.swapAt(0, items.count - 1)
        let top = items.removeLast()
        var i = 0
        while true {
            let l = 2 * i + 1, r = l + 1
            var m = i
            if l < items.count, less(items[l], items[m]) { m = l }
            if r < items.count, less(items[r], items[m]) { m = r }
            if m == i { break }
            items.swapAt(i, m); i = m
        }
        return top
    }

    mutating func removeAll(where pred: (T) -> Bool) {
        let keep = items.filter { !pred($0) }
        items = []
        keep.forEach { push($0) }
    }
}
