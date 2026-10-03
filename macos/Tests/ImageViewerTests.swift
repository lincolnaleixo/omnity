//
//  ImageViewerTests.swift
//  GhosttyTests
//
//  Omnity: tests for finding image paths in terminal text.
//
import Testing
import Foundation
@testable import Ghostty

struct ImageViewerTests {
    @Test func findsPathsInOrder() {
        let text = """
        Saved ~/uploads/1-shot.png and /tmp/a.JPG
        see ./out/chart.webp, again ~/uploads/1-shot.png
        """
        #expect(ImageViewer.imagePaths(in: text)
            == ["~/uploads/1-shot.png", "/tmp/a.JPG", "./out/chart.webp"])
    }

    @Test func ignoresUrlsAndOtherFiles() {
        let text = "https://example.com/a.png notes.md /tmp/file.pdf"
        #expect(ImageViewer.imagePaths(in: text).isEmpty)
    }

    @Test func quotedPath() {
        #expect(ImageViewer.imagePaths(in: "open '/home/robot/x.png'") == ["/home/robot/x.png"])
    }

    @Test func catCommandKeepsTilde() {
        #expect(ImageViewer.catCommand("~/up loads/it's.png") == #"cat -- ~/'up loads/it'\''s.png'"#)
        #expect(ImageViewer.catCommand("/tmp/a.png") == "cat -- '/tmp/a.png'")
    }
}
