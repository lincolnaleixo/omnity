//
//  ReadmeShotsTests.swift
//  GhosttyTests
//
//  Omnity: renders the sidebar README section to PNGs (only with OMNITY_README_SHOTS=<out dir>, fixtures in
//  OMNITY_README_FIXTURES=<dir of .md files>; a normal run does nothing).
//
import Testing
import SwiftUI
import AppKit
@testable import Ghostty
@MainActor
struct ReadmeShotsTests {
    @Test func renderShots() throws {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["OMNITY_README_SHOTS"], let fx = env["OMNITY_README_FIXTURES"] else { return }
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        let tag = env["OMNITY_README_TAG"] ?? "after"
        for name in try FileManager.default.contentsOfDirectory(atPath: fx).sorted() where name.hasSuffix(".md") {
            let md = try String(contentsOfFile: "\(fx)/\(name)", encoding: .utf8)
            for (style, mono) in [("A", nil), ("D", Font.system(size: 13, design: .monospaced))] as [(String, Font?)] {
                let view = VStack(alignment: .leading, spacing: 0) {
                    Text(style == "A" ? "README" : "README").font(.system(size: 11.5, weight: .semibold)).tracking(1.7)
                        .foregroundColor(SB.t3).padding(.bottom, 8)
                    SBReadmeBody(md: md, style: style == "A" ? .editorial : .command)
                }
                .environment(\.sbMono, mono)
                .frame(width: 440, alignment: .leading).padding(22)
                .background(Color(red: 0.12, green: 0.12, blue: 0.18))
                .environment(\.colorScheme, .dark)
                let r = ImageRenderer(content: view)
                r.scale = 2
                let tiff = try #require(r.nsImage?.tiffRepresentation)
                let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: "\(out)/\(name.replacingOccurrences(of: ".md", with: ""))-\(style)-\(tag).png"))
            }
        }
    }
}
