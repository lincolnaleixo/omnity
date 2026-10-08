import AppKit
import SwiftUI

/// Omnity: the tmux session tab bar (see SessionTabs.swift).

/// Colors of the bar. It follows the terminal's colors, so a light theme gets a light bar.
struct SessionTabsPalette {
    let theme: AnsiTheme

    var dark: Bool {
        let bg = theme.bg
        return (0.299 * Double(bg.r) + 0.587 * Double(bg.g) + 0.114 * Double(bg.b)) / 255 < 0.5
    }
    func ink(_ opacity: Double = 1) -> Color { (dark ? Color.white : Color.black).opacity(opacity) }
    /// The terminal background, nudged toward the ink so the strip reads as a toolbar above it.
    var strip: Color { theme.bg.mixed(with: dark ? AnsiRGB(255, 255, 255) : AnsiRGB(0, 0, 0), dark ? 0.07 : 0.05).color }
    var hairline: Color { ink(dark ? 0.10 : 0.12) }
    var hover: Color { ink(dark ? 0.08 : 0.07) }
    var active: Color { ink(dark ? 0.15 : 0.10) }
    var activeStroke: Color { ink(dark ? 0.16 : 0.12) }
}

/// Zero height unless this window is attached to tmux.
struct SessionTabsBar: View {
    let config: Ghostty.Config
    let surface: Ghostty.SurfaceView?
    @ObservedObject private var tabs = SessionTabs.shared

    var body: some View {
        // The foreground process of a surface is not observable: look again every two seconds.
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            if tabs.attached(surface), !tabs.tabs.isEmpty {
                SessionTabsStrip(tabs: tabs, palette: SessionTabsPalette(theme: config.switcherTheme), surface: surface)
                    .transition(.opacity)
            }
        }
    }
}

private struct SessionTabsStrip: View {
    @ObservedObject var tabs: SessionTabs
    let palette: SessionTabsPalette
    let surface: Ghostty.SurfaceView?

    var body: some View {
        let current = tabs.currentName
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(tabs.tabs) { tab in
                        SessionTabView(tab: tab, active: tab.name == current, palette: palette, tabs: tabs, surface: surface)
                    }
                }
                .padding(.horizontal, 8)
            }
            if let text = tabs.notice ?? (tabs.failed ? "offline" : nil) {
                Text(text)
                    .font(.system(size: 11))
                    .foregroundColor(tabs.notice != nil ? Color(red: 0xf7 / 255, green: 0x76 / 255, blue: 0x8e / 255) : palette.ink(0.45))
                    .lineLimit(1)
                    .padding(.trailing, 10)
            }
        }
        .frame(height: 32)
        .frame(maxWidth: .infinity)
        .background(palette.strip)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.hairline).frame(height: 0.5) }
        .onAppear { tabs.barAppeared() }
        .onDisappear { tabs.barDisappeared(); SessionHoverCard.shared.hide() }
    }
}

private struct SessionTabView: View {
    let tab: SessionTab
    let active: Bool
    let palette: SessionTabsPalette
    let tabs: SessionTabs
    let surface: Ghostty.SurfaceView?

    @State private var hovered = false
    private let anchor = AnchorBox()
    private let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)

    var body: some View {
        label
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(background)
            .background(TabAnchor(box: anchor))
            .contentShape(shape)
            .onHover { inside in
                hovered = inside
                if inside { SessionHoverCard.shared.show(tab, palette: palette, anchor: anchor, after: 0.35) } else { SessionHoverCard.shared.hide() }
            }
            .onTapGesture {
                SessionHoverCard.shared.hide()
                tabs.select(tab.name, refocus: surface)
            }
            .contextMenu {
                Button("Rename session\u{2026}") { tabs.promptRename(tab.name, in: surface?.window) }
                Button("New window") { tabs.newWindow(in: tab.name, refocus: surface) }
                Divider()
                Button("Close session\u{2026}") { tabs.confirmClose(tab, in: surface?.window) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(tab.name), \(tab.count) windows" + (tab.waiting > 0 ? ", \(tab.waiting) waiting" : ""))
            .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }

    private var label: some View {
        HStack(spacing: 6) {
            if let n = tab.shortcut {
                Text("\(n)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(palette.ink(active ? 0.5 : 0.32))
            }
            Text(tab.name)
                .font(.system(size: 12, weight: active ? .semibold : .medium))
                .foregroundColor(palette.ink(active ? 1 : 0.68))
                .lineLimit(1)
            Text("\(tab.count)")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(palette.ink(0.5))
                .padding(.horizontal, 5)
                .frame(minWidth: 16, minHeight: 14)
                .background(Capsule().fill(palette.ink(palette.dark ? 0.10 : 0.08)))
            dots
            if tab.waiting > 0 { badge }
        }
        .fixedSize()
    }

    /// Busy (green) and background (blue) dots; waiting is the yellow badge.
    @ViewBuilder private var dots: some View {
        if tab.busy > 0 || tab.bg > 0 {
            HStack(spacing: 3) {
                if tab.busy > 0 { dot("busy") }
                if tab.bg > 0 { dot("bg") }
            }
        }
    }

    private func dot(_ state: String) -> some View {
        Circle().fill(SwitcherColors.state(state)).frame(width: 6, height: 6)
    }

    private var badge: some View {
        let yellow = SwitcherColors.state("waiting")
        return Text("\(tab.waiting)")
            .font(.system(size: 10.5, weight: .bold))
            .foregroundColor(Color(red: 0x1a / 255, green: 0x1b / 255, blue: 0x26 / 255))
            .padding(.horizontal, 6)
            .frame(minWidth: 18, minHeight: 15)
            .background(Capsule().fill(yellow))
            .shadow(color: yellow.opacity(0.65), radius: 4)
    }

    @ViewBuilder private var background: some View {
        if active {
            activeBackground
        } else {
            shape.fill(hovered ? palette.hover : Color.clear)
        }
    }

    /// Liquid Glass where the system has it, a translucent fill like the option+tab selection elsewhere.
    @ViewBuilder private var activeBackground: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: shape)
                .overlay(shape.fill(palette.active))
                .overlay(shape.strokeBorder(palette.activeStroke, lineWidth: 0.5))
        } else {
            plainActive
        }
        #else
        plainActive
        #endif
    }

    private var plainActive: some View {
        shape.fill(palette.active).overlay(shape.strokeBorder(palette.activeStroke, lineWidth: 0.5))
    }
}

// MARK: - Hover card

/// The AppKit view behind a tab, to place the hover card under it.
final class AnchorBox {
    weak var view: NSView?
}

private final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct TabAnchor: NSViewRepresentable {
    let box: AnchorBox
    func makeNSView(context: Context) -> NSView {
        let v = PassthroughView()
        box.view = v
        return v
    }
    func updateNSView(_ view: NSView, context: Context) { box.view = view }
}

/// The windows of a session under its tab, after a short hover. A panel of its own (like the
/// option+tab one, never key, ignores the mouse), because a popover would take focus from the terminal.
final class SessionHoverCard {
    static let shared = SessionHoverCard()

    private var panel: NSPanel?
    private var work: DispatchWorkItem?
    private var shown: String?

    init() {
        NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.hide() }
    }

    func show(_ tab: SessionTab, palette: SessionTabsPalette, anchor: AnchorBox, after delay: TimeInterval) {
        work?.cancel()
        let item = DispatchWorkItem { [weak self, weak anchor] in
            guard let self, let view = anchor?.view, let window = view.window else { return }
            self.present(tab, palette: palette, from: view, in: window)
        }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func hide() {
        work?.cancel()
        shown = nil
        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.08
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        })
    }

    private func present(_ tab: SessionTab, palette: SessionTabsPalette, from view: NSView, in window: NSWindow) {
        guard shown != tab.name else { return }
        hide()
        let host = NSHostingView(rootView: SessionHoverCardView(tab: tab, palette: palette))
        let size = host.fittingSize
        let radius: CGFloat = 12
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: palette.dark ? .darkAqua : .aqua)
        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        blur.material = palette.dark ? .hudWindow : .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.maskImage = SwitcherPanel.roundedMask(radius: radius)
        host.frame = blur.bounds
        host.autoresizingMask = [.width, .height]
        blur.addSubview(host)
        panel.contentView = blur

        // Under the tab, 6 pt below it, kept inside the window.
        let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
        var x = rect.minX
        x = min(x, window.frame.maxX - size.width - 8)
        x = max(x, window.frame.minX + 8)
        panel.setFrameOrigin(NSPoint(x: x, y: rect.minY - 6 - size.height))
        panel.alphaValue = 0
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            panel.animator().alphaValue = 1
        }, completionHandler: { panel.invalidateShadow() })
        self.panel = panel
        shown = tab.name
    }
}

private struct SessionHoverCardView: View {
    let tab: SessionTab
    let palette: SessionTabsPalette
    private static let maxRows = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(tab.name) \u{00B7} \(tab.count == 1 ? "1 window" : "\(tab.count) windows")")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(palette.ink(0.5))
                .padding(.bottom, 4)
            ForEach(tab.windows.prefix(Self.maxRows)) { window in
                HStack(spacing: 8) {
                    Circle()
                        .fill(window.state == nil || window.state == "idle" ? palette.ink(0.35) : SwitcherColors.state(window.state))
                        .frame(width: 8, height: 8)
                        .shadow(color: window.state == "waiting" ? SwitcherColors.state("waiting").opacity(0.7) : .clear, radius: 3)
                    Text(window.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(palette.ink())
                        .lineLimit(1)
                        .fixedSize()
                    if let title = window.title, !title.isEmpty, title != window.name {
                        Text(title)
                            .font(.system(size: 12))
                            .foregroundColor(palette.ink(0.55))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .frame(height: 22)
            }
            if tab.windows.count > Self.maxRows {
                Text("+\(tab.windows.count - Self.maxRows) more")
                    .font(.system(size: 11))
                    .foregroundColor(palette.ink(0.45))
            }
        }
        .padding(12)
        .frame(minWidth: 180, maxWidth: 420, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .circular)
                .strokeBorder(palette.ink(0.12), lineWidth: 1)
                .allowsHitTesting(false))
    }
}
