import SwiftUI
/// Omnity: "move window to another session" in the option+tab switcher.
/// M (with option held, with or without cmd) opens a small picker over the
/// panel; a right click on a row opens the same choice as a context menu.
/// The move itself is `tmux-switch --move @id session` on the host.

// MARK: - Model
struct MoveRow: Equatable, Identifiable {
    enum Kind: Equatable { case existing, create }
    var name: String
    var kind: Kind
    var id: String { (kind == .create ? "+" : "=") + name }
}
struct MovePicker: Equatable {
    var windowID: String
    var windowName: String
    var from: String
    var query = ""
    var highlight = 0
    var busy = false
    var error: String?
}
struct SwitcherNotice: Equatable {
    var text: String
    var isError: Bool
}
/// One row of the switcher list: a session header or a window.
struct SwitcherItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case header(TmuxSession)
        case window(TmuxWindow)
    }
    var kind: Kind
    var id: String {
        switch kind {
        case .header(let s): return "h:" + s.name
        case .window(let w): return w.id
        }
    }
}
extension WindowSwitcherModel {
    static func items(_ sessions: [TmuxSession]) -> [SwitcherItem] {
        sessions.flatMap { s in
            [SwitcherItem(kind: .header(s))] + s.windows.map { SwitcherItem(kind: .window($0)) }
        }
    }
}
enum MoveModel {
    static let maxName = 30
    /// What `tmux-switch --move` accepts: [A-Za-z0-9_-]{1,30}.
    static func isValidName(_ s: String) -> Bool {
        s.range(of: #"^[A-Za-z0-9_-]{1,30}$"#, options: .regularExpression) != nil
    }
    static func isAllowedCharacter(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || c == "-" || c == "_")
    }
    /// Arguments for `tmux-switch`, nil when the window id or the session name is not safe to send.
    static func command(window: String, session: String) -> [String]? {
        guard TmuxSwitchClient.isWindowID(window), isValidName(session) else { return nil }
        return ["--move", window, session]
    }
    /// Output of `tmux-switch --sessions`: one name per line, valid names only, no duplicates.
    static func parseSessions(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { isValidName($0) && $0 != "_stash" && seen.insert($0).inserted }
    }
    /// Picker rows: existing sessions other than the window's own that match the typed
    /// text (exact, then prefix, then contains), then "create" when the text is a new valid name.
    static func rows(sessions: [String], from: String, query: String) -> [MoveRow] {
        let q = query.lowercased()
        let others = sessions.filter { $0 != from }
        func rank(_ s: String) -> Int? {
            let l = s.lowercased()
            if q.isEmpty { return 0 }
            if l == q { return 0 }
            if l.hasPrefix(q) { return 1 }
            return l.contains(q) ? 2 : nil
        }
        var rows = others.enumerated().compactMap { i, s in rank(s).map { (rank: $0, i: i, s: s) } }
            .sorted { ($0.rank, $0.i) < ($1.rank, $1.i) }
            .map { MoveRow(name: $0.s, kind: .existing) }
        if isValidName(query), !sessions.contains(query), query != from {
            rows.append(MoveRow(name: query, kind: .create))
        }
        return rows
    }
    static func confirmation(window: String, to session: String) -> String {
        "Moved \(window) \u{2192} \(session)"
    }
    /// The message of a failed move, as the command printed it.
    static func errorText(_ stderr: String?) -> String {
        let text = (stderr ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Move failed" : String(text.prefix(200))
    }
}

// MARK: - Picker view
struct MovePickerView: View {
    @ObservedObject var switcher: WindowSwitcher
    let picker: MovePicker
    private static let rowHeight: CGFloat = 30
    private static let maxRows = 6
    private let red = Color(red: 0xf7 / 255, green: 0x76 / 255, blue: 0x8e / 255)

    var body: some View {
        let rows = switcher.pickerRows
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Text("Move").foregroundColor(.white.opacity(0.5))
                Text(picker.windowName).fontWeight(.semibold).foregroundColor(.white).lineLimit(1)
                Text("to\u{2026}").foregroundColor(.white.opacity(0.5))
            }
            .font(.system(size: 13))
            field
            if rows.isEmpty {
                Text(picker.query.isEmpty ? "No other sessions. Type a name to create one." : "Letters, digits, - and _ (30 max)")
                    .font(.system(size: 11.5)).foregroundColor(.white.opacity(0.45))
                    .padding(.horizontal, 4).frame(height: Self.rowHeight, alignment: .leading)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 2) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                                rowView(row, selected: i == picker.highlight).id(row.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture { switcher.pickerChoose(row) }
                            }
                        }
                    }
                    .frame(height: CGFloat(min(rows.count, Self.maxRows)) * (Self.rowHeight + 2) - 2)
                    .onChange(of: picker.highlight) { i in
                        if rows.indices.contains(i) { withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(rows[i].id) } }
                    }
                }
            }
            if picker.busy {
                Text("Moving\u{2026}").font(.system(size: 11.5)).foregroundColor(.white.opacity(0.55))
            } else if let error = picker.error {
                Text(error).font(.system(size: 11.5)).foregroundColor(red)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            Text("\u{2191}\u{2193} choose    \u{21A9} move    esc back")
                .font(.system(size: 10.5)).foregroundColor(.white.opacity(0.35))
        }
        .padding(14)
        .frame(width: 320)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.55)))
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.16), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.4), radius: 18, y: 6)
    }

    /// A text field drawn by hand: the panel never becomes key, so the keys come from the monitor.
    private var field: some View {
        HStack(spacing: 0) {
            Text(picker.query).font(.system(size: 13)).foregroundColor(.white).lineLimit(1)
            Rectangle().fill(Color.accentColor).frame(width: 1.5, height: 15)
            if picker.query.isEmpty {
                Text("  Search or type a new name").font(.system(size: 13)).foregroundColor(.white.opacity(0.35))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(Color.accentColor.opacity(0.7), lineWidth: 1))
    }

    private func rowView(_ row: MoveRow, selected: Bool) -> some View {
        HStack(spacing: 8) {
            switch row.kind {
            case .existing:
                Text(row.name).font(.system(size: 13, weight: .medium)).foregroundColor(.white).lineLimit(1)
                Spacer(minLength: 0)
                if let n = switcher.windowCount(session: row.name) {
                    Text(n == 1 ? "1 window" : "\(n) windows")
                        .font(.system(size: 10.5)).foregroundColor(.white.opacity(0.4))
                }
            case .create:
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundColor(.white.opacity(0.6))
                Text("New session \u{201C}\(row.name)\u{201D}")
                    .font(.system(size: 13)).foregroundColor(.white).lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Self.rowHeight)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(selected ? Color.white.opacity(0.16) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(selected ? Color.white.opacity(0.14) : Color.clear, lineWidth: 0.5))
    }
}
