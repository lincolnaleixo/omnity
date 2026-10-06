//
//  BareLinkTests.swift
//  GhosttyTests
//
//  Omnity: scheme-less links that start with a domain open as https.
//
import Testing
import Foundation
@testable import Ghostty

struct BareLinkTests {
    @Test func domains() {
        #expect(BareLink.webURL("github.com/lincolnaleixo/omnity")?.absoluteString
            == "https://github.com/lincolnaleixo/omnity")
        #expect(BareLink.webURL("omni.tiffany-ling.ts.net:8443")?.absoluteString
            == "https://omni.tiffany-ling.ts.net:8443")
        #expect(BareLink.webURL("longlifenutri.com.br")?.absoluteString
            == "https://longlifenutri.com.br")
    }

    @Test func pathsStayPaths() {
        #expect(BareLink.webURL("src/config/Config.zig") == nil)
        #expect(BareLink.webURL("~/uploads/a.png") == nil)
        #expect(BareLink.webURL("/tmp/a.txt") == nil)
        #expect(BareLink.webURL("./build.zig") == nil)
        #expect(BareLink.webURL("notes.md") == nil)
        #expect(BareLink.webURL("Package.swift") == nil)
        #expect(BareLink.webURL("https://example.com") == nil)
        #expect(BareLink.webURL("install.sh") == nil)
        #expect(BareLink.webURL("Omnity.app") == nil)
    }
}
