import SwiftUI

/// Omnity: the option+tab panel. List of tmux windows grouped by session on
/// the left, last lines of the selected one on the right (below when narrow).
struct WindowSwitcherView: View {
    @ObservedObject var switcher: WindowSwitcher

    private static let narrow: CGFloat = 640

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= Self.narrow
            VStack(spacing: 0) {
                Group {
                    if wide {
                        HStack(spacing: 14) {
                            SwitcherList(switcher: switcher).frame(width: 330)
                            SwitcherPreview(switcher: switcher)
                        }
                    } else {
                        VStack(spacing: 12) {
                            SwitcherList(switcher: switcher).frame(maxHeight: .infinity)
                            SwitcherPreview(switcher: switcher).frame(height: geo.size.height * 0.38)
                        }
                    }
                }
                .padding(14)
                Text("\u{2325}\u{21E5} next    \u{21E7}\u{2325}\u{21E5} back    esc cancel")
                    .font(.system(size: 10.5))
                    .foregroundColor(.white.opacity(0.35))
                    .padding(.bottom, 9)
            }
        }
    }
}

enum SwitcherColors {
    static func state(_ state: String?) -> Color {
        switch state {
        case "waiting": return Color(red: 0xe0 / 255, green: 0xaf / 255, blue: 0x68 / 255)
        case "busy": return Color(red: 0x9e / 255, green: 0xce / 255, blue: 0x6a / 255)
        case "bg": return Color(red: 0x7a / 255, green: 0xa2 / 255, blue: 0xf7 / 255)
        case "stale": return Color(red: 0xbb / 255, green: 0x9a / 255, blue: 0xf7 / 255)
        default: return Color(white: 0.5)
        }
    }
}

private struct SwitcherList: View {
    @ObservedObject var switcher: WindowSwitcher

    var body: some View {
        if switcher.sessions.isEmpty {
            VStack(spacing: 6) {
                if switcher.failed {
                    Text("Can\u{2019}t reach the host").font(.system(size: 13, weight: .semibold))
                    Text("Check ssh and tmux-switch").font(.system(size: 11.5)).foregroundColor(.secondary)
                } else {
                    Text(switcher.loaded ? "No tmux windows" : "Loading\u{2026}")
                        .font(.system(size: 13)).foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(switcher.sessions, id: \.name) { session in
                            Text(WindowSwitcherModel.header(session))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.white.opacity(0.45))
                                .padding(.leading, 10).padding(.top, 10).padding(.bottom, 3)
                            ForEach(session.windows) { window in
                                SwitcherRow(
                                    window: window,
                                    selected: window.id == switcher.selection,
                                    here: window.id == switcher.current)
                                    .id(window.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture { switcher.choose(window.id) }
                            }
                        }
                    }
                }
                .clipped()
                .onAppear { reveal(proxy, animated: false) }
                .onChange(of: switcher.selection) { _ in reveal(proxy, animated: true) }
            }
        }
    }
}

extension SwitcherList {
    /// Scrolls the selected row into view (centered when it was off screen).
    fileprivate func reveal(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let id = switcher.selection else { return }
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(id) }
            } else {
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }
}

private struct SwitcherRow: View {
    let window: TmuxWindow
    let selected: Bool
    let here: Bool

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(SwitcherColors.state(window.state))
                .frame(width: 9, height: 9)
                .shadow(color: window.state == "waiting"
                    ? SwitcherColors.state("waiting").opacity(0.7) : .clear, radius: 3)
            Text(window.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
                .fixedSize()
            if let title = window.title, !title.isEmpty, title != window.name {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if here {
                Text("here").font(.system(size: 10)).foregroundColor(.white.opacity(0.35))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Color.white.opacity(0.16) : Color.clear))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(selected ? Color.white.opacity(0.14) : Color.clear, lineWidth: 0.5))
    }
}

private struct SwitcherPreview: View {
    @ObservedObject var switcher: WindowSwitcher

    private var entry: SwitcherEntry? {
        switcher.entries.first { $0.id == switcher.selection }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let entry {
                HStack(spacing: 6) {
                    Text(entry.window.name).font(.system(size: 12, weight: .semibold))
                    Text("\(entry.session) \u{00B7} \(entry.window.state ?? "idle")")
                        .font(.system(size: 11)).foregroundColor(.white.opacity(0.45))
                }
            }
            // Only the last lines that fit, so nothing overflows the box.
            GeometryReader { geo in
                let all = (switcher.preview ?? "").components(separatedBy: "\n")
                let fit = max(1, Int((geo.size.height - 20) / switcher.fonts.lineHeight))
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(all.suffix(fit).enumerated()), id: \.offset) { _, line in
                        Text(AnsiText.attributed(line, theme: switcher.theme, fonts: switcher.fonts))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(height: switcher.fonts.lineHeight, alignment: .leading)
                    }
                }
                .padding(10)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .bottomLeading)
            }
            .background(switcher.theme.bg.color.opacity(0.9))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
