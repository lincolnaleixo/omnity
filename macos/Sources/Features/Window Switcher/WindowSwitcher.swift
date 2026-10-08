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

    /// Plain text for the preview: no escape sequences, no trailing blanks.
    static func clean(_ text: String) -> String {
        let stripped = text.replacingOccurrences(
            of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        var lines = stripped.replacingOccurrences(of: "\t", with: "    ")
            .components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}

// MARK: - ssh

enum TmuxSwitchClient {
    static var command: String {
        ProcessInfo.processInfo.environment["OMNITY_SWITCH_COMMAND"] ?? "/home/robot/.local/bin/tmux-switch"
    }

    static func isWindowID(_ s: String) -> Bool {
        s.range(of: #"^@[0-9]+$"#, options: .regularExpression) != nil
    }

    /// Runs `tmux-switch <args>` on `host`; nil on any failure. One ssh
    /// connection is kept open for ten minutes (ControlPersist).
    static func run(host: String, _ args: [String]) async -> Data? {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            p.arguments = [
                "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=3", "-o", "LogLevel=ERROR",
                "-o", "ControlMaster=auto", "-o", "ControlPath=~/.ssh/omnity-switch-%C",
                "-o", "ControlPersist=10m", host, ([command] + args).joined(separator: " "),
            ]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { cont.resume(returning: nil); return }
            DispatchQueue.global(qos: .userInitiated).async {
                // A hung connection must not pile up processes.
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: killer)
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                killer.cancel()
                cont.resume(returning: p.terminationStatus == 0 ? data : nil)
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
            if visible && !mods.contains(.option) { commit() }
            return event
        case .keyUp:
            // The release of a tab we swallowed.
            return event.keyCode == Self.tab && (visible || mods.contains(.option)) ? nil : event
        default:
            break
        }
        if !visible {
            guard event.keyCode == Self.tab,
                  mods == .option || mods == [.option, .shift],
                  !host.isEmpty,
                  NSApp.keyWindow?.firstResponder is Ghostty.SurfaceView else { return event }
            open(backwards: mods.contains(.shift))
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
        self.backwards = backwards
        failed = false
        selection = initialSelection()
        let panel = SwitcherPanel(over: window, switcher: self)
        self.panel = panel
        visible = true
        panel.present()
        loadPreview()
        refresh()
        // Option may be up already (a very quick tap); never get stuck open.
        heldTimer?.invalidate()
        let held = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            if self?.visible == true && !NSEvent.modifierFlags.contains(.option) { self?.commit() }
        }
        RunLoop.main.add(held, forMode: .common)
        heldTimer = held
    }

    private func close() {
        guard visible else { return }
        visible = false
        previewWork?.cancel()
        panel?.dismiss()
        panel = nil
        heldTimer?.invalidate()
        heldTimer = nil
    }

    func cancel() { close() }

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

    func refresh() {
        let host = self.host
        guard !host.isEmpty, !refreshing else { return }
        refreshing = true
        Task {
            let data = await TmuxSwitchClient.run(host: host, ["--json"])
            let snapshot = data.flatMap { try? JSONDecoder().decode(TmuxSnapshot.self, from: $0) }
            await MainActor.run {
                self.refreshing = false
                self.lastRefresh = Date()
                guard let snapshot else {
                    self.failed = true
                    return
                }
                self.failed = false
                self.loaded = true
                // Once the user starts moving, the list stays as it is.
                guard !self.visible || !self.userMoved else { return }
                self.sessions = snapshot.sessions
                self.current = snapshot.current?.window
                if self.visible {
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
                let data = await TmuxSwitchClient.run(host: host, ["--preview", id, "30"])
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
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 18
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true
        blur.layer?.borderWidth = 0.5
        blur.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
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
