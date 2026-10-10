import AppKit
import Combine
import SwiftUI

/// Omnity: tmux session tabs. A slim bar at the top of a window whose terminal is attached to tmux
/// on the switcher host (`macos-window-switcher-host`), one tab per tmux session. It reuses the
/// option+tab switcher's data layer (`WindowSwitcher.shared` keeps the `tmux-switch --json` cache,
/// `TmuxSwitchClient` is the ssh client); this file holds the pure model, the key routing and the
/// controller, `SessionTabsView.swift` the views.

// MARK: - Model

struct SessionTab: Equatable, Identifiable {
    var name: String
    var windows: [TmuxWindow]
    /// 1...9 for the first nine tabs (cmd+N), nil after.
    var shortcut: Int?

    var id: String { name }
    var count: Int { windows.count }
    var waiting: Int { windows.filter { $0.state == "waiting" }.count }
    var busy: Int { windows.filter { $0.state == "busy" }.count }
    var bg: Int { windows.filter { $0.state == "bg" }.count }
}

enum SessionTabsModel {
    /// `ecom, youtube,,tools` -> ["ecom", "youtube", "tools"] (trimmed, no empty names, no duplicates).
    static func parseOrder(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// The listed sessions first, in the listed order, then the rest alphabetically
    /// (case-insensitive, ties by exact name). Stable: it never depends on activity.
    static func order(_ sessions: [TmuxSession], preferred: [String]) -> [TmuxSession] {
        let rank = Dictionary(preferred.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return sessions.sorted { a, b in
            switch (rank[a.name], rank[b.name]) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil):
                let c = a.name.caseInsensitiveCompare(b.name)
                return c == .orderedSame ? a.name < b.name : c == .orderedAscending
            }
        }
    }

    static func tabs(_ sessions: [TmuxSession], preferred: [String]) -> [SessionTab] {
        order(sessions, preferred: preferred).enumerated().map { i, s in
            SessionTab(name: s.name, windows: s.windows, shortcut: i < 9 ? i + 1 : nil)
        }
    }

    /// The session that holds window `id`.
    static func session(containing id: String?, in sessions: [TmuxSession]) -> String? {
        guard let id else { return nil }
        return sessions.first { $0.windows.contains { $0.id == id } }?.name
    }

    /// `omni`, `robot@omni` and `OMNI` all match the host `omni`.
    static func hostMatches(destination: String, host: String) -> Bool {
        let host = host.trimmingCharacters(in: .whitespaces).lowercased()
        guard !host.isEmpty, host != "off" else { return false }
        let name = destination.split(separator: "@").last.map(String.init) ?? destination
        return name.lowercased() == host
    }

    /// The foreground process is `ssh <host>`.
    static func attached(argv: [String], host: String) -> Bool {
        guard let target = RemoteDrop.target(argv: argv) else { return false }
        return hostMatches(destination: target.destination, host: host)
    }

    /// A word that is safe to put in the remote command line.
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// What `tmux-switch --rename` accepts.
    static func isValidName(_ s: String) -> Bool { MoveModel.isValidName(s) }
}

// MARK: - Keys

enum SessionTabsKey: Equatable {
    /// Not ours: Ghostty handles it.
    case pass
    /// Ours but nothing to do (cmd+N with fewer than N sessions).
    case swallow
    case session(Int)
    case nativeTab(Int)
}

/// Omnity: the result of a local event monitor. `handle(...) ?? event` would turn a swallowed key (nil) back into the
/// event, so the terminal (tmux) got the key as well as Omnity's action (option+digit: Omnity sent `--go` AND tmux ran its M-N).
enum OmnityMonitor {
    static func run<T: AnyObject>(_ owner: T?, _ event: NSEvent, _ handle: (T, NSEvent) -> NSEvent?) -> NSEvent? {
        guard let owner else { return event }
        return handle(owner, event)
    }
}

enum SessionTabsKeys {
    /// Key codes of 1...9 on the number row.
    static let digits: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]

    /// Only in a window with the tab bar: cmd+N -> session N, ctrl+cmd+N -> native tab N (zero based).
    static func route(keyCode: UInt16, mods: NSEvent.ModifierFlags, barVisible: Bool, tabCount: Int) -> SessionTabsKey {
        guard barVisible, let n = digits[keyCode] else { return .pass }
        let mods = mods.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        if mods == .command { return n <= tabCount ? .session(n - 1) : .swallow }
        if mods == [.command, .control] { return .nativeTab(n - 1) }
        return .pass
    }
}

// MARK: - Controller

final class SessionTabs: ObservableObject {
    static let shared = SessionTabs()

    /// The tab clicked, shown as current until tmux confirms (or 2.5 s pass).
    @Published private(set) var optimistic: String?
    @Published private(set) var notice: String?
    /// Omnity: tab bars on screen. It publishes when a bar appears or goes, which is also the sidebar's attach signal.
    @Published private(set) var bars = 0

    private let switcher = WindowSwitcher.shared
    private var bag = Set<AnyCancellable>()
    private var monitor: Any?
    private var timer: Timer?
    private var swallowedUps = Set<UInt16>()
    private var noticeWork: DispatchWorkItem?
    private var optimisticWork: DispatchWorkItem?

    private var config: Ghostty.Config? { (NSApp.delegate as? AppDelegate)?.ghostty.config }
    var host: String { (config?.macosWindowSwitcherHost ?? "omni").trimmingCharacters(in: .whitespaces) }
    var enabled: Bool { config?.macosTmuxSessionTabs ?? false }

    var tabs: [SessionTab] {
        SessionTabsModel.tabs(switcher.sessions, preferred: SessionTabsModel.parseOrder(config?.macosTmuxSessionOrder ?? ""))
    }
    var failed: Bool { switcher.failed }
    var currentName: String? {
        optimistic ?? SessionTabsModel.session(containing: switcher.current, in: switcher.sessions)
    }

    func install() {
        guard monitor == nil else { return }
        // The switcher publishes every refresh: redraw the bars with it and drop the optimistic tab once tmux agrees.
        switcher.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
            DispatchQueue.main.async { self?.confirmOptimistic() }
        }.store(in: &bag)
        HostStats.shared.install()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            MainActor.assumeIsolated { OmnityMonitor.run(self, event) { $0.handle($1) } }
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] _ in if (self?.bars ?? 0) > 0 { self?.switcher.refresh() } }
        // While a bar is visible, a few seconds is fresh enough; never faster than one call at a time.
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            guard let self, NSApp.isActive, self.bars > 0 else { return }
            self.switcher.refresh()
        }
    }

    func barAppeared() { bars += 1; switcher.refresh(); HostStats.shared.tick() }
    func barDisappeared() { bars = max(0, bars - 1) }

    /// The tab bar shows in this surface's window: the feature is on, the foreground process is
    /// `ssh <host>` and tmux answered with at least one attached client.
    @MainActor func attached(_ surface: Ghostty.SurfaceView?) -> Bool {
        if TmuxSwitchClient.local { return enabled && switcher.current != nil }   // Omnity: test builds
        guard enabled, !host.isEmpty, switcher.current != nil,
              let pid = surface?.surfaceModel?.foregroundPID,
              let argv = RemoteDrop.processArgs(pid: pid) else { return false }
        return SessionTabsModel.attached(argv: argv, host: host)
    }

    /// Omnity: the foreground process (`ssh <host>`) of the key window's terminal, nil when none is key.
    @MainActor func keyForegroundPID() -> pid_t? {
        guard !TmuxSwitchClient.local,
              let surface = NSApp.keyWindow?.firstResponder as? Ghostty.SurfaceView,
              let pid = surface.surfaceModel?.foregroundPID, attached(surface) else { return nil }
        return pid_t(pid)
    }

    // MARK: Keys

    @MainActor private func handle(_ event: NSEvent) -> NSEvent? {
        if event.type == .keyUp { return swallowedUps.remove(event.keyCode) != nil ? nil : event }
        guard !switcher.visible,
              let window = event.window ?? NSApp.keyWindow, window.attachedSheet == nil,
              let surface = window.firstResponder as? Ghostty.SurfaceView else { return event }
        let tabs = self.tabs
        let visible = !tabs.isEmpty && attached(surface)
        switch SessionTabsKeys.route(keyCode: event.keyCode, mods: event.modifierFlags, barVisible: visible, tabCount: tabs.count) {
        case .pass:
            return event
        case .swallow:
            break
        case .session(let i):
            select(tabs[i].name, refocus: surface)
        case .nativeTab(let i):
            if let group = window.tabGroup, group.windows.indices.contains(i) {
                group.selectedWindow = group.windows[i]
            }
        }
        swallowedUps.insert(event.keyCode)
        return nil
    }

    // MARK: Actions

    /// Switches the tmux client to a session: the tab is current at once, tmux confirms after.
    func select(_ name: String, refocus surface: Ghostty.SurfaceView? = nil) {
        refocus(surface)
        guard name != currentName else { return }
        setOptimistic(name)
        run(["--session", SessionTabsModel.quote(name)]) { ok in if !ok { self.setOptimistic(nil) } }
    }

    func newWindow(in name: String, refocus surface: Ghostty.SurfaceView? = nil) {
        refocus(surface)
        setOptimistic(name)
        run(["--new-window", SessionTabsModel.quote(name)]) { ok in if !ok { self.setOptimistic(nil) } }
    }

    func rename(_ old: String, to new: String) {
        guard SessionTabsModel.isValidName(new) else {
            showNotice("Session names use letters, digits, - and _ (30 max)")
            return
        }
        guard new != old else { return }
        run(["--rename", SessionTabsModel.quote(old), SessionTabsModel.quote(new)]) { _ in }
    }

    func close(_ name: String) {
        run(["--kill-session", SessionTabsModel.quote(name)]) { _ in }
    }

    /// Asks for a new name in a sheet over `window`.
    func promptRename(_ name: String, in window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = "Rename session \u{201C}\(name)\u{201D}"
        alert.informativeText = "Letters, digits, - and _ (30 max)."
        let field = NSTextField(string: name)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            if response == .alertFirstButtonReturn {
                self?.rename(name, to: field.stringValue.trimmingCharacters(in: .whitespaces))
            }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: done) } else { done(alert.runModal()) }
    }

    /// Asks before closing: it ends everything that runs in the session.
    func confirmClose(_ tab: SessionTab, in window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close session \u{201C}\(tab.name)\u{201D}?"
        alert.informativeText = "Its \(tab.count == 1 ? "window" : "\(tab.count) windows") and everything running in "
            + "\(tab.count == 1 ? "it" : "them") will be closed."
        let close = alert.addButton(withTitle: "Close Session")
        close.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            if response == .alertFirstButtonReturn { self?.close(tab.name) }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: done) } else { done(alert.runModal()) }
    }

    // MARK: Plumbing

    private func refocus(_ surface: Ghostty.SurfaceView?) {
        guard let surface, let window = surface.window else { return }
        DispatchQueue.main.async { window.makeFirstResponder(surface) }
    }

    /// Runs `tmux-switch <args>` in the background, shows an error line when it fails, then refreshes the cache.
    private func run(_ args: [String], done: @escaping (Bool) -> Void) {
        let host = self.host
        guard !host.isEmpty else { return }
        Task {
            let r = await TmuxSwitchClient.execute(host: host, args)
            await MainActor.run {
                let ok = r?.status == 0
                if !ok { self.showNotice(MoveModel.errorText(r?.err)) }
                done(ok)
                self.switcher.refresh(force: true)
            }
        }
    }

    private func setOptimistic(_ name: String?) {
        optimistic = name
        optimisticWork?.cancel()
        guard name != nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.optimistic = nil }
        optimisticWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    private func confirmOptimistic() {
        guard let name = optimistic,
              SessionTabsModel.session(containing: switcher.current, in: switcher.sessions) == name else { return }
        setOptimistic(nil)
    }

    private func showNotice(_ text: String) {
        noticeWork?.cancel()
        notice = text
        let work = DispatchWorkItem { [weak self] in self?.notice = nil }
        noticeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }
}
