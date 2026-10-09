import AppKit
import SwiftUI

/// Omnity: building blocks shared by the four panel styles (colors and sizes of the approved prototype).

private struct SBMonoKey: EnvironmentKey { static let defaultValue: Font? = nil }
extension EnvironmentValues {
    /// The terminal's font, set by the command style so every row draws in monospace.
    var sbMono: Font? { get { self[SBMonoKey.self] } set { self[SBMonoKey.self] = newValue } }
}

enum SB {
    /// Prototype pixels -> points.
    static let k: CGFloat = 0.76
    static func u(_ v: CGFloat) -> CGFloat { v * k }
    static func fs(_ v: CGFloat) -> CGFloat { max(10, (v * k).rounded(.toNearestOrAwayFromZero)) }

    static func hex(_ v: UInt32, _ a: Double = 1) -> Color {
        Color(.sRGB, red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255, opacity: a)
    }
    static let t1 = hex(0xcdd6f4), t2 = hex(0xa6adc8), t3 = hex(0x7f849c), t4 = hex(0x585b70)
    static let hair = t1.opacity(0.09), stroke = t1.opacity(0.13)
    static let wait = hex(0xe0af68), busy = hex(0x9ece6a), bgd = hex(0x7aa2f7), stale = hex(0xbb9af7)
    static let red = hex(0xf7768e), acc = hex(0x7aa2f7), green = hex(0xa6e3a1), ink = hex(0x11111b)
    static let glassTint = hex(0x202132, 0.56)

    static func stateColor(_ s: String) -> Color {
        switch s { case "waiting": return wait; case "busy": return busy; case "bg": return bgd; default: return stale }
    }
    static func unitColor(_ unit: String) -> Color {
        hex(UInt32(SidebarLogic.unitColorHex(unit), radix: 16) ?? 0xa6adc8)
    }
    static func color(hex s: String?) -> Color {
        guard var h = s?.trimmingCharacters(in: CharacterSet(charactersIn: "#")), h.count == 6 else { return t2 }
        h = h.lowercased()
        return hex(UInt32(h, radix: 16) ?? 0xa6adc8)
    }

    static func serif(_ size: CGFloat, italic: Bool = false) -> Font {
        let f = Font.system(size: size, weight: .regular, design: .serif)
        return italic ? f.italic() : f
    }
}

// MARK: - Glass

struct SBGlass: ViewModifier {
    var radius: CGFloat
    var tint: Color = SB.glassTint

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background { glass(shape) }
            .overlay(shape.strokeBorder(SB.stroke, lineWidth: 0.6))
            .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    }

    @ViewBuilder private func glass(_ shape: RoundedRectangle) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.clear.tint(tint), in: shape)
        } else {
            shape.fill(.ultraThinMaterial).overlay(shape.fill(tint))
        }
        #else
        shape.fill(.ultraThinMaterial).overlay(shape.fill(tint))
        #endif
    }
}

extension View {
    func sbGlass(radius: CGFloat, tint: Color = SB.glassTint) -> some View { modifier(SBGlass(radius: radius, tint: tint)) }
}

// MARK: - Atoms

struct SBTick: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x / 24 * r.width, y: r.minY + y / 24 * r.height) }
        p.move(to: pt(7.2, 12.4)); p.addLine(to: pt(10.4, 15.6)); p.addLine(to: pt(16.8, 8.8))
        return p
    }
}

/// The round check: on completion the ring fills, the check draws and eight particles fly out.
struct SBCheck: View {
    var size: CGFloat
    var done: Bool
    var action: () -> Void
    @State private var hover = false
    @State private var tick: CGFloat = 0
    @State private var burst: CGFloat = 0
    @State private var pop: CGFloat = 1
    private let colors = [SB.green, SB.hex(0xf9e2af), SB.bgd, SB.hex(0xcba6f7)]

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(done ? SB.green : (hover ? SB.t1.opacity(0.08) : .clear))
                Circle().strokeBorder(done ? SB.green : (hover ? SB.t1 : SB.t3), lineWidth: 1.4)
                SBTick().trim(from: 0, to: tick)
                    .stroke(SB.ink, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                ForEach(0..<8, id: \.self) { i in
                    Circle().fill(colors[i % 4]).frame(width: 4, height: 4)
                        .scaleEffect(1 - 0.8 * burst)
                        .offset(x: size * 0.5 + 20 * burst)
                        .rotationEffect(.degrees(Double(i) * 45))
                        .opacity(done ? Double(1 - burst) : 0)
                }
            }
            .frame(width: size, height: size)
            .scaleEffect(pop)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel("Complete")
        .onChange(of: done) { d in
            if d {
                withAnimation(.easeOut(duration: 0.28).delay(0.1)) { tick = 1 }
                withAnimation(.easeOut(duration: 0.6).delay(0.08)) { burst = 1 }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.45)) { pop = 1.22 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { pop = 1 } }
            } else {
                tick = 0; burst = 0; pop = 1
            }
        }
    }
}

struct SBBadge: View {
    var ai: Bool
    var body: some View {
        Text(ai ? "AI" : "YOU")
            .font(.system(size: 9.5, weight: .bold))
            .tracking(0.4)
            .foregroundColor(ai ? SB.stale : SB.bgd)
            .padding(.horizontal, 5).frame(height: 14)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill((ai ? SB.stale : SB.bgd).opacity(0.18)))
    }
}

struct SBDot: View {
    var color: Color
    var size: CGFloat = 8
    var pulse = false
    @State private var on = false
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .background(Circle().stroke(color.opacity(on ? 0 : 0.6), lineWidth: on ? 6 : 0).frame(width: size, height: size))
            .onAppear {
                guard pulse else { return }
                withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) { on = true }
            }
    }
}

struct SBKbd: View {
    var text: String
    var dark = false
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(dark ? SB.ink : SB.t1)
            .padding(.horizontal, 5).frame(minWidth: 16, minHeight: 15)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(dark ? Color.black.opacity(0.18) : SB.t1.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(dark ? Color.black.opacity(0.18) : SB.t1.opacity(0.14), lineWidth: 0.5))
    }
}

struct SBPillButton: View {
    var title: String
    var kbd: String? = nil
    var primary = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: SB.fs(13), weight: primary ? .semibold : .regular))
                if let kbd { SBKbd(text: kbd, dark: primary) }
            }
            .foregroundColor(primary ? SB.ink : SB.t1)
            .padding(.horizontal, 11).frame(height: 24)
            .background(Capsule().fill(primary ? SB.acc : SB.t1.opacity(0.1)))
            .overlay(Capsule().strokeBorder(primary ? .clear : SB.stroke, lineWidth: 0.6))
        }
        .buttonStyle(.plain)
    }
}

struct SBSpark: View {
    var series: [Double]
    var color: Color = SB.acc
    var body: some View {
        GeometryReader { g in
            let mx = series.max() ?? 1, mn = series.min() ?? 0, r = max(mx - mn, 0.0001)
            Path { p in
                for (i, v) in series.enumerated() {
                    let x = series.count < 2 ? 0 : CGFloat(i) / CGFloat(series.count - 1) * g.size.width
                    let y = g.size.height - 2 - CGFloat((v - mn) / r) * (g.size.height - 4)
                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
    }
}

struct SBRing: View {
    var value: Double       // 0...1
    var label: String
    var caption: String
    var size: CGFloat
    var gradient = true
    var body: some View {
        ZStack {
            Circle().stroke(SB.t1.opacity(0.12), lineWidth: size * 0.087)
            Circle().trim(from: 0, to: max(0.001, min(1, value)))
                .stroke(gradient ? AnyShapeStyle(LinearGradient(colors: [SB.bgd, SB.stale], startPoint: .topLeading, endPoint: .bottomTrailing)) : AnyShapeStyle(SB.green),
                        style: StrokeStyle(lineWidth: size * 0.087, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: -1) {
                Text(label).font(.system(size: size * 0.27, weight: .bold)).tracking(-0.4)
                Text(caption).font(.system(size: 10, weight: .medium)).foregroundColor(SB.t3)
            }
        }
        .padding(size * 0.044)
        .frame(width: size, height: size)
    }
}

/// Reports the panel's frame in window coordinates and its window to the store.
struct SBFrameReader: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ v: NSView, context: Context) {}
    private final class Probe: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() {
            super.layout()
            report()
        }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); report() }
        private func report() {
            guard window != nil else { return }
            let r = convert(bounds, to: nil)
            Task { @MainActor in
                SidebarStore.shared.panelFrame = r
                SidebarStore.shared.panelWindow = self.window
            }
        }
    }
}

// MARK: - Task row

struct SBRowSpec {
    var title: CGFloat = 17.5
    var meta: CGFloat = 13.5
    var hist: CGFloat = 13
    var check: CGFloat = 24
    var pad = EdgeInsets(top: 9, leading: 10, bottom: 9, trailing: 10)
    var radius: CGFloat = 12
    var fill = Color.clear
    var hoverFill = Color.clear
    var selFill = SB.acc.opacity(0.13)
    var selStroke: Color?
    var selBar = false
    var inline = false
    var mono: Font?
    var gap: CGFloat = 13
}

struct SBTaskRow: View {
    @ObservedObject var store: SidebarStore
    let task: SBTask
    let spec: SBRowSpec
    var showUnit = false
    var showHist = false
    @State private var hover = false

    var body: some View {
        let open = store.expanded.contains(task.id)
        let doing = store.completing.contains(task.id)
        let sel = store.selection == task.id
        let subs = task.subtasks
        let sd = subs.filter(\.done).count
        let hist = SidebarLogic.history(task.notes)
        let due = SidebarLogic.due(task, today: store.today)
        HStack(alignment: .top, spacing: SB.u(spec.gap)) {
            SBCheck(size: SB.u(spec.check), done: doing) { store.complete(task.id) }
                .padding(.top, spec.inline ? 1 : 0)
            VStack(alignment: .leading, spacing: 3) {
                if spec.inline { inlineHead(due: due, subs: subs, sd: sd, doing: doing) } else { stackedHead(due: due, subs: subs, sd: sd, doing: doing) }
                if showHist && !open, let h = hist.last { histLine(h, lineLimit: 1) }
                if open { details(hist: hist) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(EdgeInsets(top: SB.u(spec.pad.top), leading: SB.u(spec.pad.leading), bottom: SB.u(spec.pad.bottom), trailing: SB.u(spec.pad.trailing)))
        .background(rowBackground(sel: sel))
        .overlay(alignment: .leading) {
            if spec.selBar && sel { Rectangle().fill(SB.acc).frame(width: 2) }
        }
        .clipShape(RoundedRectangle(cornerRadius: SB.u(spec.radius), style: .continuous))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { store.toggleExpanded(task.id) }
        .opacity(doing ? 0.6 : 1)
        .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .trailing).combined(with: .opacity)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(task.title)
    }

    @ViewBuilder private func rowBackground(sel: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: SB.u(spec.radius), style: .continuous)
        ZStack {
            shape.fill(hover ? spec.hoverFill : spec.fill)
            if sel { shape.fill(spec.selFill) }
            if sel, let c = spec.selStroke { shape.strokeBorder(c, lineWidth: 0.8) }
        }
    }

    private func titleView(doing: Bool) -> some View {
        Text(task.title)
            .font(spec.mono ?? .system(size: SB.fs(spec.title), weight: .medium))
            .foregroundColor(doing ? SB.t4 : SB.t1)
            .strikethrough(doing, color: SB.green)
            .lineSpacing(1)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func metaItems(due: SBDue, subs: [SBSub], sd: Int, inline: Bool) -> some View {
        HStack(spacing: SB.u(12)) {
            if showUnit {
                HStack(spacing: 6) {
                    Circle().fill(SB.unitColor(task.unit)).frame(width: 7, height: 7)
                    Text(SidebarLogic.shortName(task.unit)).lineLimit(1)
                }
                .frame(width: inline ? SB.u(58) : nil, alignment: .leading)
            }
            if !due.label.isEmpty || inline {
                Text(due.label).foregroundColor(due.kind == .overdue ? SB.red : (due.kind == .today ? SB.wait : SB.t2)).lineLimit(1)
                    .frame(width: inline ? SB.u(84) : nil, alignment: .leading)
            }
            if !inline, let r = task.repeatRule {
                Text("\u{21BB} \(r.split(separator: ":").first.map(String.init) ?? r)").foregroundColor(SB.t3).lineLimit(1)
            }
            if !inline, !subs.isEmpty {
                HStack(spacing: 6) {
                    Capsule().fill(SB.t1.opacity(0.14)).frame(width: 30, height: 4)
                        .overlay(alignment: .leading) { Capsule().fill(SB.busy).frame(width: 30 * CGFloat(sd) / CGFloat(subs.count), height: 4) }
                    Text("\(sd)/\(subs.count)")
                }
            }
        }
        .font(.system(size: SB.fs(spec.meta)))
        .foregroundColor(SB.t2)
    }

    private func stackedHead(due: SBDue, subs: [SBSub], sd: Int, doing: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            titleView(doing: doing)
            metaItems(due: due, subs: subs, sd: sd, inline: false).opacity(doing ? 0.35 : 1)
        }
    }

    private func inlineHead(due: SBDue, subs: [SBSub], sd: Int, doing: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: SB.u(12)) {
            metaItems(due: due, subs: subs, sd: sd, inline: true).fixedSize()
            titleView(doing: doing).frame(maxWidth: .infinity, alignment: .leading)
            if !subs.isEmpty { Text("\(sd)/\(subs.count)").font(.system(size: SB.fs(12))).foregroundColor(SB.t3) }
        }
        .font(spec.mono)
    }

    private func histLine(_ h: SBHistory, lineLimit: Int?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            SBBadge(ai: h.ai)
            if lineLimit == nil { Text(String(h.date.dropFirst(5))).foregroundColor(SB.t3) }
            Text(h.text).foregroundColor(lineLimit == nil ? SB.t2 : SB.t3).lineLimit(lineLimit)
        }
        .font(spec.mono ?? .system(size: SB.fs(spec.hist)))
        .padding(.leading, spec.inline ? SB.u(154) : 0)
    }

    @ViewBuilder private func details(hist: [SBHistory]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(task.subtasks, id: \.index) { s in
                Button { store.toggleSub(task.id, s.index) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        ZStack {
                            Circle().strokeBorder(s.done ? SB.green : SB.t3, lineWidth: 1.3).background(Circle().fill(s.done ? SB.green : .clear))
                            if s.done { SBTick().stroke(SB.ink, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)).padding(3) }
                        }
                        .frame(width: 15, height: 15).offset(y: 2)
                        Text(s.text).strikethrough(s.done).foregroundColor(s.done ? SB.t3 : SB.t1)
                            .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                    }
                    .font(spec.mono ?? .system(size: SB.fs(spec.meta + 0.5)))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if !hist.isEmpty {
                VStack(alignment: .leading, spacing: 3) { ForEach(Array(hist.enumerated()), id: \.offset) { _, h in histLine(h, lineLimit: nil) } }
                    .padding(.top, task.subtasks.isEmpty ? 0 : 6)
            }
            if store.noteFor == task.id { NoteField(store: store).padding(.top, 4) }
            HStack(spacing: 8) {
                SBPillButton(title: "Open in Tally", kbd: "\u{23CE}", primary: true) { store.openInTally(task.id) }
                SBPillButton(title: "Add note") { store.beginNote(task.id) }
            }
            .padding(.top, 6)
        }
        .padding(.top, 6)
        .padding(.leading, spec.inline ? SB.u(154) : 0)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

struct NoteField: View {
    @ObservedObject var store: SidebarStore
    @FocusState private var focused: Bool
    var body: some View {
        TextField("Add a note\u{2026}", text: $store.noteText)
            .textFieldStyle(.plain)
            .font(.system(size: SB.fs(14)))
            .padding(.horizontal, 10).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SB.t1.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(SB.acc.opacity(0.5), lineWidth: 0.8))
            .focused($focused)
            .onSubmit { store.submitNote() }
            .onExitCommand { store.cancelNote() }
            .onAppear { focused = true }
    }
}

// MARK: - Sections

struct SBSection<Content: View, Extra: View>: View {
    @ObservedObject var store: SidebarStore
    let id: String
    let title: String
    let count: String
    var style: SidebarStyle = .editorial
    var titleColor: Color?
    let extra: Extra
    let content: Content
    @Environment(\.sbMono) private var mono

    init(store: SidebarStore, id: String, title: String, count: String, style: SidebarStyle = .editorial, titleColor: Color? = nil,
         @ViewBuilder extra: () -> Extra, @ViewBuilder content: () -> Content) {
        self.store = store; self.id = id; self.title = title; self.count = count; self.style = style
        self.titleColor = titleColor; self.extra = extra(); self.content = content()
    }

    var body: some View {
        let col = store.collapsed.contains(id)
        VStack(alignment: .leading, spacing: 0) {
            Button { store.toggleSection(id) } label: {
                HStack(spacing: 0) {
                    switch style {
                    case .cards:
                        Text(title).font(.system(size: SB.fs(15), weight: .semibold)).foregroundColor(SB.t1)
                        if !count.isEmpty {
                            Text(count).font(.system(size: SB.fs(12))).foregroundColor(SB.t2)
                                .padding(.horizontal, 8).frame(height: 19)
                                .background(Capsule().fill(SB.t1.opacity(0.12))).padding(.leading, 8)
                        }
                    case .command:
                        Text(title.uppercased()).font(mono ?? .system(size: SB.fs(11.5))).tracking(1.4).foregroundColor(titleColor ?? SB.t3)
                        if !count.isEmpty { Text(count).font(mono ?? .system(size: SB.fs(11.5))).foregroundColor(SB.t4).padding(.leading, 8) }
                    default:
                        Text(title.uppercased()).font(.system(size: SB.fs(11.5), weight: .semibold)).tracking(1.7).foregroundColor(titleColor ?? SB.t3)
                        if !count.isEmpty { Text(count).font(.system(size: SB.fs(12))).foregroundColor(SB.t4).padding(.leading, 10) }
                    }
                    Spacer(minLength: 8)
                    extra
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundColor(SB.t4)
                        .rotationEffect(.degrees(col ? -90 : 0)).padding(.leading, 8)
                }
                .padding(.bottom, style == .cards ? 12 : 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !col {
                content.transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

extension SBSection where Extra == EmptyView {
    init(store: SidebarStore, id: String, title: String, count: String, style: SidebarStyle = .editorial, titleColor: Color? = nil,
         @ViewBuilder content: () -> Content) {
        self.init(store: store, id: id, title: title, count: count, style: style, titleColor: titleColor, extra: { EmptyView() }, content: content)
    }
}

// MARK: - Shared rows

struct SBAgentRow: View {
    @ObservedObject var store: SidebarStore
    let agent: SBAgent
    var style: SidebarStyle
    var key: Int?
    @State private var hover = false
    @Environment(\.sbMono) private var mono

    var body: some View {
        let compact = style == .command
        HStack(spacing: 10) {
            SBDot(color: SB.stateColor(agent.state), size: compact ? 8 : 9, pulse: agent.state == "waiting")
            if let key { Text("\(key)").foregroundColor(SB.t4).frame(width: 14, alignment: .leading) }
            Text(agent.key).fontWeight(.semibold).lineLimit(1).fixedSize()
            Text(agent.query).foregroundColor(SB.t2).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text(agent.age).foregroundColor(SB.t3).lineLimit(1)
        }
        .font(mono ?? .system(size: SB.fs(style == .editorial ? 15 : (style == .cards ? 14.5 : 13))))
        .foregroundColor(SB.t1)
        .padding(.horizontal, style == .editorial ? 0 : SB.u(12))
        .padding(.vertical, SB.u(style == .command ? 6 : (style == .timeline ? 6 : 10)))
        .background {
            let isWait = agent.state == "waiting"
            if style == .cards {
                RoundedRectangle(cornerRadius: SB.u(14), style: .continuous)
                    .fill(isWait ? SB.wait.opacity(0.1) : SB.t1.opacity(0.05))
                    .overlay(RoundedRectangle(cornerRadius: SB.u(14), style: .continuous).strokeBorder(isWait ? SB.wait.opacity(0.22) : SB.t1.opacity(0.07), lineWidth: 0.6))
            } else if style == .command {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isWait ? SB.wait.opacity(hover ? 0.16 : 0.09) : (hover ? SB.t1.opacity(0.07) : .clear))
            }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { store.go(agent) }
        .help("Go to \(agent.key)")
    }
}

struct SBEventRow: View {
    let event: SBEvent
    var style: SidebarStyle
    var past: Bool
    @Environment(\.sbMono) private var mono

    var body: some View {
        let tm = event.allDay ? "All day" : "\(SidebarLogic.eventTime(event.start)) - \(SidebarLogic.eventTime(event.end))"
        let c = SB.color(hex: event.color)
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(tm).monospacedDigit().foregroundColor(style == .cards ? SB.t2 : SB.t3).lineLimit(1).fixedSize()
                .frame(width: SB.u(style == .cards ? 150 : 140), alignment: .leading)
            Text(event.title).lineLimit(1).foregroundColor(SB.t1)
            Spacer(minLength: 4)
            if style != .cards { Circle().fill(c).frame(width: 7, height: 7) }
        }
        .font(mono ?? .system(size: SB.fs(style == .command ? 13 : (style == .cards ? 14.5 : 15))))
        .padding(.vertical, SB.u(style == .command ? 3 : 7))
        .padding(.horizontal, style == .cards ? SB.u(12) : 0)
        .background {
            if style == .cards {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(SB.bgd.opacity(0.1))
                    .overlay(alignment: .leading) { Rectangle().fill(c).frame(width: 3) }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .opacity(past ? 0.45 : 1)
    }
}

struct SBBlueprintRow: View {
    let index: Int
    let item: SBBlueprintNext
    var size: CGFloat
    @Environment(\.sbMono) private var mono
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(index)").foregroundColor(SB.t4).frame(width: 14, alignment: .leading)
            Text(item.text).foregroundColor(SB.t1).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            Text(item.impact.uppercased()).foregroundColor(SB.wait).font(.system(size: 10)).tracking(1).lineLimit(1)
        }
        .font(mono ?? .system(size: SB.fs(size)))
        .padding(.vertical, 4)
    }
}

struct SBStylePicker: View {
    @ObservedObject var store: SidebarStore
    var body: some View {
        HStack(spacing: 1) {
            ForEach(SidebarStyle.allCases, id: \.self) { s in
                Button { store.setStyle(s) } label: {
                    Text(s.letter).font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(store.style == s ? SB.t1 : SB.t3)
                        .frame(width: 20, height: 18)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(store.style == s ? SB.t1.opacity(0.16) : .clear))
                }
                .buttonStyle(.plain)
                .help("\(s.title)  \u{21E7}\u{2318}\(s.number)")
            }
        }
        .padding(2)
        .background(Capsule().fill(SB.t1.opacity(0.07)))
    }
}

struct SBEmpty: View {
    var text = "Nothing here."
    var body: some View { Text(text).font(.system(size: SB.fs(14))).foregroundColor(SB.t3).padding(.vertical, 6) }
}

extension DateFormatter {
    static func sb(_ f: String) -> DateFormatter {
        let d = DateFormatter()
        d.locale = Locale(identifier: "en_US_POSIX")
        d.dateFormat = f
        return d
    }
}
