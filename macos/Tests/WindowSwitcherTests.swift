//
//  WindowSwitcherTests.swift
//  GhosttyTests
//
//  Omnity: tests for the option+tab window switcher model.
//
import Testing
import Foundation
import SwiftUI
import AppKit
@testable import Ghostty

struct WindowSwitcherTests {
    static let json = """
    {"generated":1,"current":{"session":"a","window":"@1"},"sessions":[
     {"name":"a","windows":[
       {"id":"@2","index":1,"name":"lln","state":"waiting","title":"t","path":"/","command":"claude","activity":1,"last_used":5,"active":false},
       {"id":"@1","index":2,"name":"tasker","state":"busy","title":"","path":"/","command":"claude","activity":1,"last_used":9,"active":true}]},
     {"name":"b","windows":[
       {"id":"@3","index":1,"name":"yt","state":"bg","title":"x","path":"/","command":"claude","activity":1,"last_used":7,"active":false}]}]}
    """

    func snapshot() throws -> TmuxSnapshot {
        try JSONDecoder().decode(TmuxSnapshot.self, from: Data(Self.json.utf8))
    }

    @Test func decodes() throws {
        let s = try snapshot()
        #expect(s.current?.window == "@1")
        #expect(WindowSwitcherModel.entries(s.sessions).map(\.id) == ["@2", "@1", "@3"])
    }

    @Test func noCurrent() throws {
        let s = try JSONDecoder().decode(TmuxSnapshot.self, from: Data(#"{"current":null,"sessions":[]}"#.utf8))
        #expect(s.current == nil)
    }

    @Test func previousWindowIsMostRecentlyUsed() throws {
        let e = WindowSwitcherModel.entries(try snapshot().sessions)
        #expect(WindowSwitcherModel.defaultSelection(e, current: "@1") == "@3")
    }

    @Test func fallsBackToListOrder() throws {
        var s = try snapshot()
        s.sessions = s.sessions.map { var s = $0; s.windows = s.windows.map { var w = $0; w.last_used = 0; return w }; return s }
        let e = WindowSwitcherModel.entries(s.sessions)
        #expect(WindowSwitcherModel.defaultSelection(e, current: "@2") == "@1")
    }

    @Test func moveWraps() throws {
        let e = WindowSwitcherModel.entries(try snapshot().sessions)
        #expect(WindowSwitcherModel.move(e, from: "@3", by: 1) == "@2")
        #expect(WindowSwitcherModel.move(e, from: "@2", by: -1) == "@3")
        #expect(WindowSwitcherModel.move([], from: nil, by: 1) == nil)
    }

    @Test func headers() throws {
        let s = try snapshot().sessions
        #expect(WindowSwitcherModel.header(s[0]) == "a · 1 waiting · 1 busy")
        #expect(WindowSwitcherModel.header(s[1]) == "b · 1 window")
    }

    @Test func cleansPreview() {
        #expect(WindowSwitcherModel.clean("\u{1B}[31mred\u{1B}[0m\n\n  \n\u{1B}[0m\n") == "\u{1B}[31mred\u{1B}[0m")
    }

    // MARK: Move to session (Omnity)
    @Test func sessionNameValidation() {
        for ok in ["a", "ecommerce", "lln-2", "A_b-9", String(repeating: "x", count: 30)] {
            #expect(MoveModel.isValidName(ok), "\(ok)")
        }
        for bad in ["", " ", "a b", "a.b", "a:b", "x;rm", "$(id)", "é", "a\nb", String(repeating: "x", count: 31)] {
            #expect(!MoveModel.isValidName(bad), "\(bad)")
        }
    }
    @Test func moveCommand() {
        #expect(MoveModel.command(window: "@12", session: "ecommerce") == ["--move", "@12", "ecommerce"])
        #expect(MoveModel.command(window: "12", session: "ecommerce") == nil)
        #expect(MoveModel.command(window: "@1;ls", session: "ecommerce") == nil)
        #expect(MoveModel.command(window: "@1", session: "a b") == nil)
        #expect(MoveModel.command(window: "@1", session: "") == nil)
    }
    @Test func parsesSessions() {
        #expect(MoveModel.parseSessions("lln\necommerce\n\n  yt  \nlln\n_stash\nbad name\n") == ["lln", "ecommerce", "yt"])
        #expect(MoveModel.parseSessions("lln\r\nyt\r\n") == ["lln", "yt"])
        #expect(MoveModel.parseSessions("").isEmpty)
    }
    @Test func pickerRows() {
        let all = ["lln", "ecommerce", "yt", "ecom2"]
        // own session excluded, order kept, "+ New session…" always last
        let list = MoveModel.rows(sessions: all, from: "lln", query: "")
        #expect(list.map(\.name) == ["ecommerce", "yt", "ecom2", ""])
        #expect(list.map(\.kind) == [.existing, .existing, .existing, .prompt])
        // typed new name first, then matches (prefix before contains), then the prompt
        let r = MoveModel.rows(sessions: all, from: "lln", query: "ecom")
        #expect(r.map(\.name) == ["ecom", "ecommerce", "ecom2", ""])
        #expect(r.map(\.kind) == [.create, .existing, .existing, .prompt])
        // enter after typing picks the first existing match, not the new name
        #expect(MoveModel.defaultHighlight(r) == 1)
        #expect(MoveModel.defaultHighlight(list) == 0)
        // an exact match is not offered as a new session
        #expect(MoveModel.rows(sessions: all, from: "lln", query: "yt").map(\.kind) == [.existing, .prompt])
        // neither is the window's own session
        #expect(MoveModel.rows(sessions: all, from: "lln", query: "lln").map(\.kind) == [.prompt])
        // invalid text never creates
        #expect(MoveModel.rows(sessions: all, from: "lln", query: "a b").map(\.kind) == [.prompt])
        // nothing else exists: only the prompt
        #expect(MoveModel.rows(sessions: ["lln"], from: "lln", query: "").map(\.kind) == [.prompt])
        let fresh = MoveModel.rows(sessions: ["lln"], from: "lln", query: "new")
        #expect(fresh.map(\.kind) == [.create, .prompt])
        #expect(MoveModel.defaultHighlight(fresh) == 0)
        #expect(Set(r.map(\.id)).count == r.count)
    }
    @Test func flatItems() throws {
        let items = WindowSwitcherModel.items(try snapshot().sessions)
        #expect(items.map(\.id) == ["h:a", "@2", "@1", "h:b", "@3"])
    }
    @Test func moveMessages() {
        #expect(MoveModel.confirmation(window: "lln", to: "ecommerce") == "Moved lln \u{2192} ecommerce")
        #expect(MoveModel.confirmation(window: "lln", to: "fresh", created: true) == "Moved lln \u{2192} new session fresh")
        #expect(MoveModel.errorText("  can't find window @9\n") == "can't find window @9")
        #expect(MoveModel.errorText(nil) == "Move failed")
        #expect(MoveModel.errorText("  \n") == "Move failed")
    }
    // MARK: ANSI

    static let p = AnsiTheme.fallback.palette
    func runs(_ s: String) -> [AnsiRun] { AnsiParser.parse(s, palette: Self.p) }

    @Test func ansiPlainText() {
        #expect(runs("hello") == [AnsiRun(text: "hello", style: AnsiStyle())])
        #expect(runs("").isEmpty)
    }

    @Test func ansiBaseColorsAndReset() {
        let r = runs("a\u{1B}[31mb\u{1B}[0mc\u{1B}[m")
        #expect(r.map(\.text) == ["a", "b", "c"])
        #expect(r[1].style.fg == Self.p[1])
        #expect(r[2].style == AnsiStyle())
    }

    @Test func ansiBrightAndBackground() {
        let r = runs("\u{1B}[92;44mx\u{1B}[39;49my")
        #expect(r[0].style.fg == Self.p[10])
        #expect(r[0].style.bg == Self.p[4])
        #expect(r[1].style.fg == nil && r[1].style.bg == nil)
        #expect(runs("\u{1B}[101mx")[0].style.bg == Self.p[9])
    }

    @Test func ansiAttributesAndTheirResets() {
        let on = runs("\u{1B}[1;2;3;4;7mx")[0].style
        #expect(on.bold && on.dim && on.italic && on.underline && on.reverse)
        let off = runs("\u{1B}[1;2;3;4;7m\u{1B}[22;23;24;27mx")[0].style
        #expect(off == AnsiStyle())
    }

    @Test func ansi256Color() {
        #expect(runs("\u{1B}[38;5;208mx")[0].style.fg == Self.p[208])
        #expect(runs("\u{1B}[48;5;21mx")[0].style.bg == Self.p[21])
        #expect(Self.p[196] == AnsiRGB(255, 0, 0))
    }

    @Test func ansiTruecolor() {
        let s = runs("\u{1B}[38;2;255;100;0;48;2;1;2;3mx")[0].style
        #expect(s.fg == AnsiRGB(255, 100, 0))
        #expect(s.bg == AnsiRGB(1, 2, 3))
        // colon form, with and without the color space field
        #expect(runs("\u{1B}[38:2::9:8:7mx")[0].style.fg == AnsiRGB(9, 8, 7))
        #expect(runs("\u{1B}[38:2:9:8:7mx")[0].style.fg == AnsiRGB(9, 8, 7))
        #expect(runs("\u{1B}[38:5:208mx")[0].style.fg == Self.p[208])
    }

    @Test func ansiKeepsParsingAfterExtendedColor() {
        let s = runs("\u{1B}[38;5;208;1;4mx")[0].style
        #expect(s.fg == Self.p[208] && s.bold && s.underline)
    }

    @Test func ansiIgnoresUnknownSequences() {
        // underline color, curly underline, cursor movement, OSC title and hyperlink, bare ESC
        let r = runs("\u{1B}[58;5;3ma\u{1B}[4:3mb\u{1B}[2Kc\u{1B}]0;title\u{07}d\u{1B}]8;;http://x\u{1B}\\e\u{1B}Mf\u{1B}")
        #expect(r.map(\.text).joined() == "abcdef")
        #expect(r.allSatisfy { $0.style.fg == nil })
        #expect(runs("\u{1B}[38;5;999mx")[0].style.fg == nil)
        #expect(runs("a\u{1B}[31").map(\.text) == ["a"])
        #expect(runs("a\tb\u{07}")[0].text == "a    b")
    }

    @Test func ansiAttributedAppliesReverseAndDim() {
        let t = AnsiTheme.fallback
        func run(_ s: String) -> AttributedString.Runs.Element {
            AnsiText.attributed(s, theme: t, fonts: .system(size: 10.5)).runs.first!
        }
        #expect(run("\u{1B}[7mx").foregroundColor == t.bg.color)
        #expect(run("\u{1B}[7mx").backgroundColor == t.fg.color)
        #expect(run("\u{1B}[2mx").foregroundColor == t.fg.mixed(with: t.bg, 0.5).color)
        #expect(run("\u{1B}[4mx").underlineStyle == .single)
        #expect(AnsiText.attributed("", theme: t, fonts: .system(size: 10)).characters.count == 1)
    }

    @Test func windowIDs() {
        #expect(TmuxSwitchClient.isWindowID("@12"))
        #expect(!TmuxSwitchClient.isWindowID("@12; rm -rf ~"))
    }

    // MARK: fonts and colors like the terminal

    func traits(_ f: NSFont) -> (bold: Bool, italic: Bool) {
        let t = NSFontManager.shared.traits(of: f)
        return (t.contains(.boldFontMask), t.contains(.italicFontMask))
    }

    @Test func configFontDefaults() throws {
        let c = try TemporaryConfig("").omnityFont
        #expect(c.regular.families.isEmpty)
        #expect(c.regular.style == .standard)
        #expect(c.size == 13)
        #expect(c.features.isEmpty)
        #expect(c.cellHeight == nil)
        #expect(c.cellWidth == nil)
    }

    @Test func configFontReadsTheConfig() throws {
        let c = try TemporaryConfig("""
        font-family = MesloLGS NF
        font-family = Menlo
        font-size = 14.5
        font-style-bold = false
        font-style-italic = Light Italic
        font-feature = -calt
        font-feature = ss01
        adjust-cell-height = 20%
        adjust-cell-width = -2
        """).omnityFont
        #expect(c.regular.families == ["MesloLGS NF", "Menlo"])
        // Ghostty copies font-family to the bold and italic faces unless they are set.
        #expect(c.bold.families == ["MesloLGS NF", "Menlo"])
        #expect(c.size == 14.5)
        #expect(c.bold.style == .disabled)
        #expect(c.italic.style == .named("Light Italic"))
        #expect(c.features == ["-calt", "ss01"])
        #expect(c.cellHeight == .init(absolute: false, value: 1.2))
        #expect(c.cellWidth == .init(absolute: true, value: -2))
    }

    @Test func themeReadsBoldFaintAndContrast() throws {
        var t = try TemporaryConfig("").switcherTheme
        #expect(t.bold == nil)
        #expect(t.minContrast == 1)
        #expect(t.faintOpacity == 0.5)
        t = try TemporaryConfig("bold-color = bright\nminimum-contrast = 3\nfaint-opacity = 0.25").switcherTheme
        #expect(t.bold == .bright)
        #expect(t.minContrast == 3)
        #expect(t.faintOpacity == 0.25)
        t = try TemporaryConfig("bold-color = #102030").switcherTheme
        #expect(t.bold == .color(AnsiRGB(0x10, 0x20, 0x30)))
        // The old spelling still works.
        t = try TemporaryConfig("bold-is-bright = true").switcherTheme
        #expect(t.bold == .bright)
    }

    @Test func fontFamilyIsUsedWithItsBoldAndItalicFaces() {
        var c = SwitcherFontConfig()
        c.regular.families = ["menlo"]  // any case
        let f = SwitcherFonts.resolve(c)
        #expect(f.regular.familyName == "Menlo")
        #expect(traits(f.regular) == (false, false))
        #expect(traits(f.bold) == (true, false))
        #expect(traits(f.italic) == (false, true))
        #expect(traits(f.boldItalic) == (true, true))
        #expect(f.font(bold: true, italic: true) === f.boldItalic)
    }

    @Test func fontFallsThroughTheFamilyList() {
        var c = SwitcherFontConfig()
        c.regular.families = ["No Such Font", "Menlo"]
        #expect(SwitcherFonts.resolve(c).regular.familyName == "Menlo")
    }

    @Test func missingBoldFamilyFallsBackToTheRegularFamily() {
        var c = SwitcherFontConfig()
        c.regular.families = ["Menlo"]
        c.bold.families = ["No Such Font"]
        let f = SwitcherFonts.resolve(c)
        #expect(f.bold.familyName == "Menlo")
        #expect(traits(f.bold) == (true, false))
    }

    @Test func disabledStyleUsesTheRegularFace() {
        var c = SwitcherFontConfig()
        c.regular.families = ["Menlo"]
        c.bold = .init(families: ["Menlo"], style: .disabled)
        #expect(traits(SwitcherFonts.resolve(c).bold) == (false, false))
    }

    @Test func namedStyle() {
        var c = SwitcherFontConfig()
        c.regular = .init(families: ["Menlo"], style: .named("Bold"))
        #expect(traits(SwitcherFonts.resolve(c).regular) == (true, false))
        c.regular.style = .named("No Such Style")
        #expect(traits(SwitcherFonts.resolve(c).regular) == (false, false))
    }

    @Test func noFamilyUsesTheTerminalsEmbeddedDefault() {
        let f = SwitcherFonts.resolve(SwitcherFontConfig())
        #expect(f.regular.familyName == "JetBrains Mono")
        #expect(f.italic.familyName == "JetBrains Mono")
        #expect(traits(f.italic).italic)
        // bold is the same variable font at wght 700
        let w = { (f: NSFont) in (CTFontCopyTraits(f as CTFont) as? [CFString: Any])?[kCTFontWeightTrait] as? Double ?? 0 }
        #expect(w(f.bold) > w(f.regular) + 0.2)
        let unknown = { () -> SwitcherFontConfig in var c = SwitcherFontConfig(); c.regular.families = ["No Such Font"]; return c }()
        #expect(SwitcherFonts.resolve(unknown).regular.familyName == "JetBrains Mono")
    }

    @Test func sizeFollowsTheTerminalWithAMinimum() {
        #expect(abs(SwitcherFonts.previewSize(terminal: 14) - 11.9) < 0.001)
        #expect(SwitcherFonts.previewSize(terminal: 9) == 10)
        var c = SwitcherFontConfig()
        c.size = 20
        #expect(SwitcherFonts.resolve(c).regular.pointSize == 17)
    }

    @Test func cellAdjustments() {
        var c = SwitcherFontConfig()
        c.regular.families = ["Menlo"]
        let natural = SwitcherFonts.resolve(c)
        #expect(natural.kern == 0)
        c.cellHeight = .init(absolute: false, value: 1.5)
        #expect(SwitcherFonts.resolve(c).lineHeight == natural.lineHeight * 1.5)
        // 4 px on a 2x screen is 2 pt in the terminal, 2 * 11.05/13 in the preview.
        c.cellHeight = .init(absolute: true, value: 4)
        #expect(abs(SwitcherFonts.resolve(c, backingScale: 2).lineHeight - (natural.lineHeight + 2 * 11.05 / 13)) < 0.001)
        c.cellWidth = .init(absolute: false, value: 1.1)
        let w = natural.regular.maximumAdvancement.width
        #expect(abs(SwitcherFonts.resolve(c).kern - w * 0.1) < 0.001)
    }

    @Test func fontFeatures() {
        let p = SwitcherFonts.parseFeatures(["-calt, +liga", "ss01=2", "\"dlig\" 0", "bad", "zero on"])
        #expect(p.map(\.tag) == ["calt", "liga", "ss01", "dlig", "zero"])
        #expect(p.map(\.value) == [0, 1, 2, 0, 1])
        var c = SwitcherFontConfig()
        c.regular.families = ["Menlo"]
        c.features = ["-calt"]
    }

    func glyphs(_ f: NSFont, _ text: String) -> [CGGlyph] {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: f]))
        return (CTLineGetGlyphRuns(line) as! [CTRun]).flatMap { run -> [CGGlyph] in
            var out = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &out)
            return out
        }
    }

    @Test func fontFeaturesChangeTheGlyphs() {
        // JetBrains Mono (the terminal's default) draws "->" as a ligature glyph with calt.
        var c = SwitcherFontConfig()
        let withCalt = glyphs(SwitcherFonts.resolve(c).regular, "->")
        c.features = ["-calt"]
        let without = glyphs(SwitcherFonts.resolve(c).regular, "->")
        #expect(withCalt.count == 2 && without.count == 2)
        #expect(withCalt != without)
    }

    @Test func boldBrightAndBoldColor() {
        var t = AnsiTheme.fallback
        func fg(_ s: String) -> AnsiRGB {
            let run = AnsiParser.parse(s, palette: t.palette).first!
            return AnsiText.colors(run.style, theme: t).fg
        }
        // no bold-color: bold keeps the color
        #expect(fg("\u{1B}[1;31mx") == t.palette[1])
        t.bold = .bright
        #expect(fg("\u{1B}[1;31mx") == t.palette[9])
        #expect(fg("\u{1B}[1;38;5;2mx") == t.palette[10])
        #expect(fg("\u{1B}[1;38;5;20mx") == t.palette[20])
        #expect(fg("\u{1B}[31mx") == t.palette[1])
        #expect(fg("\u{1B}[1mx") == t.fg)
        t.bold = .color(AnsiRGB(1, 2, 3))
        #expect(fg("\u{1B}[1mx") == AnsiRGB(1, 2, 3))
        #expect(fg("\u{1B}[1;38;2;1;1;1mx") == AnsiRGB(1, 1, 1))
        #expect(fg("\u{1B}[mx") == t.fg)
    }

    @Test func minimumContrastAndFaintOpacity() {
        var t = AnsiTheme.fallback
        t.bg = AnsiRGB(0, 0, 0)
        t.palette[8] = AnsiRGB(0x10, 0x10, 0x10)
        func fg(_ s: String) -> AnsiRGB {
            AnsiText.colors(AnsiParser.parse(s, palette: t.palette).first!.style, theme: t).fg
        }
        #expect(fg("\u{1B}[90mx") == AnsiRGB(0x10, 0x10, 0x10))
        t.minContrast = 4.5
        #expect(fg("\u{1B}[90mx") == AnsiRGB(255, 255, 255))   // too dark on black: white
        #expect(fg("\u{1B}[97mx") == t.palette[15])             // enough contrast: untouched
        t.minContrast = 1
        t.faintOpacity = 0.25
        #expect(fg("\u{1B}[2;38;2;200;200;200mx") == AnsiRGB(50, 50, 50))
    }

    @Test func minimumContrastSkipsGraphicsAndComesBeforeFaint() {
        var t = AnsiTheme.fallback
        t.bg = AnsiRGB(0, 0, 0)
        t.minContrast = 4.5
        let dark = AnsiParser.parse("\u{1B}[38;2;16;16;16mx", palette: t.palette).first!.style
        #expect(AnsiText.colors(dark, theme: t).fg == AnsiRGB(255, 255, 255))
        #expect(AnsiText.colors(dark, theme: t, graphics: true).fg == AnsiRGB(16, 16, 16))
        // faint dims the corrected color: white at 50% on black
        let faint = AnsiParser.parse("\u{1B}[2;38;2;16;16;16mx", palette: t.palette).first!.style
        #expect(AnsiText.colors(faint, theme: t).fg == AnsiRGB(128, 128, 128))
        #expect(AnsiText.segments("ab\u{2588}\u{E0B0}c").map(\.0) == ["ab", "\u{2588}\u{E0B0}", "c"])
        #expect(AnsiText.segments("ab\u{2588}\u{E0B0}c").map(\.1) == [false, true, false])
    }

    @Test func slantsAFamilyWithoutItalicAndFallsBackToNerdSymbols() {
        var c = SwitcherFontConfig()
        c.regular.families = ["Monaco"]
        let f = SwitcherFonts.resolve(c)
        #expect(CTFontGetMatrix(f.italic as CTFont).c > 0.2)
        #expect(CTFontGetMatrix(f.regular as CTFont).c == 0)
        // Powerline glyphs come from the embedded Symbols Nerd Font
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "\u{E0B0}", attributes: [.font: f.regular]))
        let run = (CTLineGetGlyphRuns(line) as! [CTRun])[0]
        let font = (CTRunGetAttributes(run) as! [CFString: Any])[kCTFontAttributeName] as! CTFont
        #expect((CTFontCopyFamilyName(font) as String).contains("Symbols"))
    }
    @Test func sshLocalPortFromLsof() {
        let out = "p75002\nf3\nn192.168.0.44:54773->162.55.194.190:22\nf5\nn*:59869\n"
        #expect(TmuxSwitchClient.localPort(lsof: out) == "54773")
        #expect(TmuxSwitchClient.localPort(lsof: "p1\nf5\nn*:59869\n") == nil)
        #expect(TmuxSwitchClient.localPort(lsof: "") == nil)
    }
}
