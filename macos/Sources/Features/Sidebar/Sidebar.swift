import AppKit
import Combine
import SwiftUI

/// Omnity: the right-side panel for windows attached to tmux on the switcher host. It narrows the
/// terminal (it is part of the window's layout, not an overlay), shows Today across units or the unit
/// of the current tmux window, and comes in four looks (see SidebarStyles.swift). Keys: cmd+shift+T
/// shows/hides it, cmd+shift+1...4 picks the look (remembered); after a click in the panel j/k move,
/// x completes, space expands, return opens Tally, u undoes, n adds a note, option+1...9 jumps to an
/// agent's window. Data and actions are in SidebarStore.swift.

/// Wraps the terminal view and adds the panel to its right.
struct SidebarContainer<Content: View>: View {
    let config: Ghostty.Config
    let surface: Ghostty.SurfaceView?
    @ViewBuilder var content: Content
    @ObservedObject private var store = SidebarStore.shared
    @State private var attached = false
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var show: Bool { store.enabled && store.shown && attached }

    var body: some View {
        HStack(spacing: 0) {
            content
            if show {
                SidebarPanel(store: store, config: config)
                    .padding(SB.u(16))
                    .background(SidebarBackdrop(color: config.switcherTheme.bg.color))
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .onAppear {
            store.lastSurface = surface
            store.applyConfig(config.macosSidebarStyle)
            attached = store.visible(for: surface)
        }
        .onChange(of: surface) { store.lastSurface = $0 }
        .onReceive(tick) { _ in
            let now = store.visible(for: surface)
            if now != attached { withAnimation(.smooth(duration: 0.35)) { attached = now } }
        }
        .onChange(of: store.shown) { _ in withAnimation(.smooth(duration: 0.35)) { attached = store.visible(for: surface) } }
    }
}

/// The window color behind the panel, with the soft color blooms of the prototype (glass needs something to bend).
private struct SidebarBackdrop: View {
    let color: Color
    var body: some View {
        ZStack {
            color
            RadialGradient(colors: [SB.acc.opacity(0.20), .clear], center: .init(x: 0.7, y: 0.12), startRadius: 0, endRadius: 360)
            RadialGradient(colors: [SB.stale.opacity(0.17), .clear], center: .init(x: 0.8, y: 0.85), startRadius: 0, endRadius: 320)
            RadialGradient(colors: [SB.hex(0x94e2d5, 0.07), .clear], center: .init(x: 0.3, y: 0.55), startRadius: 0, endRadius: 260)
        }
    }
}

struct SidebarPanel: View {
    @ObservedObject var store: SidebarStore
    let config: Ghostty.Config
    @State private var fonts = SwitcherFonts.system(size: 13)

    var body: some View {
        let style = store.style
        ZStack(alignment: .bottom) {
            styleView(style)
                .mask(fade)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(spacing: 6) {
                if store.offline {
                    Text("Offline \u{00B7} showing the last data").font(.system(size: 10.5)).foregroundColor(SB.t3)
                        .padding(.horizontal, 10).padding(.vertical, 3).background(Capsule().fill(.black.opacity(0.25)))
                }
                if let t = store.toast { SidebarToast(store: store, toast: t).transition(.move(edge: .bottom).combined(with: .opacity)) }
            }
            .padding(.bottom, SB.u(14))
        }
        .frame(width: CGFloat(style.width))
        .modifier(PanelShell(glass: style != .cards))
        .background(SBFrameReader())
        .onAppear {
            store.panelAppeared()
            fonts = SwitcherFonts.resolve(config.omnityFont, backingScale: NSScreen.main?.backingScaleFactor ?? 2)
        }
        .onDisappear { store.panelDisappeared() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sidebar")
    }

    @ViewBuilder private func styleView(_ s: SidebarStyle) -> some View {
        switch s {
        case .editorial: EditorialView(store: store)
        case .cards: CardsView(store: store)
        case .timeline: DayTimelineView(store: store)
        case .command: CommandView(store: store, font: fonts)
        }
    }

    private var fade: some View {
        VStack(spacing: 0) {
            Rectangle().fill(.black)
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 22)
        }
    }
}

private struct PanelShell: ViewModifier {
    var glass: Bool
    func body(content: Content) -> some View {
        if glass {
            content.clipShape(RoundedRectangle(cornerRadius: SB.u(26), style: .continuous)).sbGlass(radius: SB.u(26))
        } else {
            content
        }
    }
}

struct SidebarToast: View {
    @ObservedObject var store: SidebarStore
    let toast: SBToast
    var body: some View {
        HStack(spacing: 12) {
            Text(toast.text).font(.system(size: SB.fs(14))).lineLimit(1)
            if toast.undo { SBPillButton(title: "Undo", kbd: "U") { store.undo() } }
        }
        .padding(.leading, 16).padding(.trailing, toast.undo ? 8 : 16).padding(.vertical, 8)
        .foregroundColor(SB.t1)
        .sbGlass(radius: 22, tint: SB.hex(0x202132, 0.8))
    }
}
