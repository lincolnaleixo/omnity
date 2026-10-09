//
//  SidebarTests.swift
//  GhosttyTests
//
//  Omnity: tests for the right-side panel (window -> unit rule, parsing, due labels, lists, style persistence).
//
import Testing
import Foundation
@testable import Ghostty

struct SidebarTests {
    let units: Set<String> = ["longlifenutri", "the-furry-pack", "silas-mullins", "omni", "hmlbc", "personal"]

    // MARK: Unit rule (the one of ow-sort)

    @Test func exactFolderName() {
        #expect(SidebarLogic.unit(forWindow: "omni", units: units) == "omni")
        #expect(SidebarLogic.unit(forWindow: " hmlbc ", units: units) == "hmlbc")
    }
    @Test func aliases() {
        #expect(SidebarLogic.unit(forWindow: "lln", units: units) == "longlifenutri")
        #expect(SidebarLogic.unit(forWindow: "tfp", units: units) == "the-furry-pack")
        #expect(SidebarLogic.unit(forWindow: "silas", units: units) == "silas-mullins")
    }
    @Test func noGuessing() {
        #expect(SidebarLogic.unit(forWindow: "shell", units: units) == nil)
        #expect(SidebarLogic.unit(forWindow: "OMNI", units: units) == nil)
        #expect(SidebarLogic.unit(forWindow: "lln", units: ["omni"]) == nil)
        #expect(SidebarLogic.unit(forWindow: "", units: units) == nil)
    }

    // MARK: Parsing

    @Test func decodesATaskLikeTheServerSendsIt() throws {
        let json = #"""
        {"head": 7, "deleted": ["tgone01"], "tasks": [
          {"id": "tbxdjq7", "unit": "omni", "group": null, "title": "Build it", "notes": "n",
           "subtasks": [{"text": "one", "done": true, "index": 0}, {"text": "two", "done": false, "index": 1}],
           "due": "2026-10-09T14:00", "repeat": "weekly:fri", "alert": null, "order": 3, "rev": 12}]}
        """#
        let r = try JSONDecoder().decode(SBTasksResponse.self, from: Data(json.utf8))
        #expect(r.head == 7 && r.deleted == ["tgone01"])
        let t = r.tasks[0]
        #expect(t.id == "tbxdjq7" && t.repeatRule == "weekly:fri" && t.rev == 12)
        #expect(t.subtasks.map(\.done) == [true, false])
    }
    @Test func decodesUnitContext() throws {
        let json = #"""
        {"unit": "longlifenutri", "title": "LongLifeNutri", "kind": "Business", "type": "ecommerce", "stage": "Profit",
         "goal": "Self-running", "kpis": [{"label": "Net sales", "value": "$170.3k", "note": "Sep", "series": [1.5, 2]}],
         "blueprint": {"health": 37, "implemented": 9, "total": 96, "partial": 46, "routines": "0/27",
                       "next": [{"text": "Support SLA", "impact": "high"}]}}
        """#
        let c = try JSONDecoder().decode(SBUnitContext.self, from: Data(json.utf8))
        #expect(c.blueprint?.health == 37 && c.blueprint?.next.first?.impact == "high")
        #expect(c.kpis[0].series == [1.5, 2])
        #expect(blueprintStats(c.blueprint!) == "9 of 96 implemented \u{00B7} 46 partial \u{00B7} routines on time 0/27")
    }
    @Test func historyLines() {
        let notes = "SP-API read.\n🤖 2026-10-09 · agent: Diagnosis done: 2 SKUs red\n👤 2026-10-08 · Lincoln: go ahead\n🤖 Triaged by AI on 2026-10-01: reason\nplain"
        let h = SidebarLogic.history(notes)
        #expect(h.count == 2)
        #expect(h[0] == SBHistory(ai: true, date: "2026-10-09", text: "Diagnosis done: 2 SKUs red"))
        #expect(h[1] == SBHistory(ai: false, date: "2026-10-08", text: "go ahead"))
        #expect(SidebarLogic.history("").isEmpty)
    }

    // MARK: Dates and lists

    func task(_ id: String, _ unit: String = "omni", due: String? = nil, group: String? = nil) -> SBTask {
        SBTask(id: id, unit: unit, group: group, title: id, due: due)
    }
    @Test func dueLabels() {
        let today = "2026-10-09"
        #expect(SidebarLogic.due(task("a", due: "2026-10-05"), today: today) == SBDue(label: "4d overdue", kind: .overdue))
        #expect(SidebarLogic.due(task("a", due: "2026-10-09T14:00"), today: today) == SBDue(label: "Today 14:00", kind: .today))
        #expect(SidebarLogic.due(task("a", due: "2026-10-09"), today: today) == SBDue(label: "Today", kind: .today))
        #expect(SidebarLogic.due(task("a", due: "2026-10-10"), today: today) == SBDue(label: "Tomorrow", kind: .later))
        #expect(SidebarLogic.due(task("a", due: "2026-10-27"), today: today) == SBDue(label: "Oct 27", kind: .later))
        #expect(SidebarLogic.due(task("a"), today: today) == SBDue(label: "", kind: .none))
        // across a month end
        #expect(SidebarLogic.daysOverdue(task("a", due: "2026-09-30"), today: "2026-10-02") == 2)
    }
    @Test func lists() {
        let ts = [task("late2", due: "2026-10-07"), task("late1", due: "2026-10-05"), task("t2", due: "2026-10-09T16:00"),
                  task("t1", due: "2026-10-09T09:00"), task("any", due: "2026-10-09"), task("soon", due: "2026-10-12"),
                  task("none"), task("idea", group: "Ideas"), task("lln", "longlifenutri", due: "2026-10-09")]
        let all = SidebarLogic.lists(ts, unit: nil, today: "2026-10-09")
        #expect(all.overdue.map(\.id) == ["late1", "late2"])
        #expect(all.today.map(\.id).prefix(2) == ["t1", "t2"])   // timed first, by time
        #expect(Set(all.today.map(\.id)) == ["t1", "t2", "any", "lln"])
        #expect(all.open.map(\.id) == ["soon", "none"])   // the Ideas group is left out, undated last
        let one = SidebarLogic.lists(ts, unit: "longlifenutri", today: "2026-10-09")
        #expect(one.all.map(\.id) == ["lln"])
    }
    @Test func dueNow() {
        let ts = [task("a", due: "2026-10-09T09:00"), task("b", due: "2026-10-09T16:00"), task("c", due: "2026-10-09"), task("d", due: "2026-10-08T08:00")]
        #expect(SidebarLogic.dueNow(ts, unit: nil, today: "2026-10-09", now: "11:20").map(\.id) == ["a"])
    }

    // MARK: In progress (doing)
    @Test func decodesDoingBeforeAndAfterTheServerSendsIt() throws {
        func decode(_ extra: String) throws -> SBTask {
            try JSONDecoder().decode(SBTask.self, from: Data(#"{"id": "t1", "unit": "omni", "title": "x", "notes": ""\#(extra)}"#.utf8))
        }
        let old = try decode("")
        #expect(old.doing == nil && !old.doingStale)
        let live = try decode(#", "doing": "ecom/lln", "doingStale": false"#)
        #expect(live.doing == "ecom/lln" && !live.doingStale)
        let stale = try decode(#", "doing": "tools/omnity", "doingStale": true"#)
        #expect(stale.doing == "tools/omnity" && stale.doingStale)
        #expect(try decode(#", "doing": null"#).doing == nil)
        #expect(try decode(#", "doing": "   ""#).doing == nil)
        #expect(try decode(#", "doing": 5, "doingStale": "yes""#).doing == nil)   // wrong types never break the list
    }
    @Test func nowBlock() {
        func w(_ id: String, _ name: String, _ state: String) -> TmuxWindow {
            TmuxWindow(id: id, index: 1, name: name, state: state, title: "", path: "/", command: "claude", activity: nil, last_used: nil, active: false)
        }
        let sessions = [TmuxSession(name: "ecom", windows: [w("@1", "lln", "busy")]), TmuxSession(name: "tools", windows: [w("@3", "omnity", "idle")])]
        func doing(_ id: String, _ unit: String, _ at: String, stale: Bool = false) -> SBTask {
            SBTask(id: id, unit: unit, title: id, doing: at, doingStale: stale)
        }
        let ts = [doing("old", "omni", "tools/omnity", stale: true), doing("a", "longlifenutri", "ecom/lln"), doing("gone", "omni", "x/y"), task("plain")]
        let all = SidebarLogic.now(ts, unit: nil, sessions: sessions)
        #expect(all.map(\.id) == ["a", "gone", "old"])            // live first, stale last
        #expect(all[0].windowID == "@1" && all[0].state == "busy" && !all[0].stale)
        #expect(all[1].windowID == nil)                             // a window tmux does not list: no jump
        #expect(all[2].state == "stale" && all[2].stale)
        #expect(SidebarLogic.now(ts, unit: "omni", sessions: sessions).map(\.id) == ["gone", "old"])
    }
    // MARK: Agents

    @Test func waitingWindows() {
        func w(_ id: String, _ name: String, _ state: String, _ title: String? = "Approve?") -> TmuxWindow {
            TmuxWindow(id: id, index: 1, name: name, state: state, title: title, path: "/", command: "claude", activity: 1_000, last_used: 0, active: false)
        }
        let s = [TmuxSession(name: "ecom", windows: [w("@1", "lln", "waiting"), w("@2", "tfp", "busy")]),
                 TmuxSession(name: "tools", windows: [w("@3", "omnity", "waiting", "")])]
        let a = SidebarLogic.agents(s, now: Date(timeIntervalSince1970: 1_000 + 11 * 60))
        #expect(a.map(\.key) == ["ecom:lln", "tools:omnity"])
        #expect(a[0].age == "11m" && a[0].query == "Approve?")
        #expect(a[1].query == "Waiting for you")
    }
    @Test func ages() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(SidebarLogic.age(since: 1_000_000 - 30, now: now) == "1m")
        #expect(SidebarLogic.age(since: 1_000_000 - 3 * 3600, now: now) == "3h")
        #expect(SidebarLogic.age(since: 1_000_000 - 2 * 86400, now: now) == "2d")
        #expect(SidebarLogic.age(since: nil, now: now) == "")
    }

    // MARK: Styles

    @Test func styleParsing() {
        #expect(SidebarStyle.parse("Cards") == .cards)
        #expect(SidebarStyle.parse(" timeline ") == .timeline)
        #expect(SidebarStyle.parse("4") == .command)
        #expect(SidebarStyle.parse("a") == .editorial)
        #expect(SidebarStyle.parse("nope") == nil)
        #expect(SidebarStyle.parse(nil) == nil)
        #expect(SidebarStyle.allCases.map(\.number) == [1, 2, 3, 4])
    }
    @Test func styleResolution() {
        // the saved pick wins over the config value, then editorial
        #expect(SidebarStyle.resolve(saved: "command", config: "cards") == .command)
        #expect(SidebarStyle.resolve(saved: nil, config: "cards") == .cards)
        #expect(SidebarStyle.resolve(saved: "junk", config: "timeline") == .timeline)
        #expect(SidebarStyle.resolve(saved: nil, config: nil) == .editorial)
    }
    @MainActor @Test func stylePersists() {
        let key = SidebarStore.styleKey
        let saved = UserDefaults.standard.string(forKey: key)
        defer { if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        let store = SidebarStore()
        store.setStyle(.timeline)
        #expect(UserDefaults.standard.string(forKey: key) == "timeline")
        #expect(SidebarStore().style == .timeline)
        store.setStyle(.command)
        #expect(SidebarStore().style == .command)
    }
}
