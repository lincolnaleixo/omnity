//
//  RemoteDropTests.swift
//  GhosttyTests
//
//  Omnity: tests for the ssh argv parser used by remote drop.
//
import Testing
import Foundation
@testable import Ghostty

struct RemoteDropTests {
    @Test func plainHost() {
        #expect(RemoteDrop.target(argv: ["ssh", "omni"])
            == .init(options: [], destination: "omni"))
    }

    @Test func portAndUser() {
        #expect(RemoteDrop.target(argv: ["ssh", "-p", "2222", "user@omni"])
            == .init(options: ["-p", "2222"], destination: "user@omni"))
    }

    @Test func attachedValue() {
        #expect(RemoteDrop.target(argv: ["/usr/bin/ssh", "-p2222", "omni"])
            == .init(options: ["-p", "2222"], destination: "omni"))
    }

    @Test func remoteCommand() {
        #expect(RemoteDrop.target(argv: ["ssh", "-t", "omni", "tmux", "a"])
            == .init(options: [], destination: "omni"))
    }

    @Test func droppedOptions() {
        #expect(RemoteDrop.target(argv: ["ssh", "-L", "8080:localhost:80", "-A", "omni"])
            == .init(options: [], destination: "omni"))
    }

    @Test func notSsh() {
        #expect(RemoteDrop.target(argv: ["mosh", "omni"]) == nil)
        #expect(RemoteDrop.target(argv: ["ssh"]) == nil)
    }

    @Test func remoteName() {
        let url = URL(fileURLWithPath: "/tmp/Screen Shot ção.png")
        let name = RemoteDrop.remoteName(for: url, date: Date(timeIntervalSince1970: 100))
        #expect(name == "100-Screen-Shot---o.png")
    }
}
