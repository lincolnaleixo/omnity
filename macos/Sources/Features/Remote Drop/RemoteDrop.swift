import AppKit
import Darwin

/// Omnity: when a file is dropped, or an image pasted, into a surface whose
/// foreground process is `ssh <host>`, upload it to `~/uploads` on that host
/// and type the remote path instead of the local one.
///
/// Enabled with `macos-remote-drop = true`. Uploads go through the user's own
/// ssh config, so `ControlMaster auto` + `ControlPersist` makes them instant.
enum RemoteDrop {
    static let remoteDir = "uploads"
    static let timeout: TimeInterval = 30

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
    static func upload(_ files: [URL], to target: Target) async -> Result<[String], RemoteDropError> {
        var paths: [String] = []
        for file in files {
            let name = remoteName(for: file)
            let command = "mkdir -p \(remoteDir) && cat > \(remoteDir)/\(name)"
            let args = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
                + target.options + [target.destination, command]
            if let error = await run("/usr/bin/ssh", args, stdin: file) {
                return .failure(RemoteDropError(message: error))
            }
            paths.append("~/\(remoteDir)/\(name)")
        }
        return .success(paths)
    }

    /// Runs a process with a timeout; returns nil on success or an error message.
    private static func run(_ path: String, _ args: [String], stdin: URL) async -> String? {
        await withCheckedContinuation { cont in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
            let stderr = Pipe()
            process.standardError = stderr
            process.standardOutput = FileHandle.nullDevice
            do {
                process.standardInput = try FileHandle(forReadingFrom: stdin)
            } catch {
                cont.resume(returning: error.localizedDescription)
                return
            }

            var timedOut = false
            let timer = DispatchWorkItem {
                timedOut = true
                process.terminate()
            }
            process.terminationHandler = { p in
                timer.cancel()
                if p.terminationStatus == 0 {
                    cont.resume(returning: nil)
                    return
                }
                let data = stderr.fileHandleForReading.readDataToEndOfFile()
                let message = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                cont.resume(returning: timedOut
                    ? "timed out after \(Int(timeout))s"
                    : (message.isEmpty ? "ssh exited with \(p.terminationStatus)" : message))
            }

            do {
                try process.run()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
            } catch {
                cont.resume(returning: error.localizedDescription)
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
            .appendingPathComponent("paste-\(UUID().uuidString.prefix(8)).png")
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

    /// Uploads dropped files if this surface is remote. Returns false when the
    /// drop should be handled the upstream way.
    func remoteDrop(_ pasteboard: NSPasteboard) -> Bool {
        guard let urls = pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty,
              let target = remoteDropTarget else { return false }

        let fallback = pasteboard.getOpinionatedStringContents()
        remoteUpload(urls, to: target, fallback: fallback)
        return true
    }

    /// Uploads a pasted image if this surface is remote and the pasteboard
    /// holds an image but no text. Returns true if it took the paste.
    func remotePasteImage(_ pasteboard: NSPasteboard) -> Bool {
        guard let target = remoteDropTarget,
              let file = RemoteDrop.imageFile(from: pasteboard) else { return false }

        remoteUpload([file], to: target, fallback: nil) {
            try? FileManager.default.removeItem(at: file)
        }
        return true
    }

    private func remoteUpload(
        _ files: [URL],
        to target: RemoteDrop.Target,
        fallback: String?,
        cleanup: @escaping () -> Void = {}
    ) {
        Task { @MainActor [weak self] in
            let result = await RemoteDrop.upload(files, to: target)
            cleanup()
            guard let self else { return }
            switch result {
            case .success(let paths):
                self.surfaceModel?.sendText(paths.joined(separator: " "))
            case .failure(let error):
                self.showUserNotification(
                    title: "Upload to \(target.destination) failed",
                    body: error.message,
                    requireFocus: false)
                if let fallback {
                    self.surfaceModel?.sendText(fallback)
                }
            }
        }
    }
}
