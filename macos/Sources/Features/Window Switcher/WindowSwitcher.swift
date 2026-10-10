import AppKit
import SwiftUI

/// Omnity: option+tab window switcher for the tmux agents on the ssh host
/// (default `omni`), like cmd+tab. Hold option and press tab to open the
/// panel, tab (or shift+tab, arrows) to move, release option to switch.
///
/// Data comes from `tmux-switch` on the host over ssh, through a shared
/// ControlMaster connection so each call is fast. The host is
/// `macos-window-switcher-host` (empty disables the switcher).

// MARK: - Data

struct TmuxWindow: Decodable, Identifiable, Equatable {
    var id: String
    var index: Int?
    var name: String
    var state: String?
    var title: String?
    var path: String?
    var command: String?
    var activity: Double?
    var last_used: Double?
    var active: Bool?
}

struct TmuxSession: Decodable, Equatable {
    var name: String
    var windows: [TmuxWindow]
}

struct TmuxSnapshot: Decodable, Equatable {
    struct Current: Decodable, Equatable {
        var session: String
        var window: String
    }
    var current: Current?
    var sessions: [TmuxSession]
}

struct SwitcherEntry: Identifiable, Equatable {
    var session: String
    var window: TmuxWindow
    var id: String { window.id }
}

enum WindowSwitcherModel {
    static func entries(_ sessions: [TmuxSession]) -> [SwitcherEntry] {
        sessions.flatMap { s in s.windows.map { SwitcherEntry(session: s.name, window: $0) } }
    }

    /// Like cmd+tab: the window used before the current one, else the next
    /// one in the list. The list itself shows windows that wait for Lincoln
    /// first, so the second row is not always the previous window.
    static func defaultSelection(_ entries: [SwitcherEntry], current: String?) -> String? {
        let others = entries.filter { $0.id != current }
        let previous = others.enumerated().max { a, b in
            let (la, lb) = (a.element.window.last_used ?? 0, b.element.window.last_used ?? 0)
            return la != lb ? la < lb : a.offset > b.offset
        }
        return previous?.element.id ?? entries.first?.id
    }

    /// Selection after `delta` steps, wrapping around.
    static func move(_ entries: [SwitcherEntry], from id: String?, by delta: Int) -> String? {
        guard !entries.isEmpty else { return nil }
        guard let id, let i = entries.firstIndex(where: { $0.id == id }) else {
            return delta < 0 ? entries.last?.id : entries.first?.id
        }
        let n = entries.count
        return entries[((i + delta) % n + n) % n].id
    }

    /// "ecommerce · 1 waiting · 2 busy"
    static func header(_ s: TmuxSession) -> String {
        var parts = [s.name]
        let waiting = s.windows.filter { $0.state == "waiting" }.count
        let busy = s.windows.filter { $0.state == "busy" }.count
        if waiting > 0 { parts.append("\(waiting) waiting") }
        if busy > 0 { parts.append("\(busy) busy") }
        if parts.count == 1 { parts.append(s.windows.count == 1 ? "1 window" : "\(s.windows.count) windows") }
        return parts.joined(separator: " · ")
    }

    /// Text for the preview: SGR sequences stay (AnsiParser reads them), no trailing blank lines.
    static func clean(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        while let last = lines.last, AnsiParser.parse(last).allSatisfy({ $0.text.allSatisfy(\.isWhitespace) }) {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - ssh

enum TmuxSwitchClient {
    /// Omnity: the local port of this window's ssh connection. `tmux-switch --peer` uses it to find the tmux
    /// client of THIS window, not the one with the latest activity of all clients (another Mac, another window).
    nonisolated(unsafe) static var peer: String?
    /// `lsof -Fn` of an ssh process: the local port of its connection (`n<local>:<port>-><remote>:<port>`).
    static func localPort(lsof: String) -> String? {
        for line in lsof.split(separator: "\n") where line.hasPrefix("n") && line.contains("->") {
            let local = line.dropFirst().components(separatedBy: "->")[0]
            if let port = local.split(separator: ":").last, Int(port) != nil { return String(port) }
        }
        return nil
    }
    static func localPort(pid: pid_t) async -> String? {
        let r = await run(path: "/usr/sbin/lsof", ["-a", "-n", "-P", "-p", String(pid), "-iTCP", "-Fn"])
        return r.flatMap { localPort(lsof: String(decoding: $0, as: UTF8.self)) }
    }
    private static func run(path: String, _ args: [String]) async -> Data? {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { cont.resume(returning: nil); return }
            DispatchQueue.global(qos: .userInitiated).async {
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: data)
            }
        }
    }
    static var command: String {
        ProcessInfo.processInfo.environment["OMNITY_SWITCH_COMMAND"] ?? "/home/robot/.local/bin/tmux-switch"
    }

    /// Omnity: test builds run the commands on this Mac instead of over ssh (`OMNITY_SIDEBAR_LOCAL=1`).
    static var local: Bool { ProcessInfo.processInfo.environment["OMNITY_SIDEBAR_LOCAL"] == "1" }

    static func isWindowID(_ s: String) -> Bool {
        s.range(of: #"^@[0-9]+$"#, options: .regularExpression) != nil
    }

    /// Runs `tmux-switch <args>` on `host`; nil on any failure. One ssh
    /// connection is kept open for ten minutes (ControlPersist).
    static func run(host: String, _ args: [String]) async -> Data? {
        guard let r = await execute(host: host, args), r.status == 0 else { return nil }
        return r.out
    }
    /// Omnity: like `run`, but keeps the exit status and stderr (nil only when ssh can't start).
    struct Result {
        var status: Int32
        var out: Data
        var err: String
    }
    static func execute(host: String, _ args: [String], command: String? = nil) async -> Result? {
        // Omnity: every tmux-switch call acts on this window's own tmux client when we know its ssh port.
        let args = command == nil ? args + (peer.map { ["--peer", $0] } ?? []) : args
        let command = command ?? Self.command
        return await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: local ? "/bin/sh" : "/usr/bin/ssh")
            p.arguments = local ? ["-c", ([command] + args).joined(separator: " ")] : [
                "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=3", "-o", "LogLevel=ERROR",
                "-o", "ControlMaster=auto", "-o", "ControlPath=~/.ssh/omnity-switch-%C",
                "-o", "ControlPersist=10m", host, ([command] + args).joined(separator: " "),
            ]
            let out = Pipe()
            p.standardOutput = out
            let err = Pipe()
            p.standardError = err
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { cont.resume(returning: nil); return }
            DispatchQueue.global(qos: .userInitiated).async {
                // A hung connection must not pile up processes.
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: killer)
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                killer.cancel()
                cont.resume(returning: Result(
                    status: p.terminationStatus, out: data, err: String(decoding: errData, as: UTF8.self)))
            }
        }
    }
}

// MARK: - Controller

final class WindowSwitcher: ObservableObject {
    static let shared = WindowSwitcher()

    @Published private(set) var visible = false
    @Published private(set) var sessions: [TmuxSession] = []
    @Published private(set) var selection: String?
    @Published private(set) var current: String?
    @Published private(set) var loaded = false
    @Published private(set) var failed = false
    @Published private(set) var preview: String?
    /// Omnity: the terminal's colors, read when the panel opens.
    @Published private(set) var theme = AnsiTheme.fallback
    /// Omnity: the terminal's fonts (family, size, cell height), read when the panel opens.
    @Published private(set) var fonts = SwitcherFonts.system(size: 10.5)

    /// Omnity: move-to-session picker, last result line, session names from `--sessions`.
    @Published private(set) var picker: MovePicker?
    @Published private(set) var notice: SwitcherNotice?
    @Published private(set) var sessionNames: [String]?
    /// Omnity: the picker or a context menu is open, or option was released while one was: the panel waits for enter/esc.
    private var menuOpen = false
    private var sticky = false
    private var noticeWork: DispatchWorkItem?
    private var swallowedUps = Set<UInt16>()
    private var monitor: Any?
    private var panel: SwitcherPanel?
    private var userMoved = false
    private var backwards = false
    private var previews: [String: (text: String, at: Date)] = [:]
    private var previewWork: DispatchWorkItem?
    private var pollTimer: Timer?
    private var heldTimer: Timer?
    private var lastRefresh = Date.distantPast
    private var refreshing = false

    var entries: [SwitcherEntry] { WindowSwitcherModel.entries(sessions) }

    private var host: String {
        let config = (NSApp.delegate as? AppDelegate)?.ghostty.config
        return (config?.macosWindowSwitcherHost ?? "omni").trimmingCharacters(in: .whitespaces)
    }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
        // Keep a fresh list so the panel opens with real data at once.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.cancel() }
        NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.menuOpen = true }
        NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.menuOpen = false }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            guard let self, NSApp.isActive, !self.visible else { return }
            self.refresh()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refresh() }
    }

    // MARK: Keys

    private static let tab: UInt16 = 48
    private static let escape: UInt16 = 53
    private static let enter: UInt16 = 36
    private static let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126

    /// Returns nil to swallow the event, so it never reaches the terminal.
    private func handle(_ event: NSEvent) -> NSEvent? {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        switch event.type {
        case .flagsChanged:
            if visible && !mods.contains(.option) { optionReleased() }
            return event
        case .keyUp:
            // The release of a key we swallowed.
            return swallowedUps.remove(event.keyCode) != nil ? nil : event
        default:
            break
        }
        if !visible {
            guard event.keyCode == Self.tab,
                  mods == .option || mods == [.option, .shift],
                  !host.isEmpty,
                  NSApp.keyWindow?.firstResponder is Ghostty.SurfaceView else { return event }
            open(backwards: mods.contains(.shift))
            swallowedUps.insert(event.keyCode)
            return nil
        }
        swallowedUps.insert(event.keyCode)
        if picker != nil {
            pickerKey(event, mods)
            return nil
        }
        // Omnity: M (option held, cmd optional) moves the selected window to another session.
        if event.charactersIgnoringModifiers?.lowercased() == "m", !mods.contains(.control) {
            openPicker()
            return nil
        }
        switch event.keyCode {
        case Self.tab: step(mods.contains(.shift) ? -1 : 1)
        case Self.left, Self.up: step(-1)
        case Self.right, Self.down: step(1)
        case Self.escape: cancel()
        case Self.enter: commit()
        default: break
        }
        return nil
    }

    // MARK: Panel

    private func open(backwards: Bool) {
        guard let window = NSApp.keyWindow else { return }
        userMoved = false
        sticky = false
        picker = nil
        notice = nil
        self.backwards = backwards
        failed = false
        theme = (NSApp.delegate as? AppDelegate)?.ghostty.config.switcherTheme ?? .fallback
        if let config = (NSApp.delegate as? AppDelegate)?.ghostty.config {
            fonts = .resolve(config.omnityFont, backingScale: NSScreen.main?.backingScaleFactor ?? 2)
        }
        selection = initialSelection()
        let panel = SwitcherPanel(over: window, switcher: self)
        self.panel = panel
        visible = true
        panel.present()
        loadPreview()
        refresh()
        refreshSessionNames()
        // Option may be up already (a very quick tap); never get stuck open.
        heldTimer?.invalidate()
        let held = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            if self?.visible == true && !NSEvent.modifierFlags.contains(.option) { self?.optionReleased() }
        }
        RunLoop.main.add(held, forMode: .common)
        heldTimer = held
    }

    private func close() {
        guard visible else { return }
        visible = false
        picker = nil
        previewWork?.cancel()
        panel?.dismiss()
        panel = nil
        heldTimer?.invalidate()
        heldTimer = nil
    }

    func cancel() { close() }
    /// Omnity: releasing option switches, except while the move picker or a menu is open.
    private func optionReleased() {
        if picker != nil || menuOpen { sticky = true } else if !sticky { commit() }
    }

    func commit() {
        guard visible else { return }
        let target = selection
        close()
        if let target { goTo(target) }
    }

    /// Click on a row.
    func choose(_ id: String) {
        selection = id
        commit()
    }

    /// The previous window, or the last one for shift+option+tab.
    private func initialSelection() -> String? {
        backwards ? entries.last?.id
            : WindowSwitcherModel.defaultSelection(entries, current: current)
    }

    private func step(_ delta: Int) {
        userMoved = true
        selection = WindowSwitcherModel.move(entries, from: selection, by: delta)
        loadPreview()
    }

    // MARK: Data

    func refresh(force: Bool = false) {
        let host = self.host
        guard !host.isEmpty, force || !refreshing else { return }
        refreshing = true
        let pid = MainActor.assumeIsolated { SessionTabs.shared.keyForegroundPID() }
        Task {
            // Omnity: follow the window shown in the key Omnity window (its ssh connection), then read the snapshot.
            if let pid { TmuxSwitchClient.peer = await TmuxSwitchClient.localPort(pid: pid) }
            let data = await TmuxSwitchClient.run(host: host, ["--json"])
            let snapshot = data.flatMap { try? JSONDecoder().decode(TmuxSnapshot.self, from: $0) }
            await MainActor.run {
                self.refreshing = false
                self.lastRefresh = Date()
                // Omnity: publish only what changed (the tab bars and the sidebar redraw on each publish).
                guard let snapshot else {
                    if !self.failed { self.failed = true }
                    return
                }
                if self.failed { self.failed = false }
                if !self.loaded { self.loaded = true }
                // Once the user starts moving, the list stays as it is.
                guard force || !self.visible || !self.userMoved else { return }
                if self.sessions != snapshot.sessions { self.sessions = snapshot.sessions }
                if self.current != snapshot.current?.window { self.current = snapshot.current?.window }
                if force {
                    // Omnity: after a move the selection stays on the same window.
                    if self.visible, !self.entries.contains(where: { $0.id == self.selection }) {
                        self.selection = self.initialSelection()
                        self.loadPreview()
                    }
                } else if self.visible {
                    self.selection = self.initialSelection()
                    self.loadPreview()
                }
            }
        }
    }

    private func goTo(_ id: String) {
        guard TmuxSwitchClient.isWindowID(id), id != current else { return }
        // Local bookkeeping first, so the next option+tab already toggles back.
        let now = Date().timeIntervalSince1970
        current = id
        sessions = sessions.map { s in
            var s = s
            s.windows = s.windows.map { w in
                var w = w
                if w.id == id { w.last_used = now }
                return w
            }
            return s
        }
        let host = self.host
        Task {
            _ = await TmuxSwitchClient.run(host: host, ["--go", id])
            try? await Task.sleep(nanoseconds: 400_000_000)
            await MainActor.run { self.refresh() }
        }
    }

    // MARK: Move to session
    /// Omnity: sessions the window can move to (its own excluded).
    func moveTargets(for id: String) -> [String] {
        let from = entries.first { $0.id == id }?.session
        let names = sessionNames ?? sessions.map(\.name)
        return names.filter { $0 != from }
    }
    var pickerRows: [MoveRow] {
        guard let p = picker, !p.naming else { return [] }
        return MoveModel.rows(sessions: sessionNames ?? sessions.map(\.name), from: p.from, query: p.query)
    }
    func windowCount(session: String) -> Int? {
        sessions.first { $0.name == session }?.windows.count
    }
    func refreshSessionNames() {
        let host = self.host
        guard !host.isEmpty else { return }
        Task {
            guard let data = await TmuxSwitchClient.run(host: host, ["--sessions"]) else { return }
            let names = MoveModel.parseSessions(String(decoding: data, as: UTF8.self))
            await MainActor.run { if !names.isEmpty { self.sessionNames = names } }
        }
    }
    /// Opens the picker for the selected window, or for `id` (context menu); `naming` goes straight to the new session name field.
    func openPicker(for id: String? = nil, naming: Bool = false) {
        guard visible, let id = id ?? selection, let entry = entries.first(where: { $0.id == id }) else { return }
        selection = id
        picker = MovePicker(windowID: id, windowName: entry.window.name, from: entry.session)
        picker?.naming = naming
        notice = nil
        refreshSessionNames()
    }
    func closePicker() { picker = nil }
    func pickerChoose(_ row: MoveRow) {
        guard let p = picker, !p.busy else { return }
        if row.kind == .prompt {
            // "+ New session…": the same field now takes the name.
            picker?.naming = true
            picker?.query = ""
            picker?.error = nil
            return
        }
        move(p.windowID, to: row.name)
    }
    /// Enter in the new session name field.
    private func submitName(_ p: MovePicker) {
        if p.query.isEmpty {
            picker?.error = "Type a session name"
        } else if p.query == p.from {
            picker?.error = "The window is already in \(p.from)"
        } else {
            move(p.windowID, to: p.query)
        }
    }
    private func pickerKey(_ event: NSEvent, _ mods: NSEvent.ModifierFlags) {
        guard var p = picker, !p.busy else { return }
        let rows = pickerRows
        switch event.keyCode {
        case Self.escape:
            if p.naming {
                // Back to the list.
                p.naming = false
                p.query = ""
                p.highlight = 0
                p.error = nil
                picker = p
            } else {
                picker = nil
            }
            return
        case Self.enter, 76:
            if p.naming {
                submitName(p)
            } else if rows.indices.contains(p.highlight) {
                pickerChoose(rows[p.highlight])
            }
            return
        case Self.down, Self.up, Self.tab:
            let delta = event.keyCode == Self.down || (event.keyCode == Self.tab && !mods.contains(.shift)) ? 1 : -1
            if !rows.isEmpty { p.highlight = (p.highlight + delta + rows.count) % rows.count }
        case 51: // delete
            if !p.query.isEmpty { p.query.removeLast() }
            p.highlight = p.naming ? 0 : MoveModel.defaultHighlight(
                MoveModel.rows(sessions: sessionNames ?? sessions.map(\.name), from: p.from, query: p.query))
            p.error = nil
        default:
            guard !mods.contains(.command), !mods.contains(.control) else { return }
            // Only shift counts, so option+letter still types the letter.
            let typed = event.characters(byApplyingModifiers: mods.intersection(.shift)) ?? ""
            for c in typed where MoveModel.isAllowedCharacter(c) && p.query.count < MoveModel.maxName {
                p.query.append(c)
                p.error = nil
            }
            p.highlight = p.naming ? 0 : MoveModel.defaultHighlight(
                MoveModel.rows(sessions: sessionNames ?? sessions.map(\.name), from: p.from, query: p.query))
        }
        picker = p
    }
    /// Moves a window into `session` (created when missing), then refreshes the list.
    func move(_ id: String, to session: String) {
        let host = self.host
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        guard let args = MoveModel.command(window: id, session: session) else {
            fail("Session names use letters, digits, - and _ (30 max)")
            return
        }
        selection = id
        if picker != nil { picker?.busy = true; picker?.error = nil }
        let name = entry.window.name
        let created = !(sessionNames ?? sessions.map(\.name)).contains(session)
        Task {
            let r = await TmuxSwitchClient.execute(host: host, args)
            await MainActor.run {
                guard let r, r.status == 0 else {
                    self.fail(MoveModel.errorText(r?.err))
                    return
                }
                self.picker = nil
                self.showNotice(MoveModel.confirmation(window: name, to: session, created: created), isError: false)
                self.refresh(force: true)
                self.refreshSessionNames()
            }
        }
    }
    private func fail(_ message: String) {
        if picker != nil {
            picker?.busy = false
            picker?.error = message
        } else {
            showNotice(message, isError: true)
        }
    }
    private func showNotice(_ text: String, isError: Bool) {
        noticeWork?.cancel()
        notice = SwitcherNotice(text: text, isError: isError)
        let work = DispatchWorkItem { [weak self] in self?.notice = nil }
        noticeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (isError ? 6 : 3), execute: work)
    }
    // MARK: Preview

    /// Shows the cached text at once, then refreshes it (debounced).
    private func loadPreview() {
        previewWork?.cancel()
        guard let id = selection, TmuxSwitchClient.isWindowID(id) else {
            preview = nil
            return
        }
        let cached = previews[id]
        preview = cached?.text
        if let cached, Date().timeIntervalSince(cached.at) < 1.5 { return }
        let host = self.host
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task {
                let data = await TmuxSwitchClient.run(host: host, ["--preview", id, "30", "--ansi"])
                await MainActor.run {
                    guard let data else { return }
                    let text = WindowSwitcherModel.clean(String(decoding: data, as: UTF8.self))
                    self.previews[id] = (text, Date())
                    if self.selection == id { self.preview = text }
                }
            }
        }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }
}

// MARK: - Panel

/// A borderless panel over the focused window. It never takes focus, so the
/// terminal stays key and the key events are read by the monitor above.
final class SwitcherPanel: NSPanel {
    private weak var anchor: NSWindow?

    static let cornerRadius: CGFloat = 18

    /// A stretchable rounded rectangle: only the corners are fixed.
    /// Omnity: internal, the session tabs hover card uses it too.
    static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(over window: NSWindow, switcher: WindowSwitcher) {
        let width = min(920, max(420, window.frame.width - 80))
        let height = min(560, max(320, window.frame.height - 80))
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        anchor = window
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .darkAqua)

        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        // Omnity: the behind-window blur is drawn by the window server and ignores a layer
        // corner radius (square corners and a hard edge showed through, and the shadow followed
        // them). maskImage rounds the blur itself, so the window shape and its shadow are round.
        // The hairline is drawn by the SwiftUI view, inside the same radius.
        blur.maskImage = Self.roundedMask(radius: Self.cornerRadius)
        let host = NSHostingView(rootView: WindowSwitcherView(switcher: switcher))
        host.frame = blur.bounds
        host.autoresizingMask = [.width, .height]
        blur.addSubview(host)
        contentView = blur

        setFrameOrigin(NSPoint(
            x: window.frame.midX - width / 2, y: window.frame.midY - height / 2))
    }

    /// Fade and scale in, about 120 ms.
    func present() {
        let full = frame
        let small = full.insetBy(dx: full.width * 0.02, dy: full.height * 0.02)
        alphaValue = 0
        setFrame(small, display: false)
        anchor?.addChildWindow(self, ordered: .above)
        orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
            animator().setFrame(full, display: true)
        } completionHandler: { [weak self] in
            self?.invalidateShadow()
        }
        // The shadow is computed from the window shape: redo it once the layout settles.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.invalidateShadow() }
    }

    func dismiss() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.08
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.anchor?.removeChildWindow(self)
            self.orderOut(nil)
        })
    }
}
