//
//  SessionTabsTests.swift
//  GhosttyTests
//
//  Omnity: tests for the tmux session tabs (order, key routing, parsing).
//
import Testing
import Foundation
import AppKit
@testable import Ghostty

struct SessionTabsTests {
    static func window(_ id: String, _ state: String) -> TmuxWindow {
        TmuxWindow(id: id, index: 1, name: id, state: state, title: "t", path: "/", command: "claude", activity: 1, last_used: 1, active: false)
    }
    static func session(_ name: String, _ states: [String] = ["idle"]) -> TmuxSession {
        TmuxSession(name: name, windows: states.enumerated().map { window("@\(name)\($0)", $1) })
    }
    let sessions = ["youtube", "Tools", "ecom", "personal", "alpha"].map { session($0) }

    // MARK: Event monitors
    @Test func swallowedKeyStaysSwallowed() throws {
        let e = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .option, timestamp: 0,
                                              windowNumber: 0, context: nil, characters: "2", charactersIgnoringModifiers: "2",
                                              isARepeat: false, keyCode: 19))
        final class Owner {}
        let o = Owner()
        #expect(OmnityMonitor.run(o, e) { _, _ in nil } == nil)          // handled: the terminal must not see it
        #expect(OmnityMonitor.run(o, e) { _, ev in ev } === e)           // not ours: passes on
        #expect(OmnityMonitor.run(nil as Owner?, e) { _, _ in nil } === e)  // owner gone: passes on
    }
    // MARK: Order

    @Test func alphabeticalByDefault() {
        let names = SessionTabsModel.order(sessions, preferred: []).map(\.name)
        #expect(names == ["alpha", "ecom", "personal", "Tools", "youtube"])
    }

    @Test func listedFirstThenAlphabetical() {
        let names = SessionTabsModel.order(sessions, preferred: ["ecom", "youtube", "personal", "tools"]).map(\.name)
        // "tools" is not "Tools": unknown names are ignored, the rest stays alphabetical.
        #expect(names == ["ecom", "youtube", "personal", "alpha", "Tools"])
        let full = SessionTabsModel.order(sessions, preferred: ["Tools", "ecom"]).map(\.name)
        #expect(full == ["Tools", "ecom", "alpha", "personal", "youtube"])
    }

    @Test func orderIgnoresActivityAndInputOrder() {
        let a = SessionTabsModel.order(sessions, preferred: ["ecom"]).map(\.name)
        let b = SessionTabsModel.order(sessions.reversed(), preferred: ["ecom"]).map(\.name)
        #expect(a == b)
    }

    @Test func parsesOrderConfig() {
        #expect(SessionTabsModel.parseOrder("ecom, youtube,,personal ,tools,ecom") == ["ecom", "youtube", "personal", "tools"])
        #expect(SessionTabsModel.parseOrder("").isEmpty)
        #expect(SessionTabsModel.parseOrder(" , ").isEmpty)
    }

    @Test func shortcutsFollowTheFirstNine() {
        let many = (1...11).map { Self.session(String(format: "s%02d", $0)) }
        let tabs = SessionTabsModel.tabs(many, preferred: [])
        #expect(tabs.prefix(9).map(\.shortcut) == (1...9).map { Optional($0) })
        #expect(tabs[9].shortcut == nil && tabs[10].shortcut == nil)
    }

    // MARK: Summary

    @Test func countsStates() {
        let tab = SessionTabsModel.tabs([Self.session("a", ["waiting", "busy", "busy", "bg", "idle", "stale"])], preferred: [])[0]
        #expect(tab.count == 6)
        #expect(tab.waiting == 1 && tab.busy == 2 && tab.bg == 1)
    }

    @Test func findsTheCurrentSession() {
        #expect(SessionTabsModel.session(containing: "@ecom0", in: sessions) == "ecom")
        #expect(SessionTabsModel.session(containing: "@nope", in: sessions) == nil)
        #expect(SessionTabsModel.session(containing: nil, in: sessions) == nil)
    }

    // MARK: Keys

    @Test func cmdDigitsSwitchSessionsOnlyWithTheBar() {
        #expect(SessionTabsKeys.route(keyCode: 18, mods: .command, barVisible: true, tabCount: 4) == .session(0))
        #expect(SessionTabsKeys.route(keyCode: 20, mods: .command, barVisible: true, tabCount: 4) == .session(2))
        #expect(SessionTabsKeys.route(keyCode: 25, mods: .command, barVisible: true, tabCount: 9) == .session(8))
        // No bar: Ghostty's native tab keys.
        #expect(SessionTabsKeys.route(keyCode: 18, mods: .command, barVisible: false, tabCount: 4) == .pass)
    }

    @Test func missingSessionIsSwallowedNotNative() {
        #expect(SessionTabsKeys.route(keyCode: 23, mods: .command, barVisible: true, tabCount: 3) == .swallow)
    }

    @Test func ctrlCmdDigitsJumpToNativeTabs() {
        #expect(SessionTabsKeys.route(keyCode: 19, mods: [.command, .control], barVisible: true, tabCount: 1) == .nativeTab(1))
        #expect(SessionTabsKeys.route(keyCode: 19, mods: [.command, .control], barVisible: false, tabCount: 1) == .pass)
    }

    @Test func otherChordsPass() {
        let digit: UInt16 = 18
        for mods: NSEvent.ModifierFlags in [[], .control, .option, .shift, [.command, .shift], [.command, .option], [.control, .option, .command]] {
            #expect(SessionTabsKeys.route(keyCode: digit, mods: mods, barVisible: true, tabCount: 4) == .pass)
        }
        // Not a digit: cmd+T, cmd+shift+[ stay native.
        #expect(SessionTabsKeys.route(keyCode: 17, mods: .command, barVisible: true, tabCount: 4) == .pass)
        #expect(SessionTabsKeys.route(keyCode: 33, mods: [.command, .shift], barVisible: true, tabCount: 4) == .pass)
        // Caps lock and the function flag do not change the chord.
        #expect(SessionTabsKeys.route(keyCode: 18, mods: [.command, .capsLock], barVisible: true, tabCount: 4) == .session(0))
    }

    // MARK: Parsing

    @Test func detectsSshToTheHost() {
        #expect(SessionTabsModel.attached(argv: ["ssh", "omni"], host: "omni"))
        #expect(SessionTabsModel.attached(argv: ["/usr/bin/ssh", "-t", "robot@omni", "tmux", "attach"], host: "omni"))
        #expect(SessionTabsModel.attached(argv: ["ssh", "-p", "2222", "OMNI"], host: "omni"))
        #expect(!SessionTabsModel.attached(argv: ["ssh", "other"], host: "omni"))
        #expect(!SessionTabsModel.attached(argv: ["zsh"], host: "omni"))
        #expect(!SessionTabsModel.attached(argv: ["ssh", "omni"], host: "off"))
        #expect(!SessionTabsModel.attached(argv: ["ssh", "omni"], host: ""))
    }

    @Test func quotesForTheRemoteShell() {
        #expect(SessionTabsModel.quote("ecom") == "'ecom'")
        #expect(SessionTabsModel.quote("a b") == "'a b'")
        #expect(SessionTabsModel.quote("it's;rm") == "'it'\\''s;rm'")
    }

    @Test func validatesNewNames() {
        #expect(SessionTabsModel.isValidName("new-name_2"))
        #expect(!SessionTabsModel.isValidName(""))
        #expect(!SessionTabsModel.isValidName("a b"))
        #expect(!SessionTabsModel.isValidName("a:b"))
    }

    @Test func decodesTheSnapshotIntoTabs() throws {
        let json = """
        {"generated":1,"current":{"session":"b","window":"@3"},"sessions":[
         {"name":"b","windows":[{"id":"@3","name":"yt","state":"waiting","title":"x"}]},
         {"name":"a","windows":[{"id":"@1","name":"t","state":"busy"},{"id":"@2","name":"u","state":"bg"}]}]}
        """
        let snapshot = try JSONDecoder().decode(TmuxSnapshot.self, from: Data(json.utf8))
        let tabs = SessionTabsModel.tabs(snapshot.sessions, preferred: [])
        #expect(tabs.map(\.name) == ["a", "b"])
        #expect(tabs[0].busy == 1 && tabs[0].bg == 1 && tabs[1].waiting == 1)
        #expect(SessionTabsModel.session(containing: snapshot.current?.window, in: snapshot.sessions) == "b")
    }
}
