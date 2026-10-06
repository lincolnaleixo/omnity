import AppKit
import SwiftUI
import os

/// Omnity: installs new releases by itself. robots-mac-server builds every
/// new commit and publishes `Omnity.zip` as a GitHub release
/// (omnity-release.sh). This checks at launch and every 15 minutes, replaces
/// the app on disk in the background, and offers a Restart button. It never
/// restarts by itself, since that would close the terminals.
final class OmnityUpdater: ObservableObject {
    static let shared = OmnityUpdater()
    static let latestURL = URL(string: "https://api.github.com/repos/lincolnaleixo/omnity/releases/latest")!
    static let log = Logger(subsystem: "com.lincolnaleixo.omnity", category: "update")

    /// The release of the running app, set by omnity-build.sh.
    static let running = Bundle.main.infoDictionary?["OmnityRelease"] as? String

    /// True while the "update ready" pill shows.
    @Published private(set) var showing = false
    private var timer: Timer?
    private var busy = false
    /// The release whose pill was closed with ×, so it does not come back.
    private var dismissed: String?

    func start() {
        guard Self.running != nil, timer == nil else { return }
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
            self?.check()
        }
    }

    private func check() {
        guard !busy else { return }
        busy = true
        Task {
            do {
                if let tag = try await Self.update() {
                    Self.log.notice("installed \(tag, privacy: .public)")
                    await MainActor.run { self.announce(tag) }
                }
            } catch {
                Self.log.error("update failed: \(error.localizedDescription, privacy: .public)")
            }
            await MainActor.run { self.busy = false }
        }
    }

    private func announce(_ tag: String) {
        guard tag != dismissed, !showing else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { showing = true }
    }

    /// Hides the pill; the new release starts the next time Omnity opens.
    func dismiss() {
        dismissed = Self.release(of: Bundle.main.bundleURL)
        withAnimation(.easeIn(duration: 0.2)) { showing = false }
    }

    /// Quits (with the usual confirmation if commands are running) and opens
    /// the new release once this process is gone.
    func restart() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = [
            "-c",
            "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"",
            Bundle.main.bundleURL.path,
        ]
        try? relaunch.run()
        NSApp.terminate(nil)
    }

    private struct Release: Decodable {
        let tag_name: String
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
    }

    private struct UpdateError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// Installs the latest release when it is newer than the running app.
    /// Returns its tag when one is installed and waits for a restart.
    private static func update() async throws -> String? {
        var request = URLRequest(url: latestURL, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: request)
        let release = try JSONDecoder().decode(Release.self, from: data)

        // Tags start with a UTC timestamp, so they sort by date.
        guard let running, release.tag_name > running else { return nil }
        let bundle = Bundle.main.bundleURL
        if self.release(of: bundle) == release.tag_name { return release.tag_name }
        guard let asset = release.assets.first(where: { $0.name == "Omnity.zip" }) else { return nil }

        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("omnity-update-\(UUID().uuidString.prefix(8))")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let (download, _) = try await URLSession.shared.download(from: asset.browser_download_url)
        let zip = dir.appendingPathComponent("Omnity.zip")
        try fm.moveItem(at: download, to: zip)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path])

        let app = dir.appendingPathComponent("Omnity.app")
        guard self.release(of: app) == release.tag_name,
              Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw UpdateError("Omnity.zip does not hold release \(release.tag_name)")
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", app.path])

        // Swap the bundle on disk; the running app keeps its loaded copy.
        _ = try fm.replaceItemAt(bundle, withItemAt: app)
        return release.tag_name
    }

    private static func release(of app: URL) -> String? {
        NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["OmnityRelease"] as? String
    }

    private static func run(_ path: String, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError("\((path as NSString).lastPathComponent) exited with \(process.terminationStatus)")
        }
    }
}

/// "Update ready" pill with Restart and close, top-center of every surface.
struct OmnityUpdateBadge: View {
    @ObservedObject private var updater = OmnityUpdater.shared

    var body: some View {
        ZStack(alignment: .top) {
            if updater.showing {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.green)
                    Text("Omnity update ready")

                    Button("Restart") { updater.restart() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.accentColor))

                    Button { updater.dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Later: the update starts next time Omnity opens")
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.leading, 14)
                .padding(.trailing, 8)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
                .padding(.top, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        // Only the pill takes clicks; the empty area passes them to the terminal.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
