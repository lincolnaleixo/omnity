import SwiftUI
import AppKit
import GhosttyKit

/// Omnity: colored text for the window switcher preview. A small, self-contained
/// SGR parser (colors, bold, dim, italic, underline, reverse) that turns one line
/// of `tmux capture-pane -e` output into an AttributedString. Everything else
/// (other CSI, OSC, stray control characters) is dropped.

struct AnsiRGB: Equatable {
    var r: UInt8, g: UInt8, b: UInt8

    init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { (self.r, self.g, self.b) = (r, g, b) }
    init(hex: UInt32) { self.init(UInt8(hex >> 16 & 255), UInt8(hex >> 8 & 255), UInt8(hex & 255)) }

    var color: Color { Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255) }

    /// The terminal's `minimum-contrast`: if the WCAG contrast ratio with `bg` is
    /// below `min`, white or black, whichever contrasts more.
    func contrasted(against bg: AnsiRGB, min: Double) -> AnsiRGB {
        func lum(_ c: AnsiRGB) -> Double {
            func lin(_ v: UInt8) -> Double {
                let x = Double(v) / 255
                return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
        }
        func ratio(_ a: AnsiRGB, _ b: AnsiRGB) -> Double {
            (max(lum(a), lum(b)) + 0.05) / (Swift.min(lum(a), lum(b)) + 0.05)
        }
        guard ratio(self, bg) < min else { return self }
        let (white, black) = (AnsiRGB(255, 255, 255), AnsiRGB(0, 0, 0))
        return ratio(white, bg) > ratio(black, bg) ? white : black
    }
    func mixed(with o: AnsiRGB, _ t: Double) -> AnsiRGB {
        func m(_ a: UInt8, _ b: UInt8) -> UInt8 { UInt8((Double(a) * (1 - t) + Double(b) * t).rounded()) }
        return AnsiRGB(m(r, o.r), m(g, o.g), m(b, o.b))
    }
}

/// The terminal's foreground, background and 256-color palette.
struct AnsiTheme: Equatable {
    var fg: AnsiRGB
    var bg: AnsiRGB
    var palette: [AnsiRGB]
    /// `bold-color`: nil = bold keeps its colors, `.bright` = palette 0-7 turn 8-15,
    /// `.color` = bold default text uses that color (and palette 0-7 turn bright too).
    var bold: Bold? = nil
    /// `minimum-contrast` (1 = off) and `faint-opacity`.
    var minContrast = 1.0
    var faintOpacity = 0.5
    enum Bold: Equatable { case bright, color(AnsiRGB) }

    /// Tokyo Night (Lincoln's tmux theme) for the 16 base colors, xterm for the rest.
    static let fallback: AnsiTheme = {
        let base: [UInt32] = [
            0x15161e, 0xf7768e, 0x9ece6a, 0xe0af68, 0x7aa2f7, 0xbb9af7, 0x7dcfff, 0xa9b1d6,
            0x414868, 0xf7768e, 0x9ece6a, 0xe0af68, 0x7aa2f7, 0xbb9af7, 0x7dcfff, 0xc0caf5,
        ]
        var p = base.map { AnsiRGB(hex: $0) }
        let steps: [UInt8] = [0, 95, 135, 175, 215, 255]
        for i in 0..<216 { p.append(AnsiRGB(steps[i / 36], steps[i / 6 % 6], steps[i % 6])) }
        for i in 0..<24 { let v = UInt8(8 + 10 * i); p.append(AnsiRGB(v, v, v)) }
        return AnsiTheme(fg: AnsiRGB(hex: 0xc0caf5), bg: AnsiRGB(hex: 0x1a1b26), palette: p)
    }()
}

extension Ghostty.Config {
    /// Omnity: the terminal's current colors, for the switcher preview.
    var switcherTheme: AnsiTheme {
        guard let config = self.config else { return .fallback }
        var theme = AnsiTheme.fallback
        func color(_ key: String) -> AnsiRGB? {
            var c = ghostty_config_color_s()
            guard ghostty_config_get(config, &c, key, UInt(key.lengthOfBytes(using: .utf8))) else { return nil }
            return AnsiRGB(c.r, c.g, c.b)
        }
        theme.fg = color("foreground") ?? theme.fg
        theme.bg = color("background") ?? theme.bg
        func number(_ key: String) -> Double? {
            var v = 0.0
            return ghostty_config_get(config, &v, key, UInt(key.lengthOfBytes(using: .utf8))) ? v : nil
        }
        theme.minContrast = number("minimum-contrast") ?? theme.minContrast
        theme.faintOpacity = number("faint-opacity") ?? theme.faintOpacity
        var bold = ghostty_config_bold_color_s()
        let boldKey = "bold-color"
        if ghostty_config_get(config, &bold, boldKey, UInt(boldKey.lengthOfBytes(using: .utf8))) {
            theme.bold = bold.kind == 0 ? .bright : .color(AnsiRGB(bold.color.r, bold.color.g, bold.color.b))
        }
        var pal = ghostty_config_palette_s()
        let key = "palette"
        if ghostty_config_get(config, &pal, key, UInt(key.lengthOfBytes(using: .utf8))) {
            theme.palette = withUnsafeBytes(of: &pal.colors) { raw in
                raw.bindMemory(to: ghostty_config_color_s.self).map { AnsiRGB($0.r, $0.g, $0.b) }
            }
        }
        return theme
    }
}

struct AnsiStyle: Equatable {
    var fg: AnsiRGB?
    /// Palette index of `fg` when it came from the palette (for bold-color).
    var fgIndex: Int?
    var bg: AnsiRGB?
    var bold = false, dim = false, italic = false, underline = false, reverse = false
}

struct AnsiRun: Equatable {
    var text: String
    var style: AnsiStyle
}

enum AnsiParser {
    /// Splits one line into runs of equal style. Colors are resolved against `palette`.
    static func parse(_ line: String, palette: [AnsiRGB] = AnsiTheme.fallback.palette) -> [AnsiRun] {
        var runs: [AnsiRun] = []
        var style = AnsiStyle()
        var text = ""
        func flush() {
            if !text.isEmpty { runs.append(AnsiRun(text: text, style: style)); text = "" }
        }
        let s = Array(line.unicodeScalars)
        var i = 0
        while i < s.count {
            let c = s[i]
            i += 1
            if c == "\u{1B}" {
                guard i < s.count else { break }
                let kind = s[i]
                i += 1
                if kind == "[" {
                    var params = ""
                    while i < s.count, (0x20...0x3F).contains(s[i].value) { params.unicodeScalars.append(s[i]); i += 1 }
                    guard i < s.count else { break }
                    let final = s[i]
                    i += 1
                    if final == "m" {
                        flush()
                        applySGR(params, to: &style, palette: palette)
                    }
                } else if kind == "]" {
                    // OSC: up to BEL or ESC \
                    while i < s.count, s[i] != "\u{07}", s[i] != "\u{1B}" { i += 1 }
                    if i < s.count { i += s[i] == "\u{1B}" ? 2 : 1 }
                }
            } else if c == "\t" {
                text += "    "
            } else if c.value >= 0x20 && c.value != 0x7F {
                text.unicodeScalars.append(c)
            }
        }
        flush()
        return runs
    }

    private static func applySGR(_ params: String, to st: inout AnsiStyle, palette: [AnsiRGB]) {
        func pal(_ n: Int) -> AnsiRGB? { palette.indices.contains(n) ? palette[n] : nil }
        func rgb(_ v: [Int]) -> AnsiRGB? {
            guard v.count == 3, v.allSatisfy({ (0...255).contains($0) }) else { return nil }
            return AnsiRGB(UInt8(v[0]), UInt8(v[1]), UInt8(v[2]))
        }
        /// 5;n or 2;r;g;b from `a` (after the 38/48); returns the color, its palette
        /// index (5;n only) and how many values it used.
        func extended(_ a: ArraySlice<Int>) -> (AnsiRGB?, Int?, Int) {
            switch a.first {
            case 5: return (a.count >= 2 ? pal(a[a.startIndex + 1]) : nil, a.count >= 2 ? a[a.startIndex + 1] : nil, 2)
            case 2: return (a.count >= 4 ? rgb(Array(a.dropFirst().prefix(3))) : nil, nil, 4)
            default: return (nil, nil, a.count)
            }
        }
        let parts = params.isEmpty ? ["0"] : params.components(separatedBy: ";")
        var i = 0
        while i < parts.count {
            let part = parts[i]
            i += 1
            if part.contains(":") {
                // 4:3 (curly underline), 38:5:n, 38:2::r:g:b, 58:...
                let sub = part.components(separatedBy: ":").map { Int($0) }
                switch sub[0] {
                case 4?: st.underline = sub.count < 2 || sub[1] != 0
                case 38?, 48?:
                    // Empty fields (38:2::r:g:b) drop out; a numeric color space id is removed.
                    var v = sub.dropFirst().compactMap { $0 }
                    if v.first == 2, v.count == 5 { v.remove(at: 1) }
                    let (c, index, _) = extended(v[...])
                    if let c { if sub[0] == 38 { st.fg = c; st.fgIndex = index } else { st.bg = c } }
                default: break
                }
                continue
            }
            guard let n = Int(part.isEmpty ? "0" : part) else { continue }
            switch n {
            case 0: st = AnsiStyle()
            case 1: st.bold = true
            case 2: st.dim = true
            case 3: st.italic = true
            case 4: st.underline = true
            case 7: st.reverse = true
            case 22: st.bold = false; st.dim = false
            case 23: st.italic = false
            case 24: st.underline = false
            case 27: st.reverse = false
            case 30...37: st.fg = pal(n - 30); st.fgIndex = n - 30
            case 39: st.fg = nil; st.fgIndex = nil
            case 40...47: st.bg = pal(n - 40)
            case 49: st.bg = nil
            case 90...97: st.fg = pal(n - 90 + 8); st.fgIndex = n - 90 + 8
            case 100...107: st.bg = pal(n - 100 + 8)
            case 38, 48, 58:
                let rest = parts[i...].map { Int($0) ?? 0 }
                let (c, index, used) = extended(rest[...])
                i += min(used, rest.count)
                if let c { if n == 38 { st.fg = c; st.fgIndex = index } else if n == 48 { st.bg = c } }
            default: break
            }
        }
    }
}

enum AnsiText {
    /// Colors of a run the way the terminal paints them: bold-color, reverse,
    /// faint-opacity, then minimum-contrast against the cell background.
    static func colors(_ st: AnsiStyle, theme: AnsiTheme, graphics: Bool = false) -> (fg: AnsiRGB, bg: AnsiRGB?) {
        var fg = st.fg ?? theme.fg
        if st.bold, let bold = theme.bold {
            if let i = st.fgIndex, i < 8 {
                fg = theme.palette[i + 8]
            } else if st.fgIndex == nil, st.fg == nil || st.fg == theme.fg, case .color(let c) = bold {
                fg = c
            }
        }
        var bg = st.bg
        if st.reverse { (fg, bg) = (bg ?? theme.bg, fg) }
        // Like the terminal: contrast first (not for box, block and Powerline glyphs), faint is alpha on top.
        if theme.minContrast > 1, !graphics { fg = fg.contrasted(against: bg ?? theme.bg, min: theme.minContrast) }
        if st.dim { fg = fg.mixed(with: bg ?? theme.bg, 1 - theme.faintOpacity) }
        return (fg, bg)
    }

    /// Terminal graphics (box drawing, blocks, legacy computing, Powerline): no minimum-contrast.
    static func isGraphics(_ c: Unicode.Scalar) -> Bool {
        switch c.value {
        case 0x2500...0x259F, 0x1FB00...0x1FBFF, 0x1CC00...0x1CEBF, 0xE0B0...0xE0D7: return true
        default: return false
        }
    }

    /// `text` split into runs of graphics and non-graphics characters.
    static func segments(_ text: String) -> [(String, Bool)] {
        var out: [(String, Bool)] = []
        for c in text.unicodeScalars {
            let g = isGraphics(c)
            if let last = out.last, last.1 == g { out[out.count - 1].0.unicodeScalars.append(c) } else { out.append((String(c), g)) }
        }
        return out
    }

    static func attributed(_ line: String, theme: AnsiTheme, fonts: SwitcherFonts) -> AttributedString {
        var out = AttributedString()
        for run in AnsiParser.parse(line, palette: theme.palette) {
            let st = run.style
            for (text, graphics) in segments(run.text) {
                var s = AttributedString(text)
                let (fg, bg) = colors(st, theme: theme, graphics: graphics)
                s.foregroundColor = fg.color
                if let bg { s.backgroundColor = bg.color }
                if st.underline { s.underlineStyle = .single }
                s.font = Font(fonts.font(bold: st.bold, italic: st.italic) as CTFont)
                if fonts.kern != 0 { s.kern = fonts.kern }
                out += s
            }
        }
        return out.characters.isEmpty ? AttributedString(" ") : out
    }
}
