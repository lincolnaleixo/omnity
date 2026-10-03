import AppKit
import SwiftUI

/// Omnity: cmd+click an image path to see it in a viewer over the terminal,
/// with a filmstrip of the other image paths on screen. When the foreground
/// process is `ssh <host>`, images are read from that host over ssh.
///
/// Enabled with `macos-image-viewer = true`.
enum ImageViewer {
    static let extensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "bmp"]
    static let maxItems = 40

    /// Image paths and image URLs in terminal text, in order of appearance,
    /// without duplicates.
    static func imagePaths(in text: String) -> [String] {
        let patterns = [
            #"(?<![\w/:.~\-])(?:~/|\.{1,2}/|/)?(?:[\w.\-@+]+/)*[\w.\-@+]+\.(?:png|jpe?g|gif|webp|heic|tiff?|bmp)(?![\w])"#,
            #"https?://[^\s'"<>()\[\]]+"#,
        ]
        let range = NSRange(text.startIndex..., in: text)
        var found: [(Int, String)] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            for match in regex.matches(in: text, range: range) {
                guard let r = Range(match.range, in: text) else { continue }
                var item = String(text[r])
                while let last = item.last, ".,;:!?".contains(last) { item.removeLast() }
                if isImage(item) { found.append((match.range.location, item)) }
            }
        }

        var seen = Set<String>()
        return found.sorted { $0.0 < $1.0 }.map(\.1).filter { seen.insert($0).inserted }
    }

    /// A path to an image file, an http(s) URL to one, or a CleanShot share link.
    static func isImage(_ item: String) -> Bool {
        if let url = webURL(item) {
            return isCleanShot(url) || extensions.contains(url.pathExtension.lowercased())
        }
        guard URL(string: item)?.scheme == nil else { return false }
        return extensions.contains((item as NSString).pathExtension.lowercased())
    }

    static func webURL(_ item: String) -> URL? {
        guard let url = URL(string: item), url.scheme == "http" || url.scheme == "https" else { return nil }
        return url
    }

    static func isCleanShot(_ url: URL) -> Bool {
        (url.host?.hasSuffix("cleanshot.com") ?? false) && url.path.hasPrefix("/share/")
    }

    /// The URL that serves the image itself (CleanShot shares are pages).
    static func downloadURL(_ url: URL) -> URL {
        guard isCleanShot(url), url.lastPathComponent != "download" else { return url }
        return url.appendingPathComponent("download")
    }

    /// Where an item is read from, for the caption.
    static func source(of item: String, target: RemoteDrop.Target?) -> String {
        webURL(item)?.host ?? target?.destination ?? "local"
    }

    static func download(_ url: URL) async -> Result<NSImage, RemoteDropError> {
        var request = URLRequest(url: downloadURL(url), timeoutInterval: 30)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let image = NSImage(data: data) { return .success(image) }
            return .failure(RemoteDropError(message: "Not an image: \(url.absoluteString)"))
        } catch {
            return .failure(RemoteDropError(message: error.localizedDescription))
        }
    }

    /// The remote command that prints a file, keeping `~/` expandable.
    static func catCommand(_ path: String) -> String {
        func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        if path.hasPrefix("~/") { return "cat -- ~/" + quote(String(path.dropFirst(2))) }
        return "cat -- " + quote(path)
    }

    /// Reads an image from disk or, with a target, from the remote host.
    static func load(_ path: String, from target: RemoteDrop.Target?) async -> Result<NSImage, RemoteDropError> {
        if let url = webURL(path) { return await download(url) }
        guard let target else {
            let expanded = NSString(string: path).standardizingPath
            if let image = NSImage(contentsOfFile: expanded) { return .success(image) }
            return .failure(RemoteDropError(message: "Can't open \(path)"))
        }

        let args = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
            + target.options + [target.destination, catCommand(path)]
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                process.arguments = args
                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    cont.resume(returning: .failure(RemoteDropError(message: error.localizedDescription)))
                    return
                }
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus == 0, let image = NSImage(data: data) {
                    cont.resume(returning: .success(image))
                    return
                }
                let message = String(decoding: errData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                cont.resume(returning: .failure(RemoteDropError(
                    message: message.isEmpty ? "Not an image: \(path)" : message)))
            }
        }
    }
}

/// One open viewer: its images, the selection and what has loaded.
final class ImageViewerModel: ObservableObject {
    let paths: [String]
    let target: RemoteDrop.Target?
    @Published var index: Int
    @Published var images: [String: NSImage] = [:]
    @Published var errors: [String: String] = [:]
    private var task: Task<Void, Never>?

    init(paths: [String], index: Int, target: RemoteDrop.Target?) {
        self.paths = paths
        self.index = index
        self.target = target
    }

    var path: String { paths[index] }

    func step(_ delta: Int) {
        let next = index + delta
        guard paths.indices.contains(next) else { return }
        withAnimation(.easeOut(duration: 0.15)) { index = next }
    }

    /// Loads the selected image first, then the rest for the filmstrip.
    func start() {
        let order = [path] + paths.filter { $0 != path }
        task = Task { @MainActor [weak self] in
            for path in order {
                guard let self, !Task.isCancelled else { return }
                switch await ImageViewer.load(path, from: self.target) {
                case .success(let image): self.images[path] = image
                case .failure(let error): self.errors[path] = error.message
                }
            }
        }
    }

    func stop() { task?.cancel() }
}

/// Open viewers per surface.
final class ImageViewerState: ObservableObject {
    static let shared = ImageViewerState()
    @Published var models: [UUID: ImageViewerModel] = [:]

    func open(_ model: ImageViewerModel, on surface: UUID) {
        models[surface]?.stop()
        model.start()
        withAnimation(.easeOut(duration: 0.18)) { models[surface] = model }
    }

    func close(_ surface: UUID) {
        models[surface]?.stop()
        withAnimation(.easeIn(duration: 0.15)) { models[surface] = nil }
    }
}

extension Ghostty.SurfaceView {
    /// Opens the viewer for an image path. Returns false to let the URL open
    /// the upstream way.
    func openImageViewer(_ action: Ghostty.Action.OpenURL) -> Bool {
        // OSC 8 targets come from the program, so only take web images from
        // them (we just download and show those, never open them).
        guard action.kind != .osc8 || ImageViewer.webURL(action.url) != nil,
              let appDelegate = NSApp.delegate as? AppDelegate,
              appDelegate.ghostty.config.macosImageViewer else { return false }

        var clicked = action.url
        if let url = URL(string: clicked), url.scheme == "file" { clicked = url.path }
        guard ImageViewer.isImage(clicked) else { return false }

        // Core calls this with the renderer lock held, and reading the
        // screen takes that lock: do the rest once the call has returned.
        DispatchQueue.main.async { [weak self] in
            self?.showImageViewer(clicked)
        }
        return true
    }

    private func showImageViewer(_ clicked: String) {
        let target = surfaceModel?.foregroundPID.flatMap { RemoteDrop.target(pid: $0) }

        // The filmstrip: image paths on screen, newest last, with the click in it.
        var paths = ImageViewer.imagePaths(in: cachedScreenContents.get())
        if !paths.contains(clicked) { paths.append(clicked) }
        if paths.count > ImageViewer.maxItems {
            paths = Array(paths.suffix(ImageViewer.maxItems))
            if !paths.contains(clicked) { paths[0] = clicked }
        }
        let index = paths.firstIndex(of: clicked) ?? 0

        ImageViewerState.shared.open(
            ImageViewerModel(paths: paths, index: index, target: target),
            on: id)
    }

    /// Keys while the viewer is open: arrows move, Esc or space close.
    func handleImageViewerKey(_ event: NSEvent) -> Bool {
        let state = ImageViewerState.shared
        guard let model = state.models[id] else { return false }
        switch event.keyCode {
        case 53, 49: state.close(id)          // esc, space
        case 123, 126: model.step(-1)         // left, up
        case 124, 125: model.step(1)          // right, down
        default: break
        }
        return true
    }
}

/// The viewer drawn over a surface.
struct ImageViewerOverlay: View {
    let surfaceID: UUID
    @ObservedObject private var state = ImageViewerState.shared

    var body: some View {
        if let model = state.models[surfaceID] {
            ImageViewerContent(model: model) { state.close(surfaceID) }
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
        }
    }
}

private struct ImageViewerContent: View {
    @ObservedObject var model: ImageViewerModel
    let close: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.82)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: close)

            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    navButton("chevron.left", enabled: model.index > 0) { model.step(-1) }
                    mainImage
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    navButton("chevron.right", enabled: model.index < model.paths.count - 1) { model.step(1) }
                }

                caption

                if model.paths.count > 1 {
                    filmstrip
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 44)
            .padding(.bottom, 18)

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
    }

    @ViewBuilder
    private var mainImage: some View {
        if let image = model.images[model.path] {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
                .id(model.path)
                .transition(.opacity)
        } else if let error = model.errors[model.path] {
            placeholder("exclamationmark.triangle", error)
        } else {
            placeholder("photo", "Loading from \(ImageViewer.source(of: model.path, target: model.target))…")
        }
    }

    private func placeholder(_ symbol: String, _ text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 34, weight: .light))
            Text(text).font(.system(size: 12)).multilineTextAlignment(.center).lineLimit(3)
        }
        .foregroundStyle(.white.opacity(0.6))
        .frame(maxWidth: 360)
    }

    private var caption: some View {
        HStack(spacing: 6) {
            Text((model.path as NSString).lastPathComponent)
                .fontWeight(.semibold)
                .foregroundStyle(.white.opacity(0.92))
            if let image = model.images[model.path], let rep = image.representations.first {
                Text("·")
                Text("\(rep.pixelsWide)×\(rep.pixelsHigh)")
            }
            Text("·")
            Text(ImageViewer.source(of: model.path, target: model.target))
            if model.paths.count > 1 {
                Text("·")
                Text("\(model.index + 1)/\(model.paths.count)")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.white.opacity(0.55))
        .lineLimit(1)
        .truncationMode(.middle)
        .monospacedDigit()
        .help(model.path)
    }

    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(model.paths.enumerated()), id: \.offset) { i, path in
                        thumbnail(path, selected: i == model.index)
                            .id(i)
                            .onTapGesture {
                                withAnimation(.easeOut(duration: 0.15)) { model.index = i }
                            }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            }
            .frame(height: 76)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(0.06))
            )
            .onAppear { proxy.scrollTo(model.index, anchor: .center) }
            .onChange(of: model.index) { i in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(i, anchor: .center) }
            }
        }
        .frame(maxWidth: 760)
    }

    private func thumbnail(_ path: String, selected: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.white.opacity(0.08))
            if let image = model.images[path] {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFill()
            } else {
                Image(systemName: model.errors[path] == nil ? "photo" : "exclamationmark.triangle")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : .white.opacity(0.1), lineWidth: selected ? 2.5 : 1)
        )
        .scaleEffect(selected ? 1.0 : 0.92)
        .opacity(selected ? 1 : 0.7)
        .animation(.easeOut(duration: 0.15), value: selected)
        .help(path)
    }

    private func navButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white.opacity(enabled ? 0.85 : 0.2))
                .frame(width: 36, height: 56)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.white.opacity(enabled ? 0.1 : 0.03))
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(model.paths.count > 1 ? 1 : 0)
    }
}
