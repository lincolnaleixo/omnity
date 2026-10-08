import AppKit

/// Omnity: CLIs such as Codex and Claude Code wrap a long URL with real
/// newlines and an indent, so link detection stops at the end of the first
/// line and cmd+click opened a cut URL. Join the lines that continue it.
enum WrappedLink {
    /// Characters a URL can hold; a continuation line has only these.
    static func isURLChar(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || "-._~:/?#[]@!$&'()*+,;=%".contains(c))
    }

    /// The clicked link plus the lines that continue it. A line continues the
    /// link when the line before it ran to the right edge (within a few
    /// columns, since CLIs wrap a little short of it) and it is, once its
    /// indent is trimmed, made only of URL characters.
    static func join(_ link: String, in screen: String, columns: Int) -> String {
        guard columns > 0 else { return link }
        let lines = screen.components(separatedBy: "\n")
        let edge = columns - 4

        // The newest line that ends with the link.
        guard var i = lines.lastIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasSuffix(link)
        }) else { return link }

        var full = link
        while lines[i].count >= edge, i + 1 < lines.count {
            let next = lines[i + 1].trimmingCharacters(in: .whitespaces)
            guard !next.isEmpty, next.allSatisfy(isURLChar) else { break }
            full += next
            i += 1
        }
        return full
    }
}

extension Ghostty.SurfaceView {
    /// Opens a web link, joined with the lines it was wrapped onto. Core calls
    /// open_url with the renderer lock held and reading the screen takes it,
    /// so call this asynchronously.
    func openWebLink(_ text: String) {
        let columns = Int(surfaceSize?.columns ?? 0)
        let full = WrappedLink.join(text, in: cachedScreenContents.get(), columns: columns)
        if let url = BareLink.webURL(full) ?? URL(string: full) {
            NSWorkspace.shared.open(url)
        }
    }
}
