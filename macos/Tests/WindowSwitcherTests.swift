//
//  WindowSwitcherTests.swift
//  GhosttyTests
//
//  Omnity: tests for the option+tab window switcher model.
//
import Testing
import Foundation
import SwiftUI
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
            AnsiText.attributed(s, theme: t, size: 10.5).runs.first!
        }
        #expect(run("\u{1B}[7mx").foregroundColor == t.bg.color)
        #expect(run("\u{1B}[7mx").backgroundColor == t.fg.color)
        #expect(run("\u{1B}[2mx").foregroundColor == t.fg.mixed(with: t.bg, 0.5).color)
        #expect(run("\u{1B}[4mx").underlineStyle == .single)
        #expect(AnsiText.attributed("", theme: t, size: 10).characters.count == 1)
    }

    @Test func windowIDs() {
        #expect(TmuxSwitchClient.isWindowID("@12"))
        #expect(!TmuxSwitchClient.isWindowID("@12; rm -rf ~"))
    }
}
