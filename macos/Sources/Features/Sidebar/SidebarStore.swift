import AppKit
import Combine
import SwiftUI

/// Omnity: state and actions of the right-side panel. It opens from a disk cache and refreshes in the
/// background (on focus, every 20 s while a panel is visible, after each action); nothing here waits
/// on the network on the main thread.

struct SBToast: Equatable, Identifiable {
    var id = UUID()
    var text: String
    var undo: Bool
}

private struct SBCache: Codable {
    var head: Int
    var tasks: [SBTask]
    var events: [SBEvent]
    var eventsDay: String
    var units: [SBUnit]
    var contexts: [String: SBUnitContext]
    var unitsAt: Date?
    var savedAt: Date?
}

/// What the views read, computed once per data change (not in view bodies).
struct SBDerived: Equatable {
    var panel = SBPanel(unit: nil)
    var dueNowIDs = Set<String>()
    var todaysEvents: [SBEvent] = []
}

/// Everything a task row shows that depends on the store, as one comparable value (rows are Equatable).
struct SBRowInfo: Equatable {
    var open = false
    var completing = false
    var selected = false
    var noting = false
    var dueNow = false
    var due = SBDue(label: "", kind: .none)
    var hist: [SBHistory] = []
}

/// Omnity: timing marks for the panel (time to first content, refresh duration). With
/// `OMNITY_SIDEBAR_TIMING=<file>` each mark is also appended to that file (test builds).
enum SBTiming {
    private static var t0 = Date()
    private static var seen = Set<String>()
    static func start() { t0 = Date() }
    static func mark(_ name: String, _ extra: String = "") {
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        let line = "sidebar-timing \(name) +\(ms)ms \(extra)\n"
        NSLog("%@", line)
        if let path = ProcessInfo.processInfo.environment["OMNITY_SIDEBAR_TIMING"], let d = line.data(using: .utf8) {
            if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(d); try? h.close() } else { try? d.write(to: URL(fileURLWithPath: path)) }
        }
    }
    static func once(_ name: String, _ extra: String = "") { if seen.insert(name).inserted { mark(name, extra) } }
}

@MainActor
final class SidebarStore: ObservableObject {
    static let shared = SidebarStore()

    static let styleKey = "omnity.sidebar.style"
    static let shownKey = "omnity.sidebar.shown"

    @Published private(set) var tasks: [SBTask] = [] { didSet { rebuild() } }
    @Published private(set) var events: [SBEvent] = [] { didSet { rebuild() } }
    @Published private(set) var units: [SBUnit] = [] { didSet { unitIDs = Set(units.map(\.id)); rebuild() } }
    @Published private(set) var contexts: [String: SBUnitContext] = [:]
    @Published private(set) var derived = SBDerived()
    /// True once there is something to show: cached tasks, or the first refresh has finished (else the views show skeletons).
    @Published private(set) var ready = false
    /// The current unit's context is being read and none is cached yet.
    @Published private(set) var contextLoading = false
    @Published private(set) var offline = false
    @Published private(set) var now = Date()
    @Published private(set) var style: SidebarStyle
    @Published private(set) var shown: Bool
    @Published var selection: String?
    @Published var expanded: Set<String> = []
    @Published var collapsed: Set<String> = []
    /// README sections the user opened ("readme:<unit>"); they start collapsed and are remembered.
    @Published var opened: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "omnity.sidebar.readmeOpen") ?? [])
    /// Sections that start collapsed use `opened`; the others use `collapsed`.
    func isCollapsed(_ id: String) -> Bool { id.hasPrefix("readme:") ? !opened.contains(id) : collapsed.contains(id) }
    @Published private(set) var completing: Set<String> = []
    @Published private(set) var doneCount = 0
    @Published private(set) var toast: SBToast?
    @Published var keysActive = false
    @Published var noteFor: String?
    @Published var noteText = ""

    private let switcher = WindowSwitcher.shared
    private var bag = Set<AnyCancellable>()
    private var monitor: Any?
    private var timer: Timer?
    private var head = 0
    private var eventsDay = ""
    private var refreshing = false
    private var refreshAgain = false
    private var refreshedAt = Date.distantPast
    private var failures = 0
    private var unitsAt = Date.distantPast
    private var contextAt: [String: Date] = [:]
    private var contextInFlight = Set<String>()
    private var saveWork: DispatchWorkItem?
    private var dueCache: [String: (due: String?, value: SBDue)] = [:]
    private var histCache: [String: (notes: String, hist: [SBHistory])] = [:]
    private var dueDay = ""
    private(set) var today = SidebarLogic.dayString(Date())
    private(set) var nowHM = SidebarLogic.timeString(Date())
    private(set) var unitIDs = Set<String>()
    private var panels = 0
    private var undoStack: [(original: SBTask, next: SBTask?)] = []
    private var toastWork: DispatchWorkItem?
    private var swallowedUps = Set<UInt16>()
    /// The panel's frame in window coordinates (to tell a click inside from outside).
    var panelFrame = CGRect.zero
    weak var panelWindow: NSWindow?
    /// The terminal surface of the window that shows the panel: where focus goes back to after typing a note.
    weak var lastSurface: Ghostty.SurfaceView?

    private var config: Ghostty.Config? { (NSApp.delegate as? AppDelegate)?.ghostty.config }
    var host: String { SessionTabs.shared.host }
    var enabled: Bool { config?.macosSidebar ?? false }

    init() {
        let d = UserDefaults.standard
        style = SidebarStyle.resolve(saved: d.string(forKey: Self.styleKey), config: nil)
        shown = d.object(forKey: Self.shownKey) as? Bool ?? true
    }

    // MARK: Derived

    var currentWindow: (session: String, window: TmuxWindow)? {
        guard let id = switcher.current else { return nil }
        for s in switcher.sessions { if let w = s.windows.first(where: { $0.id == id }) { return (s.name, w) } }
        return nil
    }
    /// The unit of the current tmux window, nil = Today mode.
    var unit: String? { derived.panel.unit }
    var unitTitle: String? { unit.flatMap { u in units.first { $0.id == u }?.title ?? contexts[u]?.title } }
    var context: SBUnitContext? { unit.flatMap { contexts[$0] } }
    var lists: SidebarLogic.Lists { derived.panel.lists }
    func titleOf(_ unit: String) -> String { units.first { $0.id == unit }?.title ?? unit }

    /// Windows not idle and not on a Now row (command and cards Today lists).
    var agentsAll: [SBAgent] { derived.panel.agentsAll }
    /// Waiting windows of the current unit (all in Today mode) that no in-progress task shows.
    var waitingHere: [SBAgent] { derived.panel.waiting }
    /// How many windows wait for Lincoln in all (for counts).
    var waitingTotal: Int { derived.panel.waitingTotal }
    var nowItems: [SBNow] { derived.panel.now }
    var todaysEvents: [SBEvent] { derived.todaysEvents }

    /// Window ids ⌃⌥1...9 jump to, aligned with the numbers on screen: the Now block first, then (command style) the agents.
    var jumpTargets: [String?] {
        let nowIDs: [String?] = nowItems.map(\.windowID)
        guard style == .command else { return nowIDs }
        return nowIDs + (unit == nil ? agentsAll : waitingHere).map { Optional($0.windowID) }
    }

    /// Recomputes `derived` from tasks, units, events, the switcher snapshot and the clock.
    private func rebuild() {
        var d = SBDerived()
        let sessions = switcher.sessions
        let cur = currentWindow
        let unit = cur.flatMap { SidebarLogic.unit(forWindow: $0.window.name, units: unitIDs, snapshot: $0.window.unit) }
        d.panel = SidebarLogic.panel(tasks: tasks, sessions: sessions, unit: unit, current: cur, unitIDs: unitIDs, today: today, at: now)
        d.dueNowIDs = Set(SidebarLogic.dueNow(tasks, unit: unit, today: today, now: nowHM).map(\.id))
        d.todaysEvents = events.filter { !$0.allDay }.sorted { $0.start < $1.start }
        if d != derived { derived = d }
        updateContextLoading()
    }

    private func setNow(_ n: Date) {
        let hm = SidebarLogic.timeString(n)
        guard hm != nowHM else { return }
        now = n
        nowHM = hm
        today = SidebarLogic.dayString(n)
        rebuild()
    }

    /// What a task row needs from the store; due labels and history are parsed once per task change.
    func rowInfo(_ t: SBTask) -> SBRowInfo {
        if dueDay != today { dueDay = today; dueCache = [:] }
        var i = SBRowInfo()
        i.open = expanded.contains(t.id)
        i.completing = completing.contains(t.id)
        i.selected = selection == t.id
        i.noting = noteFor == t.id
        i.dueNow = derived.dueNowIDs.contains(t.id)
        if let c = dueCache[t.id], c.due == t.due { i.due = c.value } else {
            i.due = SidebarLogic.due(t, today: today)
            dueCache[t.id] = (t.due, i.due)
        }
        if let c = histCache[t.id], c.notes == t.notes { i.hist = c.hist } else {
            i.hist = SidebarLogic.history(t.notes)
            histCache[t.id] = (t.notes, i.hist)
        }
        return i
    }

    // MARK: Install

    func install() {
        guard monitor == nil else { return }
        SBTiming.start()
        loadCache()

        // Test builds: OMNITY_SIDEBAR_DEMO=expand:<id> or complete:<id> acts on a task a few seconds after launch.
        if let demo = ProcessInfo.processInfo.environment["OMNITY_SIDEBAR_DEMO"], let sep = demo.firstIndex(of: ":") {
            let (verb, id) = (String(demo[..<sep]), String(demo[demo.index(after: sep)...]))
            DispatchQueue.main.asyncAfter(deadline: .now() + (verb == "complete" ? 6 : 4)) { [weak self] in
                if verb == "expand" { self?.toggleExpanded(id) } else if verb == "complete" { self?.complete(id) }
            }
        }
        // Only a real change of the tmux snapshot redraws the panel.
        Publishers.CombineLatest(switcher.$sessions, switcher.$current)
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.rebuild()
                    self?.ensureContext()
                    self?.prefetchContexts()
                }
            }.store(in: &bag)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .leftMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { OmnityMonitor.run(self, event) { $0.handle($1) } }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { if (self?.panels ?? 0) > 0 { self?.refresh() } } }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.keysActive = false } }
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, NSApp.isActive, self.panels > 0 else { return }
                self.refresh()
            }
        }
    }

    func panelAppeared() {
        panels += 1
        if Date().timeIntervalSince(refreshedAt) > 5 { refresh() }
    }
    func panelDisappeared() { panels = max(0, panels - 1) }

    /// The panel shows in this surface's window: the feature is on, it is not hidden, and the window is
    /// attached to tmux (the same test as the session tab bar).
    func visible(for surface: Ghostty.SurfaceView?) -> Bool {
        enabled && shown && SessionTabs.shared.attached(surface)
    }

    // MARK: Style and visibility

    func setStyle(_ s: SidebarStyle) {
        guard s != style else { return }
        withAnimation(.smooth(duration: 0.25)) { style = s }
        UserDefaults.standard.set(s.rawValue, forKey: Self.styleKey)
    }

    func applyConfig(_ value: String?) {
        if UserDefaults.standard.string(forKey: Self.styleKey) == nil, let s = SidebarStyle.parse(value), s != style { style = s }
    }

    func toggle() {
        withAnimation(.smooth(duration: 0.35)) { shown.toggle() }
        UserDefaults.standard.set(shown, forKey: Self.shownKey)
        if !shown { keysActive = false }
    }

    // MARK: Data

    private var cacheURL: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "omnity", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(ProcessInfo.processInfo.environment["OMNITY_SIDEBAR_CACHE"] ?? "sidebar.json")
    }

    private func loadCache() {
        let url = cacheURL
        Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url), let c = try? JSONDecoder().decode(SBCache.self, from: data) else {
                await MainActor.run { self.startRefresh() }
                return
            }
            await MainActor.run {
                defer { self.startRefresh() }
                guard self.tasks.isEmpty else { return }
                self.units = c.units; self.contexts = c.contexts
                self.tasks = c.tasks
                // A cache older than a day may miss deletions the server no longer lists: that one refreshes in full.
                self.head = Date().timeIntervalSince(c.savedAt ?? .distantPast) < 86_400 ? c.head : 0
                self.unitsAt = c.unitsAt ?? .distantPast
                if c.eventsDay == SidebarLogic.dayString(Date()) { self.events = c.events; self.eventsDay = c.eventsDay }
                if !c.tasks.isEmpty { self.ready = true }
                SBTiming.mark("cache-loaded", "tasks=\(c.tasks.count) head=\(self.head)")
            }
        }
    }

    /// Writes the cache a moment after the last change (several contexts arrive together), off the main thread.
    /// The first refresh starts as soon as the cache is read (at launch, not when the panel shows), so the wait
    /// for the tmux snapshot and the panel overlaps it.
    private func startRefresh() {
        guard enabled && shown else { return }
        refresh()
    }

    private func saveCache() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let c = SBCache(head: head, tasks: tasks, events: events, eventsDay: eventsDay, units: units, contexts: contexts,
                            unitsAt: unitsAt == .distantPast ? nil : unitsAt, savedAt: Date())
            let url = cacheURL
            Task.detached(priority: .utility) {
                if let data = try? JSONEncoder().encode(c) { try? data.write(to: url, options: .atomic) }
            }
        }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: w)
    }

    /// Reads tasks, events and (when stale) units at the same time; the unit context starts at once beside them.
    /// The tmux snapshot is the switcher's own (it polls); nothing here asks for it again.
    func refresh() {
        guard !refreshing else { refreshAgain = true; return }
        refreshing = true
        let began = Date()
        refreshedAt = began
        setNow(Date())
        ensureContext(force: true)
        prefetchContexts()
        let since = tasks.isEmpty ? 0 : head
        let needUnits = units.isEmpty || Date().timeIntervalSince(unitsAt) > 600
        let day = SidebarLogic.dayString(Date())
        Task {
            async let tasksResult = try? await SidebarClient.tasks(since: since)
            async let eventsResult = try? await SidebarClient.events(day: day)
            async let unitsResult: [SBUnit]? = needUnits ? (try? await SidebarClient.units()) : nil
            var ok = true
            if needUnits {
                if let u = await unitsResult { units = u; unitsAt = Date() } else { ok = false }
            }
            if let r = await tasksResult { applyChanges(r, since: since) } else { ok = false }
            if let e = await eventsResult { events = e; eventsDay = day }
            if ok { failures = 0; offline = false } else { failures += 1; if failures >= 2 { offline = true } }
            ready = true
            refreshing = false
            SBTiming.mark("refresh-done", "\(Int(Date().timeIntervalSince(began) * 1000))ms tasks=\(tasks.count) delta=\(since != 0)")
            saveCache()
            ensureContext(force: true)
            if refreshAgain { refreshAgain = false; refresh() }
        }
    }

    private func applyChanges(_ r: SBTasksResponse, since: Int) {
        if since == 0 {
            tasks = r.tasks
        } else {
            var byID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
            for t in r.tasks { byID[t.id] = t }
            for d in r.deleted { byID[d] = nil }
            tasks = byID.values.sorted { ($0.order ?? 0, $0.id) < ($1.order ?? 0, $1.id) }
        }
        head = r.head
    }

    /// The unit context of the current window's unit, read from the host when missing or older than 2 minutes.
    func ensureContext(force: Bool = false) {
        guard panels > 0 || (enabled && shown), let u = unit else { return }
        if let at = contextAt[u], Date().timeIntervalSince(at) < (force ? 120 : 1e9) { return }
        fetchContext(u)
    }

    /// Reads the contexts of the other tmux windows' units that are not known yet, over the same ssh connection
    /// (several run at once), so a switch of window already has its unit on screen.
    func prefetchContexts() {
        guard panels > 0 || (enabled && shown) else { return }
        for s in switcher.sessions {
            for w in s.windows {
                guard let u = SidebarLogic.unit(forWindow: w.name, units: unitIDs, snapshot: w.unit), contexts[u] == nil, contextAt[u] == nil else { continue }
                fetchContext(u)
            }
        }
    }

    private func fetchContext(_ u: String) {
        guard contextInFlight.insert(u).inserted else { return }
        contextAt[u] = Date()
        updateContextLoading()
        let host = self.host
        Task {
            let c = await SidebarClient.unitContext(host: host, unit: u)
            contextInFlight.remove(u)
            if let c {
                SBTiming.once("context-first", u)
                contexts[u] = c
                saveCache()
            }
            updateContextLoading()
        }
    }

    private func updateContextLoading() {
        let loading = unit.map { contexts[$0] == nil && contextInFlight.contains($0) } ?? false
        if loading != contextLoading { contextLoading = loading }
    }

    // MARK: Actions

    func showToast(_ text: String, undo: Bool = false) {
        toastWork?.cancel()
        withAnimation(.smooth(duration: 0.3)) { toast = SBToast(text: text, undo: undo) }
        let w = DispatchWorkItem { [weak self] in withAnimation(.smooth(duration: 0.3)) { self?.toast = nil } }
        toastWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: w)
    }

    func complete(_ id: String) {
        guard let t = tasks.first(where: { $0.id == id }), !completing.contains(id) else { return }
        let order = visibleOrder
        let i = order.firstIndex(of: id)
        let neighbour = i.flatMap { order.indices.contains($0 + 1) ? order[$0 + 1] : (i! > 0 ? order[i! - 1] : nil) }
        completing.insert(id)
        Task {
            async let result = SidebarClient.complete(t)
            try? await Task.sleep(nanoseconds: 850_000_000)
            do {
                let r = try await result
                withAnimation(.smooth(duration: 0.35)) {
                    if let next = r.task { tasks = tasks.map { $0.id == id ? next : $0 } } else { tasks.removeAll { $0.id == id } }
                    completing.remove(id)
                    expanded.remove(id)
                }
                doneCount += 1
                undoStack.append((t, r.task))
                if selection == id { selection = neighbour }
                let again = r.task.flatMap { SidebarLogic.due($0, today: today).label }.map { " \u{00B7} next \($0)" } ?? ""
                showToast("Completed: \(t.title.prefix(46))\(again)", undo: true)
            } catch {
                completing.remove(id)
                showToast("Could not complete the task")
            }
            refresh()
        }
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        toast = nil
        Task {
            do {
                try await SidebarClient.reopen(last.original, next: last.next)
                doneCount = max(0, doneCount - 1)
                selection = last.next?.id ?? selection
            } catch { showToast("Could not undo") }
            refresh()
        }
    }

    func clearDoing(_ id: String) {
        Task {
            do { try await SidebarClient.clearDoing(id) } catch { showToast("Could not clear the marker") }
            refresh()
        }
    }

    func toggleSub(_ taskID: String, _ index: Int) {
        guard let ti = tasks.firstIndex(where: { $0.id == taskID }),
              let si = tasks[ti].subtasks.firstIndex(where: { $0.index == index }) else { return }
        let before = tasks[ti]
        let sub = before.subtasks[si]
        tasks[ti].subtasks[si].done.toggle()
        Task {
            do {
                if let t = try await SidebarClient.setSubtask(before, sub, done: !sub.done),
                   let i = tasks.firstIndex(where: { $0.id == taskID }) { tasks[i] = t }
            } catch {
                if let i = tasks.firstIndex(where: { $0.id == taskID }) { tasks[i] = before }
                showToast("Could not update the subtask")
            }
        }
    }

    func toggleExpanded(_ id: String) {
        withAnimation(.smooth(duration: 0.3)) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
            if noteFor == id, !expanded.contains(id) { noteFor = nil }
        }
        selection = id
    }

    func toggleSection(_ id: String) {
        withAnimation(.smooth(duration: 0.28)) {
            if id.hasPrefix("readme:") {
                if opened.contains(id) { opened.remove(id) } else { opened.insert(id) }
                UserDefaults.standard.set(Array(opened), forKey: "omnity.sidebar.readmeOpen")
            } else if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
        }
    }

    func beginNote(_ id: String) {
        selection = id
        noteText = ""
        withAnimation(.smooth(duration: 0.25)) { noteFor = id }
    }

    func submitNote() {
        let text = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = noteFor else { return }
        noteFor = nil
        noteText = ""
        panelWindow?.makeFirstResponder(lastSurface)
        guard !text.isEmpty else { return }
        Task {
            do {
                try await SidebarClient.addNote(id, text)
                showToast("Note added")
            } catch { showToast("Could not add the note") }
            refresh()
        }
    }

    func cancelNote() {
        noteFor = nil
        noteText = ""
        panelWindow?.makeFirstResponder(lastSurface)
    }

    func openInTally(_ id: String) {
        // Tally has no URL handler yet: open the link when something answers it, else just bring Tally up.
        if let url = URL(string: "tally://task/\(id)"), NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
        } else if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.buyfromus.omni") {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
            showToast("Opened Tally")
        } else {
            showToast("Tally is not installed on this Mac")
        }
    }

    func go(_ agent: SBAgent) { go(windowID: agent.windowID) }

    func go(windowID: String) {
        guard TmuxSwitchClient.isWindowID(windowID) else { return }
        let host = self.host
        Task {
            _ = await TmuxSwitchClient.run(host: host, ["--go", windowID])
            try? await Task.sleep(nanoseconds: 400_000_000)
            switcher.refresh(force: true)
        }
    }

    // MARK: Keyboard

    /// Task ids in the order a style shows them, set by the visible style view.
    var visibleOrder: [String] = []

    private func move(_ delta: Int) {
        let o = visibleOrder
        guard !o.isEmpty else { return }
        guard let s = selection, let i = o.firstIndex(of: s) else { selection = delta > 0 ? o.first : o.last; return }
        selection = o[max(0, min(o.count - 1, i + delta))]
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        if event.type == .leftMouseDown {
            let inside = event.window != nil && event.window === panelWindow && panelFrame.contains(event.locationInWindow)
            keysActive = inside && panels > 0
            if !inside, noteFor != nil { noteFor = nil }
            return event
        }
        if event.type == .keyUp { return swallowedUps.remove(event.keyCode) != nil ? nil : event }
        guard panels > 0 || (event.modifierFlags.contains(.command) && event.keyCode == 17),
              !switcher.visible,
              let window = event.window ?? NSApp.keyWindow, window.attachedSheet == nil else { return event }
        let editing = window.firstResponder is NSText
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        // cmd+shift+T, cmd+shift+1...4: only in a window that can show the panel.
        if mods == [.command, .shift], key == "t" || ["1", "2", "3", "4", "!", "@", "#", "$"].contains(key) {
            guard enabled, let s = (window.firstResponder as? Ghostty.SurfaceView) ?? lastSurface,
                  SessionTabs.shared.attached(s) else { return event }
            if key == "t" { toggle() } else if shown {
                let n = ["1": 1, "!": 1, "2": 2, "@": 2, "3": 3, "#": 3, "4": 4, "$": 4][key]!
                setStyle(SidebarStyle.allCases[n - 1])
            }
            swallowedUps.insert(event.keyCode)
            return nil
        }
        guard panels > 0, shown else { return event }
        // control+option+1...9 jumps (option+digit belongs to tmux's M-1...9) to a window of the Now block (and, in the command style, to an agent's window).
        if mods == [.control, .option], let n = SessionTabsKeys.digits[event.keyCode] {
            let list = jumpTargets
            if list.indices.contains(n - 1), let id = list[n - 1] { go(windowID: id); swallowedUps.insert(event.keyCode); return nil }
            return event
        }
        guard keysActive, !editing, mods.isEmpty || mods == .shift else { return event }
        var handled = true
        switch (event.keyCode, key) {
        case (_, "j"), (125, _): move(1)
        case (_, "k"), (126, _): move(-1)
        case (_, "x"): if let s = selection { complete(s) }
        case (49, _): if let s = selection { toggleExpanded(s) }
        case (36, _), (76, _): if let s = selection { openInTally(s) }
        case (_, "u"): undo()
        case (_, "n"): if let s = selection { beginNote(s) }
        case (53, _): keysActive = false
        default: handled = false
        }
        if handled { swallowedUps.insert(event.keyCode); return nil }
        return event
    }
}
