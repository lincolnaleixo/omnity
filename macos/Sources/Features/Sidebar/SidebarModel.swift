import Foundation

/// Omnity: the right-side panel (see Sidebar.swift). This file holds the pure parts: the data shapes
/// of the omni-tasks server and `omni-unit-context`, the window -> unit rule, history parsing, due
/// labels and the lists a style shows. No AppKit, so it is unit tested on its own.

// MARK: - Data

struct SBSub: Codable, Equatable {
    var text: String
    var done: Bool
    var index: Int
}

struct SBTask: Codable, Identifiable, Equatable {
    var id: String
    var unit: String
    var group: String?
    var title: String
    var notes: String
    var due: String?
    var repeatRule: String?
    var rev: Int
    var order: Int?
    var subtasks: [SBSub]

    enum CodingKeys: String, CodingKey {
        case id, unit, group, title, notes, due, rev, order, subtasks
        case repeatRule = "repeat"
    }

    init(id: String, unit: String, group: String? = nil, title: String, notes: String = "", due: String? = nil,
         repeatRule: String? = nil, rev: Int = 1, order: Int? = nil, subtasks: [SBSub] = []) {
        self.id = id; self.unit = unit; self.group = group; self.title = title; self.notes = notes
        self.due = due; self.repeatRule = repeatRule; self.rev = rev; self.order = order; self.subtasks = subtasks
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        unit = try c.decode(String.self, forKey: .unit)
        group = try c.decodeIfPresent(String.self, forKey: .group)
        title = try c.decode(String.self, forKey: .title)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        due = try c.decodeIfPresent(String.self, forKey: .due)
        repeatRule = try c.decodeIfPresent(String.self, forKey: .repeatRule)
        rev = try c.decodeIfPresent(Int.self, forKey: .rev) ?? 0
        order = try c.decodeIfPresent(Int.self, forKey: .order)
        subtasks = try c.decodeIfPresent([SBSub].self, forKey: .subtasks) ?? []
    }
}

struct SBTasksResponse: Codable {
    var head: Int
    var tasks: [SBTask]
    var deleted: [String]
}

struct SBEvent: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var start: String
    var end: String
    var allDay: Bool
    var calendar: String?
    var color: String?
}

struct SBEventsResponse: Codable { var events: [SBEvent] }

struct SBUnit: Codable, Equatable {
    var id: String
    var title: String
}

struct SBUnitsResponse: Codable { var units: [SBUnit] }

struct SBKpi: Codable, Equatable {
    var label: String
    var value: String
    var note: String
    var series: [Double]
}

struct SBBlueprintNext: Codable, Equatable {
    var text: String
    var impact: String
}

struct SBBlueprint: Codable, Equatable {
    var health: Int?
    var implemented: Int?
    var total: Int?
    var partial: Int?
    var routines: String?
    var next: [SBBlueprintNext]
}

/// Output of `omni-unit-context --json <unit>`.
struct SBUnitContext: Codable, Equatable {
    var unit: String
    var title: String
    var kind: String
    var type: String
    var stage: String
    var goal: String
    var kpis: [SBKpi]
    var blueprint: SBBlueprint?
}

struct SBHistory: Equatable {
    var ai: Bool
    var date: String
    var text: String
}

enum SBDueKind: Equatable { case none, overdue, today, later }

struct SBDue: Equatable {
    var label: String
    var kind: SBDueKind
}

/// A window of tmux that waits for Lincoln.
struct SBAgent: Equatable, Identifiable {
    var key: String     // session:window
    var windowID: String
    var query: String
    var age: String
    var state: String
    var id: String { key }
}

// MARK: - Styles

enum SidebarStyle: String, CaseIterable, Equatable {
    case editorial, cards, timeline, command

    /// Config values and user defaults: the name, or 1...4, or A...D.
    static func parse(_ s: String?) -> SidebarStyle? {
        let t = (s ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if let v = SidebarStyle(rawValue: t) { return v }
        switch t {
        case "1", "a": return .editorial
        case "2", "b": return .cards
        case "3", "c": return .timeline
        case "4", "d": return .command
        default: return nil
        }
    }

    var number: Int { Self.allCases.firstIndex(of: self)! + 1 }
    var letter: String { ["A", "B", "C", "D"][number - 1] }
    var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    /// Panel width in points (the prototype's 640/700/700/660 px times 0.76).
    var width: Double { [486, 532, 532, 502][number - 1] }

    /// The style in use: the user's pick wins over the config value, then editorial.
    static func resolve(saved: String?, config: String?) -> SidebarStyle {
        parse(saved) ?? parse(config) ?? .editorial
    }
}

// MARK: - Rules

enum SidebarLogic {
    static let aliases = ["lln": "longlifenutri", "tfp": "the-furry-pack", "silas": "silas-mullins"]

    /// The unit folder named by a tmux window: an alias, or the exact folder name (the rule of ow-sort).
    static func unit(forWindow name: String, units: Set<String>) -> String? {
        let n = name.trimmingCharacters(in: .whitespaces)
        if let a = aliases[n], units.contains(a) { return a }
        return units.contains(n) ? n : nil
    }

    // History lines: `🤖 2026-10-08 · agent: text` and `👤 2026-10-09 · Lincoln: text`.
    static func history(_ notes: String) -> [SBHistory] {
        notes.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let l = String(line)
            guard l.hasPrefix("🤖 ") || l.hasPrefix("👤 ") else { return nil }
            let rest = l.dropFirst(2).drop { $0 == " " }
            guard rest.count > 13, let sep = rest.range(of: " · ") else { return nil }
            let date = String(rest[rest.startIndex..<sep.lowerBound])
            guard date.count == 10, date.filter({ $0 == "-" }).count == 2 else { return nil }
            let tail = rest[sep.upperBound...]
            guard let colon = tail.firstIndex(of: ":"), tail.distance(from: tail.startIndex, to: colon) <= 40 else { return nil }
            let text = tail[tail.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            return SBHistory(ai: l.hasPrefix("🤖"), date: date, text: text)
        }
    }

    static func dayString(_ d: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    static func timeString(_ d: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    static func day(_ t: SBTask) -> String? { t.due.map { String($0.prefix(10)) } }
    /// "14:00" for a due with a time, else "".
    static func time(_ t: SBTask) -> String {
        guard let d = t.due, d.count >= 16 else { return "" }
        return String(d.dropFirst(11).prefix(5))
    }

    private static func ordinal(_ ymd: String) -> Int? {
        let p = ymd.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        guard let d = c.date(from: DateComponents(year: p[0], month: p[1], day: p[2])) else { return nil }
        return Int(d.timeIntervalSince1970 / 86400)
    }

    /// Positive = days overdue, 0 = today, negative = days ahead, nil = no date.
    static func daysOverdue(_ t: SBTask, today: String) -> Int? {
        guard let d = day(t), let a = ordinal(today), let b = ordinal(d) else { return nil }
        return a - b
    }

    static func due(_ t: SBTask, today: String) -> SBDue {
        guard let n = daysOverdue(t, today: today) else { return SBDue(label: "", kind: .none) }
        if n > 0 { return SBDue(label: "\(n)d overdue", kind: .overdue) }
        if n == 0 { let tm = time(t); return SBDue(label: tm.isEmpty ? "Today" : "Today \(tm)", kind: .today) }
        if n == -1 { return SBDue(label: "Tomorrow", kind: .later) }
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let p = day(t)!.split(separator: "-").compactMap { Int($0) }
        return SBDue(label: "\(months[p[1] - 1]) \(p[2])", kind: .later)
    }

    struct Lists: Equatable {
        var overdue: [SBTask] = []
        var today: [SBTask] = []
        var open: [SBTask] = []
        var all: [SBTask] { overdue + today + open }
    }

    /// Overdue (oldest first), today (timed first, by time), open (no date or later; by date, the Ideas group left out).
    static func lists(_ tasks: [SBTask], unit: String?, today: String) -> Lists {
        var l = Lists()
        for t in tasks where unit == nil || t.unit == unit {
            guard let n = daysOverdue(t, today: today) else { if t.group != "Ideas" { l.open.append(t) }; continue }
            if n > 0 { l.overdue.append(t) } else if n == 0 { l.today.append(t) } else { l.open.append(t) }
        }
        l.overdue.sort { ($0.due ?? "") < ($1.due ?? "") }
        l.today.sort { (time($0).isEmpty ? "99" : time($0)) < (time($1).isEmpty ? "99" : time($1)) }
        l.open.sort { ($0.due ?? "9") < ($1.due ?? "9") }
        return l
    }

    /// Tasks due today at or before `now` ("HH:mm"): what needs Lincoln right now.
    static func dueNow(_ tasks: [SBTask], unit: String?, today: String, now: String) -> [SBTask] {
        tasks.filter { t in
            (unit == nil || t.unit == unit) && day(t) == today && !time(t).isEmpty && time(t) <= now
        }
    }

    /// Windows in state "waiting", optionally of one tmux window name (the unit's window).
    static func agents(_ sessions: [TmuxSession], now: Date = Date()) -> [SBAgent] {
        sessions.flatMap { s in
            s.windows.filter { $0.state == "waiting" }.map { w in
                SBAgent(key: "\(s.name):\(w.name)", windowID: w.id, query: (w.title ?? "").isEmpty ? "Waiting for you" : w.title!,
                        age: age(since: w.activity, now: now), state: "waiting")
            }
        }
    }

    static func age(since t: Double?, now: Date) -> String {
        guard let t, t > 0 else { return "" }
        let s = max(0, Int(now.timeIntervalSince1970 - t))
        if s < 90 { return "1m" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }

    /// "09:30" from "2026-10-09T09:30:00+02:00"; "" for all-day.
    static func eventTime(_ s: String) -> String {
        guard s.count >= 16, s.contains("T") else { return "" }
        return String(s.dropFirst(11).prefix(5))
    }

    /// A stable accent for a unit from a small palette (the prototype's pastel set).
    static let palette = ["94e2d5", "fab387", "f5c2e7", "b4befe", "89dceb", "a6e3a1", "f9e2af", "cba6f7"]
    static func unitColorHex(_ unit: String) -> String {
        var h: UInt32 = 5381
        for u in unit.utf8 { h = (h &* 33) &+ UInt32(u) }
        return palette[Int(h % UInt32(palette.count))]
    }

    /// Short chip for a unit: its id, up to 8 characters.
    static func shortName(_ unit: String) -> String {
        let rev = aliases.first { $0.value == unit }?.key
        return (rev ?? unit).prefix(8).uppercased()
    }
}
