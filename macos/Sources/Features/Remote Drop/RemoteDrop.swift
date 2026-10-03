import AppKit
import SwiftUI
import Darwin

/// Omnity: when a file is dropped, or an image pasted, into a surface whose
/// foreground process is `ssh <host>`, upload it to `~/uploads` on that host
/// and type the remote path instead of the local one.
///
/// Enabled with `macos-remote-drop = true`. Uploads go through the user's own
/// ssh config, so `ControlMaster auto` + `ControlPersist` makes them instant.
enum RemoteDrop {
    static let remoteDir = "uploads"

    struct Target: Equatable {
        /// Options from the original command that matter for a new connection.
        var options: [String]
        var destination: String
    }

    /// Parses an ssh argv into its destination, or nil if it is not ssh.
    static func target(argv: [String]) -> Target? {
        guard let first = argv.first,
              (first as NSString).lastPathComponent == "ssh" else { return nil }

        // Options that take an argument, from ssh(1).
        let withArg = Set("BbcDEeFIiJLlmOoPpQRSWw")
        // Of those, the ones we pass on to the upload connection.
        let keep = Set("FiJlop")

        var options: [String] = []
        var i = 1
        while i < argv.count {
            let arg = argv[i]
            if arg == "--" { i += 1; break }
            guard arg.hasPrefix("-"), arg.count > 1 else { break }

            // Flags can be combined (-tt) and values attached (-p2222).
            let flags = Array(arg.dropFirst())
            guard let j = flags.firstIndex(where: { withArg.contains($0) }) else {
                i += 1
                continue
            }
            let flag = flags[j]
            let attached = String(flags[(j + 1)...])
            let value: String
            if attached.isEmpty {
                guard i + 1 < argv.count else { return nil }
                value = argv[i + 1]
                i += 2
            } else {
                value = attached
                i += 1
            }
            if keep.contains(flag) { options += ["-\(flag)", value] }
        }

        guard i < argv.count else { return nil }
        return Target(options: options, destination: argv[i])
    }

    /// Returns the ssh target of a process, or nil if it is not ssh.
    static func target(pid: Int) -> Target? {
        guard let argv = processArgs(pid: pid) else { return nil }
        return target(argv: argv)
    }

    /// Reads a process's argv with sysctl(KERN_PROCARGS2).
    static func processArgs(pid: Int) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, Int32(pid)]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return nil }

        // Layout: argc (Int32), executable path, NUL padding, then argv.
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var idx = 4
        while idx < size && buf[idx] != 0 { idx += 1 }
        while idx < size && buf[idx] == 0 { idx += 1 }

        var args: [String] = []
        while args.count < argc && idx < size {
            let start = idx
            while idx < size && buf[idx] != 0 { idx += 1 }
            args.append(String(decoding: buf[start..<idx], as: UTF8.self))
            idx += 1
        }
        return args
    }

    /// A name that is safe to type unquoted in a remote shell.
    static func remoteName(for url: URL, date: Date = Date()) -> String {
        let stamp = Int(date.timeIntervalSince1970)
        let safe = url.lastPathComponent.map { c -> Character in
            c.isASCII && (c.isLetter || c.isNumber || "._-".contains(c)) ? c : "-"
        }
        return "\(stamp)-\(String(safe))"
    }

    /// Uploads files and returns their remote paths, or an error message.
    /// `progress` gets the fraction of bytes sent, from any thread.
    static func upload(
        _ files: [URL],
        to target: Target,
        progress: @escaping (Double) -> Void
    ) async -> Result<[String], RemoteDropError> {
        let sizes = files.map {
            Int64((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        let total = max(sizes.reduce(0, +), 1)
        var done: Int64 = 0

        var paths: [String] = []
        for (file, size) in zip(files, sizes) {
            let name = remoteName(for: file)
            let command = "mkdir -p \(remoteDir) && cat > \(remoteDir)/\(name)"
            // ssh drops a stalled connection after ~30s (3 x 10s keepalives).
            let args = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                        "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=3"]
                + target.options + [target.destination, command]
            let base = done
            let error = await run("/usr/bin/ssh", args, stdin: file) { sent in
                progress(Double(base + sent) / Double(total))
            }
            if let error { return .failure(RemoteDropError(message: error)) }
            done += size
            paths.append("~/\(remoteDir)/\(name)")
        }
        return .success(paths)
    }

    /// Runs a process, feeding it a file on stdin in chunks so we can report
    /// bytes sent. Returns nil on success or an error message.
    private static func run(
        _ path: String,
        _ args: [String],
        stdin file: URL,
        sent: @escaping (Int64) -> Void
    ) async -> String? {
        await withCheckedContinuation { cont in
            let input: FileHandle
            do {
                input = try FileHandle(forReadingFrom: file)
            } catch {
                cont.resume(returning: error.localizedDescription)
                return
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
            let stdin = Pipe()
            let stderr = Pipe()
            process.standardInput = stdin
            process.standardError = stderr
            process.standardOutput = FileHandle.nullDevice
            // A write after ssh exits must fail with EPIPE, not kill the app.
            _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

            process.terminationHandler = { p in
                if p.terminationStatus == 0 {
                    cont.resume(returning: nil)
                    return
                }
                let data = stderr.fileHandleForReading.readDataToEndOfFile()
                let message = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                cont.resume(returning: message.isEmpty
                    ? "ssh exited with \(p.terminationStatus)" : message)
            }

            do {
                try process.run()
            } catch {
                cont.resume(returning: error.localizedDescription)
                return
            }

            DispatchQueue.global(qos: .userInitiated).async {
                let writer = stdin.fileHandleForWriting
                var count: Int64 = 0
                while let chunk = try? input.read(upToCount: 64 * 1024), !chunk.isEmpty {
                    do { try writer.write(contentsOf: chunk) } catch { break }
                    count += Int64(chunk.count)
                    sent(count)
                }
                try? input.close()
                try? writer.close()
            }
        }
    }

    /// Writes the pasteboard image, if any, to a temporary PNG file.
    static func imageFile(from pasteboard: NSPasteboard) -> URL? {
        let png: Data
        if let data = pasteboard.data(forType: .png) {
            png = data
        } else if let tiff = pasteboard.data(forType: .tiff),
                  let rep = NSBitmapImageRep(data: tiff),
                  let data = rep.representation(using: .png, properties: [:]) {
            png = data
        } else {
            return nil
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("image-\(UUID().uuidString.prefix(8)).png")
        do {
            try png.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}

struct RemoteDropError: Error {
    let message: String
}

extension Ghostty.SurfaceView {
    /// The ssh target of this surface when remote drop is enabled and the
    /// foreground process is ssh; nil means "behave like upstream".
    var remoteDropTarget: RemoteDrop.Target? {
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              appDelegate.ghostty.config.macosRemoteDrop,
              let pid = surfaceModel?.foregroundPID else { return nil }
        return RemoteDrop.target(pid: pid)
    }

    /// Uploads dropped files, promised files (Photos, Mail) or image data
    /// (browsers) if this surface is remote. Returns false when the drop
    /// should be handled the upstream way.
    func remoteDrop(_ pasteboard: NSPasteboard) -> Bool {
        guard let target = remoteDropTarget else { return false }
        return remoteUploadFiles(pasteboard, to: target)
            || remoteUploadPromises(pasteboard, to: target)
            || remoteUploadImage(pasteboard, to: target)
    }

    /// Uploads pasted files (e.g. a CleanShot or Finder copy), or a pasted
    /// image when there is no text, if this surface is remote. Returns true
    /// if it took the paste.
    func remotePaste(_ pasteboard: NSPasteboard) -> Bool {
        guard let target = remoteDropTarget else { return false }
        if remoteUploadFiles(pasteboard, to: target) { return true }
        return pasteboard.string(forType: .string) == nil
            && remoteUploadImage(pasteboard, to: target)
    }

    private func remoteUploadFiles(_ pasteboard: NSPasteboard, to target: RemoteDrop.Target) -> Bool {
        guard let urls = pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }

        remoteUpload(urls, to: target, fallback: pasteboard.getOpinionatedStringContents())
        return true
    }

    private func remoteUploadImage(_ pasteboard: NSPasteboard, to target: RemoteDrop.Target) -> Bool {
        guard let file = RemoteDrop.imageFile(from: pasteboard) else { return false }

        remoteUpload([file], to: target, fallback: nil) {
            try? FileManager.default.removeItem(at: file)
        }
        return true
    }

    /// Files that the source app writes only once dropped (Photos, Mail).
    private func remoteUploadPromises(_ pasteboard: NSPasteboard, to target: RemoteDrop.Target) -> Bool {
        guard let receivers = pasteboard.readObjects(
                forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
              !receivers.isEmpty else { return false }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("omnity-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cleanup = { try? FileManager.default.removeItem(at: dir) }

        // One callback per promised file; wait for all of them, then upload.
        let group = DispatchGroup()
        var files: [URL] = []
        for receiver in receivers {
            let expected = max(receiver.fileNames.count, 1)
            var received = 0
            group.enter()
            receiver.receivePromisedFiles(atDestination: dir, options: [:], operationQueue: .main) { url, error in
                if error == nil { files.append(url) }
                received += 1
                if received == expected { group.leave() }
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self, !files.isEmpty else { _ = cleanup(); return }
            self.remoteUpload(files, to: target, fallback: nil) { _ = cleanup() }
        }
        return true
    }

    private func remoteUpload(
        _ files: [URL],
        to target: RemoteDrop.Target,
        fallback: String?,
        cleanup: @escaping () -> Void = {}
    ) {
        let status = RemoteDropStatus.shared
        let name = files.count == 1 ? files[0].lastPathComponent : "\(files.count) files"
        let token = status.start(surface: id, name: name, host: target.destination)

        Task { @MainActor [weak self] in
            let result = await RemoteDrop.upload(files, to: target) { fraction in
                DispatchQueue.main.async { status.update(token, fraction: fraction) }
            }
            cleanup()
            switch result {
            case .success(let paths):
                status.finish(token, error: nil)
                self?.surfaceModel?.sendText(paths.joined(separator: " "))
            case .failure(let error):
                status.finish(token, error: error.message)
                if let fallback {
                    self?.surfaceModel?.sendText(fallback)
                }
            }
        }
    }
}

/// Upload progress per surface, shown by `RemoteDropBadge`.
final class RemoteDropStatus: ObservableObject {
    static let shared = RemoteDropStatus()

    enum State: Equatable {
        case uploading
        case done
        case failed(String)
    }

    struct Upload: Equatable {
        let token: UUID
        let name: String
        let host: String
        var fraction: Double = 0
        var state: State = .uploading
    }

    @Published private(set) var uploads: [UUID: Upload] = [:]

    func start(surface: UUID, name: String, host: String) -> (UUID, UUID) {
        let token = UUID()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            uploads[surface] = Upload(token: token, name: name, host: host)
        }
        return (surface, token)
    }

    func update(_ key: (UUID, UUID), fraction: Double) {
        guard uploads[key.0]?.token == key.1 else { return }
        uploads[key.0]?.fraction = min(fraction, 1)
    }

    func finish(_ key: (UUID, UUID), error: String?) {
        guard uploads[key.0]?.token == key.1 else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            uploads[key.0]?.fraction = 1
            uploads[key.0]?.state = error.map { .failed($0) } ?? .done
        }
        // Linger a moment on success, longer on error so it can be read.
        DispatchQueue.main.asyncAfter(deadline: .now() + (error == nil ? 1.2 : 5)) {
            guard self.uploads[key.0]?.token == key.1 else { return }
            withAnimation(.easeIn(duration: 0.25)) {
                self.uploads[key.0] = nil
            }
        }
    }
}

/// A floating pill in the bottom-right corner of a surface with the upload's
/// name, a progress bar and the percentage.
struct RemoteDropBadge: View {
    let surfaceID: UUID
    @ObservedObject private var status = RemoteDropStatus.shared

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let upload = status.uploads[surfaceID] {
                pill(upload)
                    .padding(14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .allowsHitTesting(false)
    }

    private func pill(_ upload: RemoteDropStatus.Upload) -> some View {
        HStack(spacing: 10) {
            icon(upload.state)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(title(upload))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Text(trailing(upload))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12, weight: .medium))

                bar(upload)
            }
            .frame(width: 230)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    }

    @ViewBuilder
    private func icon(_ state: RemoteDropStatus.State) -> some View {
        switch state {
        case .uploading:
            Image(systemName: "arrow.up.circle.fill").foregroundStyle(Color.accentColor)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    private func bar(_ upload: RemoteDropStatus.Upload) -> some View {
        let tint: Color = switch upload.state {
        case .uploading: .accentColor
        case .done: .green
        case .failed: .red
        }
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(LinearGradient(
                        colors: [tint.opacity(0.75), tint],
                        startPoint: .leading,
                        endPoint: .trailing))
                    .frame(width: max(geo.size.width * upload.fraction, 4))
                    .animation(.easeOut(duration: 0.15), value: upload.fraction)
            }
        }
        .frame(height: 5)
    }

    private func title(_ upload: RemoteDropStatus.Upload) -> String {
        switch upload.state {
        case .uploading: return "\(upload.name) → \(upload.host)"
        case .done: return "Uploaded to \(upload.host)"
        case .failed(let message): return message
        }
    }

    private func trailing(_ upload: RemoteDropStatus.Upload) -> String {
        switch upload.state {
        case .uploading: return "\(Int(upload.fraction * 100))%"
        case .done: return "100%"
        case .failed: return "Failed"
        }
    }
}
