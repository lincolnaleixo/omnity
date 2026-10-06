import Foundation

/// Omnity: link detection treats `github.com/x` or `host.ts.net:8443` as a
/// file path, so cmd+click tried to open a local file and did nothing. When
/// such a "path" starts with a domain, open it as https instead.
enum BareLink {
    /// Top-level domains common enough to read a bare `name.tld` as a site.
    static let tlds: Set<String> = [
        "com", "net", "org", "io", "dev", "ai", "co", "me", "gg", "xyz", "tv", "info",
        "biz", "us", "uk", "de", "fr", "es", "it", "pt", "br", "ca", "eu", "cloud",
        "site", "tech", "page", "link", "to", "ly",
    ]

    /// The https URL for a scheme-less link that starts with a domain, or nil
    /// when it is a file path.
    static func webURL(_ text: String) -> URL? {
        // `host:8443` parses as scheme "host", so look for "://" instead.
        guard !text.contains("://"), !text.lowercased().hasPrefix("mailto:"),
              let first = text.first, first != "/", first != "~", first != "." else { return nil }

        let host = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
        let name = host.split(separator: ":", maxSplits: 1).first.map(String.init) ?? host
        if let port = host.split(separator: ":", maxSplits: 1).dropFirst().first,
           port.isEmpty || !port.allSatisfy(\.isNumber) { return nil }

        let labels = name.lowercased().split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2,
              labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }),
              let tld = labels.last, tlds.contains(String(tld)) else { return nil }

        return URL(string: "https://" + text)
    }
}
