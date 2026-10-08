//
//  WrappedLinkTests.swift
//  GhosttyTests
//
//  Omnity: URLs that a CLI wrapped onto several lines are joined.
//
import Testing
import Foundation
@testable import Ghostty

struct WrappedLinkTests {
    // 40 columns: the first two URL lines run to the edge.
    let screen = """
    ● The login link is ready:

      https://claude.ai/oauth/authorize?a=1
      &code_challenge=Nb0CC5IFyaeI4oJg8xH6X
      %3Afile_upload&state=234e6f

      How to do it:
    """

    @Test func joinsContinuationLines() {
        #expect(WrappedLink.join("https://claude.ai/oauth/authorize?a=1", in: screen, columns: 40)
            == "https://claude.ai/oauth/authorize?a=1&code_challenge=Nb0CC5IFyaeI4oJg8xH6X%3Afile_upload&state=234e6f")
    }

    @Test func shortLineIsNotJoined() {
        let text = "see https://example.com/a\nREADME.md\n"
        #expect(WrappedLink.join("https://example.com/a", in: text, columns: 80) == "https://example.com/a")
    }

    @Test func proseIsNotJoined() {
        let text = "  https://claude.ai/oauth/authorize?a=1234\n  and then click Authorize\n"
        #expect(WrappedLink.join("https://claude.ai/oauth/authorize?a=1234", in: text, columns: 44)
            == "https://claude.ai/oauth/authorize?a=1234")
    }
}
