import AppKit
import SwiftUI

/// Omnity: the four looks of the right-side panel (A Editorial, B Cards, C Timeline, D Command), each
/// with a Today view and a Unit view, after the approved prototype.

extension SidebarStore {
    var nextEvent: SBEvent? {
        todaysEvents.first { SidebarLogic.eventTime($0.end) > nowHM }
    }
    var weekdayTitle: String { DateFormatter.sb("EEEE").string(from: now) }
    var dateTitle: String { DateFormatter.sb("d MMMM").string(from: now) }
    func unitName() -> String { unitTitle ?? unit ?? "" }
}

extension View {
    /// Tells the store the order of the task rows on screen (j/k move through it).
    func sbOrder(_ store: SidebarStore, _ ids: [String]) -> some View {
        self.onAppear { store.visibleOrder = ids }.onChange(of: ids) { store.visibleOrder = $0 }
    }
}

@MainActor private func ids(_ store: SidebarStore, _ section: String, _ tasks: [SBTask]) -> [String] {
    store.collapsed.contains(section) ? [] : tasks.map(\.id)
}

private struct SBRows: View {
    @ObservedObject var store: SidebarStore
    let tasks: [SBTask]
    let spec: SBRowSpec
    var showUnit = false
    var showHist = false
    var gap: CGFloat = 0

    var body: some View {
        if tasks.isEmpty {
            // Placeholders until the first data (cache or refresh) is in, so nothing flashes "Nothing here.".
            if store.ready { SBEmpty() } else { SBSkelRows(count: 2) }
        } else {
            VStack(alignment: .leading, spacing: gap) {
                ForEach(tasks) { t in
                    SBTaskRow(store: store, task: t, info: store.rowInfo(t), spec: spec, showUnit: showUnit, showHist: showHist).equatable()
                }
            }
        }
    }
}

/// The Now block: tasks an agent works on, each with its tmux window (click or ⌥N jumps there; stale ones are grey).
private struct SBNowList: View {
    @ObservedObject var store: SidebarStore
    let style: SidebarStyle
    var spacing: CGFloat = 0
    var body: some View {
        VStack(spacing: spacing) {
            ForEach(Array(store.nowItems.enumerated()), id: \.element.id) { i, n in
                SBAgentRow(store: store, agent: n.agent, style: style, key: i < 9 ? i + 1 : nil, muted: n.stale)
            }
        }
    }
}

/// "This window is working on <task>" under the header of a unit view.
private struct SBWorkingHere: View {
    let task: SBTask
    var size: CGFloat = 14
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            SBDot(color: SB.busy, size: 7, pulse: true)
            (Text("This window is working on ") + Text(task.title).fontWeight(.semibold).foregroundColor(SB.t1))
                .font(.system(size: SB.fs(size))).foregroundColor(SB.t2).lineLimit(2)
        }
    }
}

/// "Nothing here" once data is in, a placeholder before.
private struct SBPending: View {
    @ObservedObject var store: SidebarStore
    let text: String
    var body: some View { if store.ready { SBEmpty(text: text) } else { SBSkelRows(count: 1, rowHeight: SB.u(40)) } }
}

private struct SBBlueprintList: View {
    let items: [SBBlueprintNext]
    var size: CGFloat
    var limit = 5
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.prefix(limit).enumerated()), id: \.offset) { i, x in SBBlueprintRow(index: i + 1, item: x, size: size) }
        }
    }
}

private func capped(_ t: [SBTask], _ n: Int) -> [SBTask] { Array(t.prefix(n)) }

// MARK: - A Editorial

struct EditorialView: View {
    @ObservedObject var store: SidebarStore

    private var spec: SBRowSpec {
        SBRowSpec(title: 17.5, meta: 13.5, hist: 13, check: 24, pad: EdgeInsets(top: 9, leading: 10, bottom: 9, trailing: 10), radius: 12)
    }

    var body: some View {
        let L = store.lists
        let unit = store.unit
        let order: [String] = unit == nil
            ? ids(store, "ov", L.overdue) + ids(store, "td", L.today)
            : ids(store, "nd", store.derived.needsTasks) + ids(store, "op", L.open)
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                top
                if unit == nil { today(L) } else { unitView(L) }
                foot
            }
            .padding(.horizontal, SB.u(38)).padding(.top, SB.u(34)).padding(.bottom, SB.u(26))
        }
        .sbOrder(store, order)
    }

    private var top: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(store.unit.map(SB.unitColor) ?? SB.t2).frame(width: 8, height: 8)
                Text(store.unit == nil ? "All units" : store.unitName())
            }
            Spacer()
            Text("\(store.doneCount) done today")
            SBStylePicker(store: store)
            SBKbd(text: "\u{21E7}\u{2318}T")
        }
        .font(.system(size: SB.fs(13))).foregroundColor(SB.t3)
        .padding(.bottom, SB.u(18))
    }

    private func section<C: View>(_ id: String, _ title: String, _ count: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(SB.hair).frame(height: 1)
            SBSection(store: store, id: id, title: title, count: count, content: c).padding(.top, SB.u(14))
        }
        .padding(.top, SB.u(6)).padding(.bottom, SB.u(14))
    }

    private func rows(_ t: [SBTask], unit: Bool, hist: Bool) -> some View {
        SBRows(store: store, tasks: t, spec: spec, showUnit: unit, showHist: hist).padding(.horizontal, -SB.u(10))
    }

    @ViewBuilder private func today(_ L: SidebarLogic.Lists) -> some View {
        let n = L.overdue.count + L.today.count
        VStack(alignment: .leading, spacing: 4) {
            Text(store.weekdayTitle).font(SB.serif(SB.u(66))).tracking(-1.6).foregroundColor(Color(red: 0.95, green: 0.96, blue: 1))
            Text(store.dateTitle).font(SB.serif(SB.u(46), italic: true)).foregroundColor(SB.t2)
        }
        lede(n: n, overdue: L.overdue.count).padding(.top, SB.u(14)).padding(.bottom, SB.u(18))
        nowSection
        section("ag", "Waiting for you", "\(store.waiting.count)") {
            if store.waiting.isEmpty { SBEmpty(text: "Nobody is waiting.") } else {
                VStack(spacing: 0) { ForEach(store.waiting) { SBAgentRow(store: store, agent: $0, style: .editorial) } }
            }
        }
        section("ov", "Overdue", "\(L.overdue.count)") { rows(capped(L.overdue, 25), unit: true, hist: false) }
        section("td", "Today", "\(L.today.count)") { rows(L.today, unit: true, hist: false) }
        section("ev", "Calendar", "\(store.todaysEvents.count)") {
            if store.todaysEvents.isEmpty { SBPending(store: store, text: "No events today.") } else {
                VStack(spacing: 0) { ForEach(store.todaysEvents) { SBEventRow(event: $0, style: .editorial, past: SidebarLogic.eventTime($0.end) <= store.nowHM) } }
            }
        }
    }

    @ViewBuilder private var nowSection: some View {
        if !store.nowItems.isEmpty {
            section("now", "Now", "\(store.nowItems.count)") { SBNowList(store: store, style: .editorial) }
        }
    }

    private func lede(n: Int, overdue: Int) -> some View {
        var t = Text("\(n) to do").fontWeight(.semibold).foregroundColor(SB.t1) + Text(", \(overdue) overdue.")
        if let e = store.nextEvent {
            t = t + Text(" Next: ") + Text(e.title).fontWeight(.semibold).foregroundColor(SB.t1) + Text(" at \(SidebarLogic.eventTime(e.start)).")
        }
        let w = store.waiting.count
        t = t + Text(" \(w) agent\(w == 1 ? " is" : "s are") waiting for you.")
        return t.font(.system(size: SB.fs(16))).foregroundColor(SB.t2).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func unitView(_ L: SidebarLogic.Lists) -> some View {
        let c = store.context
        Text(store.unitName()).font(SB.serif(SB.u(52))).tracking(-1.2).foregroundColor(Color(red: 0.95, green: 0.96, blue: 1))
            .fixedSize(horizontal: false, vertical: true)
        if let c {
            HStack(spacing: 10) {
                if !c.stage.isEmpty {
                    Text(c.stage).font(.system(size: SB.fs(12))).foregroundColor(SB.green)
                        .padding(.horizontal, 9).padding(.vertical, 1)
                        .overlay(Capsule().strokeBorder(SB.green.opacity(0.4), lineWidth: 0.8))
                }
                Text([c.kind, c.type].filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")).foregroundColor(SB.t2)
            }
            .font(.system(size: SB.fs(13.5))).padding(.top, 10)
            if let w = store.derived.workingHere { SBWorkingHere(task: w, size: 13.5).padding(.top, 10) }
            if !c.goal.isEmpty {
                Text(c.goal).font(SB.serif(SB.u(21), italic: true)).foregroundColor(Color(red: 0.87, green: 0.89, blue: 0.97))
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 12)
            }
            if !c.kpis.isEmpty { kpis(c.kpis) }
        } else {
            if let w = store.derived.workingHere { SBWorkingHere(task: w, size: 13.5).padding(.top, 10) }
            if store.contextLoading {
                VStack(alignment: .leading, spacing: 10) {
                    SBSkel(height: SB.u(22), width: SB.u(200))
                    SBSkel(height: SB.u(24))
                    SBSkel(height: SB.u(62), radius: 8)
                }
                .padding(.top, 14)
            }
        }
        nowSection
        let n = store.derived
        section("nd", n.needsTitle, "\(n.needsAgents.count + n.needsTasks.count)") {
            if n.needsAgents.isEmpty && n.needsTasks.isEmpty { SBPending(store: store, text: "Nothing due today.") } else {
                VStack(spacing: 0) {
                    ForEach(n.needsAgents) { SBAgentRow(store: store, agent: $0, style: .editorial) }
                    if !n.needsTasks.isEmpty { rows(capped(n.needsTasks, 25), unit: false, hist: true) }
                }
            }
        }
        if let b = c?.blueprint { section("bp", "Blueprint", b.health.map { "\($0) / 100" } ?? "") { blueprint(b) } }
        else if c == nil && store.contextLoading { section("bp", "Blueprint", "") { SBSkelRows(count: 1, rowHeight: SB.u(110)) } }
        section("op", "Open", "\(L.open.count)") { rows(capped(L.open, 15), unit: false, hist: true) }
    }

    private func kpis(_ k: [SBKpi]) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(k.prefix(3).enumerated()), id: \.offset) { i, x in
                VStack(alignment: .leading, spacing: 0) {
                    Text(x.value).font(SB.serif(SB.u(36))).foregroundColor(SB.t1)
                    Text("\(x.label) \u{00B7} \(x.note)").font(.system(size: SB.fs(12.5))).foregroundColor(SB.t3).lineLimit(1)
                }
                .padding(.leading, i == 0 ? 0 : SB.u(18)).padding(.vertical, SB.u(14))
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .leading) { if i > 0 { Rectangle().fill(SB.hair).frame(width: 1) } }
            }
        }
        .overlay(alignment: .top) { Rectangle().fill(SB.hair).frame(height: 1) }
        .padding(.top, SB.u(22)).padding(.bottom, SB.u(8))
    }

    private func blueprint(_ b: SBBlueprint) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { g in
                Capsule().fill(SB.hair).overlay(alignment: .leading) {
                    Capsule().fill(LinearGradient(colors: [SB.bgd, SB.stale], startPoint: .leading, endPoint: .trailing))
                        .frame(width: g.size.width * CGFloat(b.health ?? 0) / 100)
                }
            }
            .frame(height: 3).padding(.vertical, 10)
            Text(blueprintStats(b)).font(.system(size: SB.fs(13.5))).foregroundColor(SB.t2).padding(.bottom, 8)
            SBBlueprintList(items: b.next, size: 15)
        }
    }

    private var foot: some View {
        HStack(spacing: 14) { Text("j k move"); Text("x done"); Text("\u{23CE} open in Tally") }
            .font(.system(size: SB.fs(12.5))).foregroundColor(SB.t4).padding(.top, SB.u(18))
    }
}

func blueprintStats(_ b: SBBlueprint) -> String {
    var p: [String] = []
    if let i = b.implemented, let t = b.total { p.append("\(i) of \(t) implemented") }
    if let x = b.partial { p.append("\(x) partial") }
    if let r = b.routines { p.append("routines on time \(r)") }
    return p.joined(separator: " \u{00B7} ")
}

// MARK: - B Cards

struct CardsView: View {
    @ObservedObject var store: SidebarStore

    private var spec: SBRowSpec {
        SBRowSpec(title: 16, meta: 13, hist: 12.5, check: 24, pad: EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14), radius: 16,
                  fill: SB.t1.opacity(0.06), hoverFill: SB.t1.opacity(0.10), selFill: SB.acc.opacity(0.16), selStroke: SB.acc.opacity(0.4))
    }

    var body: some View {
        let L = store.lists
        let unit = store.unit
        let order: [String] = unit == nil
            ? ids(store, "ov", L.overdue) + ids(store, "td", L.today)
            : ids(store, "nd", store.derived.needsTasks) + ids(store, "op", L.open)
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: SB.u(14)) {
                if unit == nil { today(L) } else { unitView(L) }
            }
            .padding(.bottom, SB.u(20))
        }
        .sbOrder(store, order)
    }

    private func card<C: View, E: View>(_ id: String, _ title: String, _ n: String, @ViewBuilder extra: () -> E, @ViewBuilder _ c: () -> C) -> some View {
        SBSection(store: store, id: id, title: title, count: n, style: .cards, extra: extra, content: c)
            .padding(SB.u(20))
            .frame(maxWidth: .infinity, alignment: .leading)
            .sbGlass(radius: SB.u(24))
    }
    private func card<C: View>(_ id: String, _ title: String, _ n: String, @ViewBuilder _ c: () -> C) -> some View {
        card(id, title, n, extra: { EmptyView() }, c)
    }

    private func rows(_ t: [SBTask], unit: Bool, hist: Bool) -> some View {
        SBRows(store: store, tasks: t, spec: spec, showUnit: unit, showHist: hist, gap: 8)
    }

    @ViewBuilder private func today(_ L: SidebarLogic.Lists) -> some View {
        let left = L.overdue.count + L.today.count
        HStack(spacing: SB.u(20)) {
            VStack(alignment: .leading, spacing: 6) {
                HStack { Spacer(); SBStylePicker(store: store) }.padding(.bottom, 2)
                Text("\(store.weekdayTitle), \(DateFormatter.sb("MMM d").string(from: store.now))").font(.system(size: SB.fs(34), weight: .bold)).tracking(-1)
                Text("\(left) left today \u{00B7} \(L.overdue.count) overdue \u{00B7} \(store.doneCount) done").font(.system(size: SB.fs(15))).foregroundColor(SB.t2)
                if let e = store.nextEvent {
                    Text("Next up: \(e.title), \(SidebarLogic.eventTime(e.start))").font(.system(size: SB.fs(14))).foregroundColor(SB.t3).padding(.top, 8)
                }
            }
            SBRing(value: Double(store.doneCount) / Double(max(1, store.doneCount + left)), label: "\(store.doneCount)/\(store.doneCount + left)",
                   caption: "done", size: SB.u(104), gradient: false)
        }
        .padding(SB.u(24)).frame(maxWidth: .infinity, alignment: .leading).sbGlass(radius: SB.u(24))
        nowCard
        card("ag", "Agents", "\(store.waiting.count) waiting") {
            VStack(spacing: 6) { ForEach(Array(store.agentsAll.prefix(5))) { SBAgentRow(store: store, agent: $0, style: .cards) } }
        }
        card("ov", "Overdue", "\(L.overdue.count)") { rows(capped(L.overdue, 25), unit: true, hist: false) }
        card("td", "Today", "\(L.today.count)") { rows(L.today, unit: true, hist: false) }
        card("ev", "Calendar", "\(store.todaysEvents.count)") {
            if store.todaysEvents.isEmpty { SBPending(store: store, text: "No events today.") } else {
                VStack(spacing: 6) { ForEach(store.todaysEvents) { SBEventRow(event: $0, style: .cards, past: SidebarLogic.eventTime($0.end) <= store.nowHM) } }
            }
        }
    }

    @ViewBuilder private var nowCard: some View {
        if !store.nowItems.isEmpty {
            card("now", "Now", "\(store.nowItems.count)") { SBNowList(store: store, style: .cards, spacing: 6) }
        }
    }

    @ViewBuilder private func unitView(_ L: SidebarLogic.Lists) -> some View {
        let c = store.context
        VStack(alignment: .leading, spacing: 6) {
            Text(store.unitName()).font(.system(size: SB.fs(34), weight: .bold)).tracking(-1)
            if let c {
                (Text([c.kind, c.type].filter { !$0.isEmpty }.joined(separator: " \u{00B7} ") + " \u{00B7} ") + Text(c.stage).foregroundColor(SB.green))
                    .font(.system(size: SB.fs(15))).foregroundColor(SB.t2)
                if !c.goal.isEmpty { Text(c.goal).font(.system(size: SB.fs(14))).foregroundColor(SB.t3).padding(.top, 6) }
            } else if store.contextLoading {
                SBSkel(height: SB.u(20), width: SB.u(220)).padding(.top, 2)
                SBSkel(height: SB.u(20)).padding(.top, 4)
            }
            if let w = store.derived.workingHere { SBWorkingHere(task: w).padding(.top, 6) }
        }
        .padding(SB.u(24)).frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topTrailing) { SBStylePicker(store: store).padding(SB.u(18)) }
        .sbGlass(radius: SB.u(24))
        if let c, !c.kpis.isEmpty {
            HStack(spacing: 10) {
                ForEach(Array(c.kpis.prefix(3).enumerated()), id: \.offset) { _, k in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(k.label).font(.system(size: SB.fs(12.5))).foregroundColor(SB.t2)
                        Text(k.value).font(.system(size: SB.fs(26), weight: .bold)).tracking(-0.5)
                        SBSpark(series: k.series).frame(height: 22).opacity(k.series.isEmpty ? 0 : 1)
                        Text(k.note).font(.system(size: 10)).foregroundColor(SB.t3).lineLimit(1)
                    }
                    .padding(.horizontal, SB.u(14)).padding(.top, SB.u(13)).padding(.bottom, SB.u(10))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .sbGlass(radius: SB.u(20))
                }
            }
        }
        if c == nil && store.contextLoading {
            HStack(spacing: 10) { ForEach(0..<3, id: \.self) { _ in SBSkel(height: SB.u(96), radius: SB.u(20)) } }
        }
        nowCard
        let n = store.derived
        card("nd", n.needsTitle, "\(n.needsAgents.count + n.needsTasks.count)") {
            if n.needsAgents.isEmpty && n.needsTasks.isEmpty { SBPending(store: store, text: "Nothing due today.") } else {
                VStack(spacing: 6) {
                    ForEach(n.needsAgents) { SBAgentRow(store: store, agent: $0, style: .cards) }
                    if !n.needsTasks.isEmpty { rows(capped(n.needsTasks, 25), unit: false, hist: true) }
                }
            }
        }
        if c == nil && store.contextLoading { card("bp", "Blueprint", "") { SBSkelRows(count: 1, rowHeight: SB.u(110)) } }
        if let b = c?.blueprint {
            card("bp", "Blueprint", "\(b.implemented ?? 0)/\(b.total ?? 0)") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 18) {
                        SBRing(value: Double(b.health ?? 0) / 100, label: "\(b.health ?? 0)", caption: "health", size: SB.u(84))
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(statChips(b), id: \.self) { s in
                                Text(s).font(.system(size: SB.fs(12.5))).foregroundColor(SB.t2)
                                    .padding(.horizontal, 10).padding(.vertical, 2).background(Capsule().fill(SB.t1.opacity(0.08)))
                            }
                        }
                    }
                    .padding(.bottom, 6)
                    ForEach(Array(b.next.prefix(5).enumerated()), id: \.offset) { i, x in
                        SBBlueprintRow(index: i + 1, item: x, size: 14.5).overlay(alignment: .top) { Rectangle().fill(SB.hair).frame(height: 1) }
                    }
                }
            }
        }
        card("op", "Open tasks", "\(L.open.count)") { rows(capped(L.open, 15), unit: false, hist: true) }
    }

    private func statChips(_ b: SBBlueprint) -> [String] {
        var s: [String] = []
        if let i = b.implemented { s.append("\(i) implemented") }
        if let p = b.partial { s.append("\(p) partial") }
        if let r = b.routines { s.append("routines \(r)") }
        return s
    }
}

// MARK: - C Timeline

struct DayTimelineView: View {
    @ObservedObject var store: SidebarStore
    private let px: CGFloat = SB.u(46)

    private var spec: SBRowSpec {
        SBRowSpec(title: 15.5, meta: 12.5, hist: 12.5, check: 24, pad: EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12), radius: 14,
                  selFill: SB.acc.opacity(0.14), selStroke: SB.acc.opacity(0.55))
    }

    private func minutes(_ s: String) -> Int { (Int(s.prefix(2)) ?? 0) * 60 + (Int(s.suffix(2)) ?? 0) }

    var body: some View {
        let L = store.lists
        let timed = L.today.filter { !SidebarLogic.time($0).isEmpty }
        let anytime = L.today.filter { SidebarLogic.time($0).isEmpty }
        let unitFilter = store.unit
        let events = store.todaysEvents.filter { _ in true }
        let selTimed = store.expanded.compactMap { id in timed.first { $0.id == id } }.first
        let order = ids(store, "ov", L.overdue) + ids(store, "un", anytime) + ids(store, "op", unitFilter == nil ? [] : L.open) + timed.map(\.id)
        VStack(spacing: 0) {
            strip(L)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    let here = store.waitingHere
                    if !store.nowItems.isEmpty {
                        SBSection(store: store, id: "now", title: "Now", count: "\(store.nowItems.count)", style: .timeline) {
                            SBNowList(store: store, style: .timeline)
                        }
                        .padding(.top, SB.u(14))
                    }
                    SBSection(store: store, id: "ag", title: "Waiting for you", count: "\(here.count)", style: .timeline) {
                        if here.isEmpty { SBEmpty(text: "Nobody is waiting.") } else {
                            VStack(spacing: 0) { ForEach(here) { SBAgentRow(store: store, agent: $0, style: .timeline) } }
                        }
                    }
                    .padding(.top, SB.u(14))
                    Text("DAY \u{00B7} \(DateFormatter.sb("d MMM").string(from: store.now).uppercased())")
                        .font(.system(size: SB.fs(11.5), weight: .semibold)).tracking(1.7).foregroundColor(SB.t3).padding(.top, SB.u(18)).padding(.bottom, 10)
                    timeline(events: events, timed: timed)
                    if let sx = selTimed { detail(sx) }
                    section("ov", "Overdue", "\(L.overdue.count)") {
                        SBRows(store: store, tasks: capped(L.overdue, 20), spec: spec, showUnit: unitFilter == nil, showHist: unitFilter != nil)
                    }
                    section("un", "Anytime today", "\(anytime.count)") {
                        SBRows(store: store, tasks: anytime, spec: spec, showUnit: unitFilter == nil, showHist: unitFilter != nil)
                    }
                    if let b = store.context?.blueprint {
                        section("bp", "Blueprint \u{00B7} next", "\(b.next.count)") { SBBlueprintList(items: b.next, size: 14, limit: 4) }
                    }
                    if unitFilter != nil {
                        section("op", "Open", "\(L.open.count)") { SBRows(store: store, tasks: capped(L.open, 5), spec: spec, showHist: true) }
                    }
                }
                .padding(.horizontal, SB.u(26)).padding(.top, SB.u(6)).padding(.bottom, SB.u(22))
            }
        }
        .sbOrder(store, order)
    }

    private func section<C: View>(_ id: String, _ title: String, _ n: String, @ViewBuilder _ c: () -> C) -> some View {
        SBSection(store: store, id: id, title: title, count: n, style: .timeline, content: c).padding(.top, SB.u(14))
            .padding(.horizontal, -SB.u(12)).padding(.horizontal, SB.u(12))
    }

    private func strip(_ L: SidebarLogic.Lists) -> some View {
        let c = store.context
        let accent = store.unit.map(SB.unitColor) ?? SB.t2
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if store.unit == nil {
                    Text("\(store.weekdayTitle) \(DateFormatter.sb("d").string(from: store.now))").font(.system(size: SB.fs(30), weight: .bold)).tracking(-0.8)
                    Text("\(DateFormatter.sb("MMMM").string(from: store.now)) \u{00B7} All units").font(.system(size: SB.fs(15), weight: .medium)).foregroundColor(SB.t2)
                } else {
                    Text(store.unitName()).font(.system(size: SB.fs(30), weight: .bold)).tracking(-0.8).lineLimit(1)
                    Text([c?.kind ?? "", c?.stage ?? ""].filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")).font(.system(size: SB.fs(15), weight: .medium)).foregroundColor(SB.t2).lineLimit(1)
                }
                Spacer(minLength: 0)
                SBStylePicker(store: store)
            }
            if store.unit == nil {
                Text("\(L.overdue.count + L.today.count) to do \u{00B7} \(L.overdue.count) overdue \u{00B7} \(store.waiting.count) agents waiting \u{00B7} \(store.doneCount) done")
                    .font(.system(size: SB.fs(14.5))).foregroundColor(SB.t2)
            } else if let c {
                if let w = store.derived.workingHere { SBWorkingHere(task: w, size: 14).padding(.top, 2) }
                if !c.goal.isEmpty { Text(c.goal).font(.system(size: SB.fs(14.5))).foregroundColor(SB.t2).lineLimit(2) }
                HStack(spacing: SB.u(26)) {
                    ForEach(Array(c.kpis.prefix(3).enumerated()), id: \.offset) { _, k in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(k.value).font(.system(size: SB.fs(21), weight: .semibold)).monospacedDigit()
                            Text(k.label).font(.system(size: 10.5)).foregroundColor(SB.t3)
                        }
                    }
                    if let h = c.blueprint?.health {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("\(h)").font(.system(size: SB.fs(21), weight: .semibold)).monospacedDigit()
                            Text("Blueprint health").font(.system(size: 10.5)).foregroundColor(SB.t3)
                        }
                    }
                }
                .padding(.top, 8)
            } else {
                if let w = store.derived.workingHere { SBWorkingHere(task: w, size: 14).padding(.top, 2) }
                if store.contextLoading {
                    SBSkel(height: SB.u(20)).padding(.top, 2)
                    SBSkel(height: SB.u(34), width: SB.u(260)).padding(.top, 6)
                }
            }
        }
        .padding(.leading, SB.u(26)).padding(.trailing, SB.u(26)).padding(.top, SB.u(22)).padding(.bottom, SB.u(18))
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(accent).frame(width: 4).padding(.vertical, SB.u(26)) }
        .overlay(alignment: .bottom) { Rectangle().fill(SB.hair).frame(height: 1) }
    }

    private func timeline(events: [SBEvent], timed: [SBTask]) -> some View {
        let times = events.map { minutes(SidebarLogic.eventTime($0.start)) } + events.map { minutes(SidebarLogic.eventTime($0.end)) }
            + timed.map { minutes(SidebarLogic.time($0)) } + [minutes(store.nowHM)]
        let h0 = max(0, min(9, (times.min() ?? 540) / 60 - 0))
        let h1 = min(24, max(h0 + 6, ((times.max() ?? 1260) + 59) / 60 + 1))
        let nowM = minutes(store.nowHM)
        func y(_ m: Int) -> CGFloat { CGFloat(m - h0 * 60) / 60 * px }
        return GeometryReader { g in
            let w = g.size.width - SB.u(52)
            ZStack(alignment: .topLeading) {
                ForEach(h0...h1, id: \.self) { x in
                    Rectangle().fill(SB.hair).frame(height: 1).offset(y: CGFloat(x - h0) * px)
                    Text(String(format: "%02d:00", x)).font(.system(size: 10.5).monospacedDigit()).foregroundColor(SB.t4)
                        .offset(x: 0, y: CGFloat(x - h0) * px - 7)
                }
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(SB.hair).frame(width: 1, height: CGFloat(h1 - h0) * px)
                    ForEach(events) { e in
                        let top = y(minutes(SidebarLogic.eventTime(e.start))), bottom = y(minutes(SidebarLogic.eventTime(e.end)))
                        let hh = max(SB.u(34), bottom - top - 3)
                        let c = SB.color(hex: e.color)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(e.title).font(.system(size: SB.fs(14), weight: .semibold)).lineLimit(1)
                            if hh > SB.u(40) { Text("\(SidebarLogic.eventTime(e.start)) - \(SidebarLogic.eventTime(e.end))").font(.system(size: 10.5)).foregroundColor(SB.t2) }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .frame(width: w * 0.4 - 12, height: hh, alignment: .topLeading)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(c.opacity(0.2)))
                        .overlay(alignment: .leading) { Rectangle().fill(c).frame(width: 3) }
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .opacity(SidebarLogic.eventTime(e.end) <= store.nowHM ? 0.5 : 1)
                        .offset(x: 12, y: top + 2)
                    }
                    ForEach(timed) { t in
                        timedPill(t).frame(width: w * 0.6 - 24)
                            .offset(x: w * 0.4 + 24, y: y(minutes(SidebarLogic.time(t))) - 4)
                    }
                    if nowM >= h0 * 60 {
                        ZStack(alignment: .leading) {
                            Rectangle().fill(SB.red).frame(height: 2)
                            Circle().fill(SB.red).frame(width: 8, height: 8).offset(x: -3)
                        }
                        .overlay(alignment: .trailing) {
                            Text(store.nowHM).font(.system(size: 10.5, weight: .bold)).foregroundColor(SB.ink)
                                .padding(.horizontal, 7).background(Capsule().fill(SB.red)).offset(y: -9)
                        }
                        .frame(width: w + 6).offset(x: -3, y: y(nowM))
                    }
                }
                .padding(.leading, SB.u(52))
            }
        }
        .frame(height: CGFloat(h1 - h0) * px + 4)
    }

    private func timedPill(_ t: SBTask) -> some View {
        let doing = store.completing.contains(t.id)
        let sel = store.selection == t.id
        return HStack(spacing: 10) {
            SBCheck(size: SB.u(22), done: doing) { store.complete(t.id) }
            Text(t.title).font(.system(size: SB.fs(14), weight: .medium)).lineLimit(1)
                .foregroundColor(doing ? SB.t4 : SB.t1).strikethrough(doing, color: SB.green)
            Spacer(minLength: 0)
            Text(SidebarLogic.time(t)).font(.system(size: 10.5).monospacedDigit()).foregroundColor(SB.t3)
        }
        .padding(.horizontal, 12).frame(height: SB.u(44))
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(sel ? SB.acc.opacity(0.14) : SB.t1.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(sel ? SB.acc.opacity(0.55) : SB.stroke, lineWidth: 0.6))
        .contentShape(Rectangle())
        .onTapGesture { store.toggleExpanded(t.id) }
    }

    private func detail(_ t: SBTask) -> some View {
        let hist = SidebarLogic.history(t.notes)
        return VStack(alignment: .leading, spacing: 4) {
            Text(t.title).font(.system(size: SB.fs(15), weight: .semibold)).padding(.bottom, 2)
            ForEach(t.subtasks, id: \.index) { s in
                Button { store.toggleSub(t.id, s.index) } label: {
                    HStack(spacing: 10) {
                        Circle().strokeBorder(s.done ? SB.green : SB.t3, lineWidth: 1.3).background(Circle().fill(s.done ? SB.green : .clear)).frame(width: 15, height: 15)
                        Text(s.text).strikethrough(s.done).foregroundColor(s.done ? SB.t3 : SB.t1)
                    }.font(.system(size: SB.fs(14)))
                }.buttonStyle(.plain)
            }
            ForEach(Array(hist.enumerated()), id: \.offset) { _, h in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    SBBadge(ai: h.ai); Text(String(h.date.dropFirst(5))).foregroundColor(SB.t3); Text(h.text).foregroundColor(SB.t2)
                }.font(.system(size: SB.fs(12.5)))
            }
            if store.noteFor == t.id { NoteField(store: store) }
            HStack(spacing: 8) {
                SBPillButton(title: "Open in Tally", kbd: "\u{23CE}", primary: true) { store.openInTally(t.id) }
                SBPillButton(title: "Add note") { store.beginNote(t.id) }
            }.padding(.top, 4)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(SB.acc.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(SB.acc.opacity(0.3), lineWidth: 0.6))
        .padding(.top, 6)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

// MARK: - D Command

struct CommandView: View {
    @ObservedObject var store: SidebarStore
    let font: SwitcherFonts

    private func mono(_ size: CGFloat) -> Font {
        Font(NSFont(descriptor: font.regular.fontDescriptor, size: SB.fs(size)) ?? font.regular)
    }
    private var spec: SBRowSpec {
        SBRowSpec(title: 13.5, meta: 12, hist: 12, check: 19, pad: EdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 10), radius: 8,
                  selFill: SB.acc.opacity(0.13), selBar: true, inline: true, mono: mono(13.5), gap: 11)
    }

    var body: some View {
        let L = store.lists
        let unit = store.unit
        let order = ids(store, "ov", L.overdue) + ids(store, "td", L.today) + (unit == nil ? [] : ids(store, "op", L.open))
        VStack(spacing: 0) {
            header(L)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: SB.u(6)) { content(L) }
                    .padding(.horizontal, SB.u(8)).padding(.top, SB.u(6)).padding(.bottom, SB.u(8))
            }
            footer
        }
        .font(mono(13.5))
        .environment(\.sbMono, mono(13))
        .sbOrder(store, order)
    }

    private func header(_ L: SidebarLogic.Lists) -> some View {
        HStack(spacing: 12) {
            Text("OMNI").fontWeight(.bold).tracking(0.5).foregroundColor(.white)
            Text(store.unit.map { SidebarLogic.shortName($0) } ?? "TODAY").fontWeight(.bold)
                .foregroundColor(SB.bgd).padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(SB.bgd.opacity(0.18)))
            Text("\(DateFormatter.sb("EEE dd MMM").string(from: store.now)) \u{00B7} \(store.nowHM)")
            Spacer()
            Text("\(L.overdue.count + L.today.count) open \u{00B7} \(store.doneCount) done")
            SBStylePicker(store: store)
        }
        .font(mono(13)).foregroundColor(SB.t2)
        .padding(.horizontal, SB.u(18)).padding(.vertical, SB.u(14))
        .overlay(alignment: .bottom) { Rectangle().fill(SB.hair).frame(height: 1) }
    }

    private func sec<C: View>(_ id: String, _ title: String, _ n: String, color: Color? = nil, hint: String? = nil, @ViewBuilder _ c: () -> C) -> some View {
        SBSection(store: store, id: id, title: title, count: n, style: .command, titleColor: color,
                  extra: { if let hint { Text(hint).font(mono(11.5)).foregroundColor(SB.t4).padding(.trailing, 6) } },
                  content: c)
            .padding(.top, SB.u(12)).padding(.horizontal, SB.u(10))
    }

    private func rows(_ t: [SBTask], hist: Bool) -> some View {
        SBRows(store: store, tasks: t, spec: spec, showUnit: true, showHist: hist).padding(.horizontal, -SB.u(10))
    }

    @ViewBuilder private func content(_ L: SidebarLogic.Lists) -> some View {
        let unit = store.unit
        let ags = unit == nil ? store.agentsAll : store.waitingHere
        let nn = store.nowItems.count
        if nn > 0 {
            sec("now", "Now", "\(nn)", color: SB.busy, hint: "\u{2325}1-9 jump") {
                SBNowList(store: store, style: .command).padding(.horizontal, -SB.u(10))
            }
        }
        sec("ag", "Agents", unit == nil ? "\(store.waiting.count) waiting" : "waiting \(ags.count)", color: SB.wait, hint: nn == 0 ? "\u{2325}1-9 jump" : nil) {
            if ags.isEmpty { SBEmpty(text: "Nobody is waiting.") } else {
                VStack(spacing: 0) {
                    ForEach(Array(ags.enumerated()), id: \.element.id) { i, a in SBAgentRow(store: store, agent: a, style: .command, key: nn + i < 9 ? nn + i + 1 : nil) }
                }.padding(.horizontal, -SB.u(10))
            }
        }
        if unit != nil, let c = store.context {
            sec("in", "Unit", SidebarLogic.shortName(unit!)) { kv(c) }
        } else if let u = unit, store.contextLoading {
            sec("in", "Unit", SidebarLogic.shortName(u)) { SBSkelRows(count: 3, rowHeight: SB.u(20)) }
        }
        sec("ov", "Overdue", "\(L.overdue.count)", hint: "x done") { rows(capped(L.overdue, 25), hist: unit != nil) }
        sec("td", "Today", "\(L.today.count)") { rows(L.today, hist: unit != nil) }
        if unit == nil {
            sec("ev", "Calendar", "\(store.todaysEvents.count)") {
                if store.todaysEvents.isEmpty { SBPending(store: store, text: "No events today.") } else {
                    VStack(spacing: 0) { ForEach(store.todaysEvents) { SBEventRow(event: $0, style: .command, past: SidebarLogic.eventTime($0.end) <= store.nowHM) } }
                }
            }
        } else {
            if let b = store.context?.blueprint { sec("bp", "Blueprint next", "\(b.next.count)") { SBBlueprintList(items: b.next, size: 13, limit: 5) } }
            sec("op", "Open", "\(L.open.count)") { rows(capped(L.open, 12), hist: true) }
        }
    }

    private func kv(_ c: SBUnitContext) -> some View {
        var rows: [(String, String)] = []
        rows.append(("stage", [c.stage, c.kind].filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")))
        if let w = store.derived.workingHere { rows.append(("working on", w.title)) }
        if !c.goal.isEmpty { rows.append(("goal", c.goal)) }
        for k in c.kpis { rows.append((k.label.lowercased(), "\(k.value)  \(k.note)")) }
        if let b = c.blueprint, let h = b.health {
            rows.append(("blueprint", "health \(h) \u{00B7} \(b.implemented ?? 0)/\(b.total ?? 0) impl \u{00B7} routines \(b.routines ?? "-")"))
        }
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(r.0).foregroundColor(SB.t3).frame(width: SB.u(96), alignment: .leading)
                    Text(r.1).foregroundColor(i == 0 ? SB.green : SB.t1).fixedSize(horizontal: false, vertical: true)
                }
                .font(mono(13))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            ForEach([("j k", "move"), ("x", "complete"), ("space", "expand"), ("\u{23CE}", "open"), ("\u{2325}1", "jump"), ("\u{21E7}\u{2318}T", "hide")], id: \.1) { k in
                HStack(spacing: 5) { SBKbd(text: k.0); Text(k.1) }
            }
        }
        .font(mono(12)).foregroundColor(SB.t3)
        .lineLimit(1).minimumScaleFactor(0.8)
        .padding(.horizontal, SB.u(18)).padding(.vertical, SB.u(11))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.07, green: 0.07, blue: 0.11).opacity(0.35))
        .overlay(alignment: .top) { Rectangle().fill(SB.hair).frame(height: 1) }
    }
}
