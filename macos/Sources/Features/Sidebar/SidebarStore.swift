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
}

@MainActor
final class SidebarStore: ObservableObject {
    static let shared = SidebarStore()

    static let styleKey = "omnity.sidebar.style"
    static let shownKey = "omnity.sidebar.shown"

    @Published private(set) var tasks: [SBTask] = []
    @Published private(set) var events: [SBEvent] = []
    @Published private(set) var units: [SBUnit] = []
    @Published private(set) var contexts: [String: SBUnitContext] = [:]
    @Published private(set) var offline = false
    @Published private(set) var now = Date()
    @Published private(set) var style: SidebarStyle
    @Published private(set) var shown: Bool
    @Published var selection: String?
    @Published var expanded: Set<String> = []
    @Published var collapsed: Set<String> = []
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
    private var unitsAt = Date.distantPast
    private var contextAt: [String: Date] = [:]
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

    var today: String { SidebarLogic.dayString(now) }
    var nowHM: String { SidebarLogic.timeString(now) }
    var unitIDs: Set<String> { Set(units.map(\.id)) }

    var currentWindow: (session: String, window: TmuxWindow)? {
        guard let id = switcher.current else { return nil }
        for s in switcher.sessions { if let w = s.windows.first(where: { $0.id == id }) { return (s.name, w) } }
        return nil
    }
    /// The unit of the current tmux window, nil = Today mode.
    var unit: String? {
        guard let w = currentWindow else { return nil }
        return SidebarLogic.unit(forWindow: w.window.name, units: unitIDs)
    }
    var unitTitle: String? { unit.flatMap { u in units.first { $0.id == u }?.title ?? contexts[u]?.title } }
    var context: SBUnitContext? { unit.flatMap { contexts[$0] } }
    var lists: SidebarLogic.Lists { SidebarLogic.lists(tasks, unit: unit, today: today) }
    func titleOf(_ unit: String) -> String { units.first { $0.id == unit }?.title ?? unit }

    /// Every window that is not idle, waiting first (what the command style lists, and what ⌥1...9 jump to).
    var agentsAll: [SBAgent] {
        let rank = ["waiting": 0, "busy": 1, "bg": 2, "stale": 3]
        let all: [SBAgent] = switcher.sessions.flatMap { s in
            s.windows.compactMap { w in
                guard rank[w.state ?? "idle"] != nil else { return nil }
                return SBAgent(key: "\(s.name):\(w.name)", windowID: w.id, query: (w.title ?? "").isEmpty ? (w.state ?? "") : w.title!,
                               age: SidebarLogic.age(since: w.activity, now: now), state: w.state ?? "idle")
            }
        }
        return all.enumerated().sorted { a, b in
            let (x, y) = (rank[a.element.state] ?? 9, rank[b.element.state] ?? 9)
            return x != y ? x < y : a.offset < b.offset
        }.map(\.element)
    }
    var waiting: [SBAgent] { SidebarLogic.agents(switcher.sessions, now: now) }
    /// Waiting windows of the current unit's window.
    var waitingHere: [SBAgent] {
        guard let u = unit else { return waiting }
        return waiting.filter { a in
            SidebarLogic.unit(forWindow: String(a.key.split(separator: ":").last ?? ""), units: unitIDs) == u
        }
    }
    var dueNow: [SBTask] { SidebarLogic.dueNow(tasks, unit: unit, today: today, now: nowHM) }
    var jumpList: [SBAgent] { unit == nil ? agentsAll : waitingHere }

    var todaysEvents: [SBEvent] {
        events.filter { !$0.allDay }.sorted { $0.start < $1.start }
    }

    // MARK: Install

    func install() {
        guard monitor == nil else { return }
        loadCache()
        // Test builds: OMNITY_SIDEBAR_DEMO=expand:<id> or complete:<id> acts on a task a few seconds after launch.
        if let demo = ProcessInfo.processInfo.environment["OMNITY_SIDEBAR_DEMO"], let sep = demo.firstIndex(of: ":") {
            let (verb, id) = (String(demo[..<sep]), String(demo[demo.index(after: sep)...]))
            DispatchQueue.main.asyncAfter(deadline: .now() + (verb == "complete" ? 6 : 4)) { [weak self] in
                if verb == "expand" { self?.toggleExpanded(id) } else if verb == "complete" { self?.complete(id) }
            }
        }
        switcher.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.objectWillChange.send()
                self?.ensureContext()
            }
        }.store(in: &bag)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .leftMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) ?? event }
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

    func panelAppeared() { panels += 1; refresh() }
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
            guard let data = try? Data(contentsOf: url), let c = try? JSONDecoder().decode(SBCache.self, from: data) else { return }
            await MainActor.run {
                guard self.tasks.isEmpty else { return }
                self.head = c.head; self.tasks = c.tasks; self.units = c.units; self.contexts = c.contexts
                if c.eventsDay == SidebarLogic.dayString(Date()) { self.events = c.events; self.eventsDay = c.eventsDay }
                self.head = 0   // a cache is for a quick first paint; the first refresh is complete
            }
        }
    }

    private func saveCache() {
        let c = SBCache(head: head, tasks: tasks, events: events, eventsDay: eventsDay, units: units, contexts: contexts)
        let url = cacheURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(c) { try? data.write(to: url, options: .atomic) }
        }
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        now = Date()
        switcher.refresh()
        Task {
            var ok = true
            if Date().timeIntervalSince(unitsAt) > 600 || units.isEmpty {
                if let u = try? await SidebarClient.units() { units = u; unitsAt = Date() } else { ok = false }
            }
            do {
                let r = try await SidebarClient.tasks(since: head)
                applyChanges(r)
            } catch { ok = false }
            let day = SidebarLogic.dayString(Date())
            if let e = try? await SidebarClient.events(day: day) { events = e; eventsDay = day }
            offline = !ok
            refreshing = false
            saveCache()
            ensureContext(force: true)
        }
    }

    private func applyChanges(_ r: SBTasksResponse) {
        if head == 0 {
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
        guard panels > 0, let u = unit else { return }
        if let at = contextAt[u], Date().timeIntervalSince(at) < (force ? 120 : 1e9) { return }
        contextAt[u] = Date()
        let host = self.host
        Task {
            if let c = await SidebarClient.unitContext(host: host, unit: u) {
                contexts[u] = c
                saveCache()
            }
        }
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
            refreshing = false
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
            if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
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
            refreshing = false
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

    func go(_ agent: SBAgent) {
        let host = self.host
        Task {
            _ = await TmuxSwitchClient.run(host: host, ["--go", agent.windowID])
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
        // option+1...9 jumps to an agent's window.
        if mods == .option, style == .command, let n = SessionTabsKeys.digits[event.keyCode] {
            let list = jumpList
            if list.indices.contains(n - 1) { go(list[n - 1]); swallowedUps.insert(event.keyCode); return nil }
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
