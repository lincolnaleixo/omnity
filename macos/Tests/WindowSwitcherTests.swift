//
//  WindowSwitcherTests.swift
//  GhosttyTests
//
//  Omnity: tests for the option+tab window switcher model.
//
import Testing
import Foundation
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
        #expect(WindowSwitcherModel.clean("\u{1B}[31mred\u{1B}[0m\n\n  \n") == "red")
    }

    @Test func windowIDs() {
        #expect(TmuxSwitchClient.isWindowID("@12"))
        #expect(!TmuxSwitchClient.isWindowID("@12; rm -rf ~"))
    }
}
