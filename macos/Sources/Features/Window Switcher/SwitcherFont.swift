import AppKit
import CoreText
import GhosttyKit

/// Omnity: the terminal's effective font settings (read from the config through
/// `ghostty_config_get`, defaults included) and the fonts the window switcher
/// preview draws with, resolved from them.
struct SwitcherFontConfig: Equatable {
    enum FaceStyle: Equatable { case standard, disabled, named(String) }
    struct Face: Equatable {
        var families: [String] = []
        var style = FaceStyle.standard
    }
    /// `adjust-cell-*`: a size factor (1.2 = +20%) or, when `absolute`, pixels.
    struct Modifier: Equatable {
        var absolute: Bool
        var value: Double
    }
    var regular = Face(), bold = Face(), italic = Face(), boldItalic = Face()
    /// `font-feature` entries, e.g. "-calt" or "ss01, -liga".
    var features: [String] = []
    /// `font-size` (macOS default 13).
    var size: CGFloat = 13
    var cellWidth: Modifier?
    var cellHeight: Modifier?

    init() {}

    init(config: ghostty_config_t?) {
        guard let config else { return }
        func get<T>(_ key: String, _ value: inout T) -> Bool {
            ghostty_config_get(config, &value, key, UInt(key.lengthOfBytes(using: .utf8)))
        }
        func list(_ key: String) -> [String] {
            var l = ghostty_config_string_list_s()
            guard get(key, &l) else { return [] }
            return withUnsafeBytes(of: &l.items) { raw in
                raw.bindMemory(to: UnsafePointer<CChar>?.self).prefix(Int(l.len)).compactMap { $0.map { String(cString: $0) } }
            }
        }
        func style(_ key: String) -> FaceStyle {
            var s = ghostty_config_font_style_s()
            guard get(key, &s) else { return .standard }
            switch s.kind {
            case 1: return .disabled
            case 2: return s.name.map { .named(String(cString: $0)) } ?? .standard
            default: return .standard
            }
        }
        func modifier(_ key: String) -> Modifier? {
            var m = ghostty_config_metric_modifier_s()
            return get(key, &m) ? Modifier(absolute: m.absolute, value: m.value) : nil
        }
        regular = Face(families: list("font-family"), style: style("font-style"))
        bold = Face(families: list("font-family-bold"), style: style("font-style-bold"))
        italic = Face(families: list("font-family-italic"), style: style("font-style-italic"))
        boldItalic = Face(families: list("font-family-bold-italic"), style: style("font-style-bold-italic"))
        features = list("font-feature")
        var size: Float = 0
        if get("font-size", &size), size > 0 { self.size = CGFloat(size) }
        cellWidth = modifier("adjust-cell-width")
        cellHeight = modifier("adjust-cell-height")
    }
}

/// The four faces of the preview plus its cell metrics.
struct SwitcherFonts {
    var regular: NSFont, bold: NSFont, italic: NSFont, boldItalic: NSFont
    var lineHeight: CGFloat
    /// Extra advance per character, from `adjust-cell-width`.
    var kern: CGFloat

    func font(bold isBold: Bool, italic isItalic: Bool) -> NSFont {
        switch (isBold, isItalic) {
        case (false, false): return regular
        case (true, false): return bold
        case (false, true): return italic
        case (true, true): return boldItalic
        }
    }

    /// The preview is a little smaller than the terminal, never below 10 pt.
    static func previewSize(terminal: CGFloat) -> CGFloat { max(10, terminal * 0.85) }

    /// System monospaced, for when there is no config at all.
    static func system(size: CGFloat) -> SwitcherFonts {
        func f(_ w: NSFont.Weight, _ italic: Bool) -> NSFont {
            let base = NSFont.monospacedSystemFont(ofSize: size, weight: w)
            guard italic else { return base }
            return NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(.italic), size: size) ?? base
        }
        return SwitcherFonts(
            regular: f(.regular, false), bold: f(.bold, false), italic: f(.regular, true),
            boldItalic: f(.bold, true), lineHeight: ceil(size * 1.25), kern: 0)
    }

    /// Resolves the terminal's fonts for the preview. Each face tries its configured
    /// families in order; then the regular face of the family (bold/italic only), then
    /// the JetBrains Mono the terminal itself falls back to, then system monospaced.
    static func resolve(_ c: SwitcherFontConfig, backingScale: CGFloat = 2) -> SwitcherFonts {
        let size = previewSize(terminal: c.size)
        let configured = lookup(c.regular, bold: false, italic: false, size: size)
        let base = configured ?? SwitcherDefaultFont.font(bold: false, italic: false, size: size)
            ?? system(size: size).regular
        func face(_ spec: SwitcherFontConfig.Face, bold: Bool, italic: Bool) -> NSFont {
            if spec.style == .disabled { return base }
            let found = lookup(spec, bold: bold, italic: italic, size: size)
                ?? lookup(.init(families: c.regular.families), bold: bold, italic: italic, size: size)
            let font = found ?? configured
                ?? SwitcherDefaultFont.font(bold: bold, italic: italic, size: size)
                ?? system(size: size).font(bold: bold, italic: italic)
            // The terminal slants a family that has no italic.
            return italic && !NSFontManager.shared.traits(of: font).contains(.italicFontMask) ? slanted(font) : font
        }
        let features = parseFeatures(c.features)
        func final(_ f: NSFont) -> NSFont { withSymbols(applying(features, to: f)) }
        let regular = final(face(c.regular, bold: false, italic: false))
        // Cell metrics like the terminal's: natural height and width, then adjust-cell-*.
        let ratio = size / c.size
        func adjusted(_ natural: CGFloat, _ m: SwitcherFontConfig.Modifier?) -> CGFloat {
            guard let m else { return natural }
            return m.absolute ? natural + CGFloat(m.value) / backingScale * ratio : natural * CGFloat(m.value)
        }
        let naturalHeight = ceil(regular.ascender - regular.descender + regular.leading)
        let naturalWidth = regular.maximumAdvancement.width
        return SwitcherFonts(
            regular: regular,
            bold: final(face(c.bold, bold: true, italic: false)),
            italic: final(face(c.italic, bold: false, italic: true)),
            boldItalic: final(face(c.boldItalic, bold: true, italic: true)),
            lineHeight: max(1, adjusted(naturalHeight, c.cellHeight)),
            kern: adjusted(naturalWidth, c.cellWidth) - naturalWidth)
    }

    /// The first of the face's families that has the requested face.
    static func lookup(_ spec: SwitcherFontConfig.Face, bold: Bool, italic: Bool, size: CGFloat) -> NSFont? {
        for family in spec.families {
            if let f = face(family: family, style: spec.style, bold: bold, italic: italic, size: size) { return f }
        }
        return nil
    }

    static func face(family: String, style: SwitcherFontConfig.FaceStyle, bold: Bool, italic: Bool, size: CGFloat) -> NSFont? {
        guard let name = canonicalFamily(family) else { return nil }
        if case .named(let face) = style {
            let d = NSFontDescriptor(fontAttributes: [.family: name, .face: face])
            if let f = NSFont(descriptor: d, size: size), f.familyName == name,
               (f.fontDescriptor.object(forKey: .face) as? String)?.caseInsensitiveCompare(face) == .orderedSame {
                return f
            }
        }
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        guard let f = NSFontManager.shared.font(withFamily: name, traits: traits, weight: bold ? 9 : 5, size: size),
              f.familyName == name else { return nil }
        return f
    }

    /// A family as the system spells it, from its name in any case or a full/PostScript name.
    static func canonicalFamily(_ name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        return NSFontManager.shared.availableFontFamilies.first { $0.caseInsensitiveCompare(name) == .orderedSame }
            ?? NSFont(name: name, size: 12)?.familyName
    }

    /// Synthetic italic, with the terminal's own skew (15 degrees).
    static func slanted(_ font: NSFont) -> NSFont {
        var skew = CGAffineTransform(a: 1, b: 0, c: 0.267949, d: 1, tx: 0, ty: 0)
        return CTFontCreateWithFontDescriptor(CTFontCopyFontDescriptor(font as CTFont), font.pointSize, &skew) as NSFont
    }

    /// Falls back to the Symbols Nerd Font the terminal embeds, so powerline and icon glyphs show.
    static func withSymbols(_ font: NSFont) -> NSFont {
        guard let symbols = SwitcherDefaultFont.symbols else { return font }
        let cascade = CTFontDescriptorCreateWithAttributes([kCTFontCascadeListAttribute: [symbols]] as CFDictionary)
        return CTFontCreateCopyWithAttributes(font as CTFont, font.pointSize, nil, cascade) as NSFont
    }

    // MARK: font-feature

    /// "-calt", "ss01", "ss01=2", "\"liga\" 0", comma separated.
    static func parseFeatures(_ entries: [String]) -> [(tag: String, value: Int)] {
        entries.flatMap { $0.split(separator: ",") }.compactMap { raw in
            var token = raw.trimmingCharacters(in: .whitespaces)
            var value = 1
            if token.hasPrefix("-") { value = 0; token.removeFirst() } else if token.hasPrefix("+") { token.removeFirst() }
            let parts = token.split(whereSeparator: { $0 == "=" || $0 == " " }).map(String.init)
            guard let first = parts.first else { return nil }
            let tag = first.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard tag.utf8.count == 4 else { return nil }
            if parts.count > 1 {
                switch parts[1].lowercased() {
                case "on", "true": value = 1
                case "off", "false": value = 0
                default: if let v = Int(parts[1]) { value = v } else { return nil }
                }
            }
            return (tag, value)
        }
    }

    static func applying(_ features: [(tag: String, value: Int)], to font: NSFont) -> NSFont {
        guard !features.isEmpty else { return font }
        let settings: [[String: Any]] = features.map {
            [kCTFontOpenTypeFeatureTag as String: $0.tag, kCTFontOpenTypeFeatureValue as String: $0.value]
        }
        let d = font.fontDescriptor.addingAttributes([.featureSettings: settings])
        return NSFont(descriptor: d, size: font.pointSize) ?? font
    }
}

/// The JetBrains Mono that the terminal draws with when `font-family` is not set
/// (the variable font embedded in the library), made without installing it.
enum SwitcherDefaultFont {
    private static func descriptor(_ kind: UInt8) -> CTFontDescriptor? {
        var len: UInt = 0
        guard let ptr = ghostty_omnity_default_font(kind, &len) else { return nil }
        let data = Data(bytes: ptr, count: Int(len)) as CFData
        return (CTFontManagerCreateFontDescriptorsFromData(data) as? [CTFontDescriptor])?.first
    }
    private static let descriptors: [Bool: CTFontDescriptor] = {
        var out: [Bool: CTFontDescriptor] = [:]
        for italic in [false, true] { out[italic] = descriptor(italic ? 1 : 0) }
        return out
    }()
    /// The Symbols Nerd Font embedded in the library.
    static let symbols: CTFontDescriptor? = descriptor(2)

    static func font(bold: Bool, italic: Bool, size: CGFloat) -> NSFont? {
        guard var d = descriptors[italic] else { return nil }
        // wght axis, like the terminal's own bold for this font.
        if bold { d = CTFontDescriptorCreateCopyWithVariation(d, NSNumber(value: 0x7767_6874), 700) }
        return CTFontCreateWithFontDescriptor(d, size, nil) as NSFont
    }
}
