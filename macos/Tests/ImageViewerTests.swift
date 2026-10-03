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

    @Test func ignoresOtherFiles() {
        let text = "notes.md /tmp/file.pdf https://example.com/page"
        #expect(ImageViewer.imagePaths(in: text).isEmpty)
    }

    @Test func findsImageUrlsAndCleanShot() {
        let text = """
        see https://example.com/img/a.png?x=1, then /tmp/b.jpg
        and https://cleanshot.com/share/mTccRtnZ.
        """
        #expect(ImageViewer.imagePaths(in: text) == [
            "https://example.com/img/a.png?x=1",
            "/tmp/b.jpg",
            "https://cleanshot.com/share/mTccRtnZ",
        ])
    }

    @Test func cleanShotDownloadUrl() {
        let url = URL(string: "https://cleanshot.com/share/mTccRtnZ")!
        #expect(ImageViewer.downloadURL(url).absoluteString
            == "https://cleanshot.com/share/mTccRtnZ/download")
        let direct = URL(string: "https://example.com/a.png")!
        #expect(ImageViewer.downloadURL(direct) == direct)
    }

    @Test func quotedPath() {
        #expect(ImageViewer.imagePaths(in: "open '/home/robot/x.png'") == ["/home/robot/x.png"])
    }

    @Test func catCommandKeepsTilde() {
        #expect(ImageViewer.catCommand("~/up loads/it's.png") == #"cat -- ~/'up loads/it'\''s.png'"#)
        #expect(ImageViewer.catCommand("/tmp/a.png") == "cat -- '/tmp/a.png'")
    }
}
