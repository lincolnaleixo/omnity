import AppKit
import AVFoundation
import SwiftUI
import WhisperKit
import os

/// Omnity: hold the right Option key, speak, release: the speech is
/// transcribed on device with Whisper (WhisperKit) and typed into the
/// focused surface as a paste.
///
/// Enabled with `macos-dictation = true`. The model is picked for the chip,
/// downloaded once to ~/Library/Application Support/Omnity/whisper and kept
/// loaded.
final class Dictation: ObservableObject {
    static let shared = Dictation()
    static let log = Logger(subsystem: "com.lincolnaleixo.omnity", category: "dictation")

    static let rightOptionKeyCode: UInt16 = 61
    /// Words Whisper should spell this way; it biases the decoder toward them.
    static let vocabulary = """
        Omnity, omni, tmux, ssh, Claude Code, Codex, Ghostty, git, commit, push, \
        deploy, LXC, Tailscale, Termius, LongLifeNutri, Tally.
        """
    /// Whisper's known output on silence in Portuguese.
    static let hallucinations = ["Legendas pela comunidade Amara.org", "Obrigado."]

    enum Phase: Equatable {
        case idle
        case downloading(Double)
        case loading
        case ready
        case listening
        case transcribing
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var surfaceID: UUID?
    /// Recent microphone levels, 0...1, oldest first.
    @Published private(set) var levels: [Float] = Array(repeating: 0, count: 28)

    private weak var surface: Ghostty.SurfaceView?
    private var whisper: WhisperKit?
    private var loading: Task<WhisperKit, Error>?
    private var engine: AVAudioEngine?
    private let lock = NSLock()
    private var samples: [Float] = []
    private var startedAt = Date()
    private var monitor: Any?

    private var enabled: Bool {
        (NSApp.delegate as? AppDelegate)?.ghostty.config.macosDictation ?? false
    }

    /// Watches the right Option key and preloads the model.
    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            self?.handle(event)
            return event
        }
        if enabled {
            Task { _ = try? await self.model() }
        }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged where event.keyCode == Self.rightOptionKeyCode:
            if event.modifierFlags.contains(.option) {
                guard enabled else { return }
                guard let surface = NSApp.keyWindow?.firstResponder as? Ghostty.SurfaceView else {
                    Self.log.notice("right option: no focused terminal")
                    return
                }
                start(on: surface)
            } else {
                stop()
            }
        case .keyDown where phase == .listening:
            // Option was used as a modifier (e.g. option+arrow), not to dictate.
            cancel()
        default:
            break
        }
    }

    // MARK: Model

    /// Downloads the model the first time, then loads it, showing progress.
    @MainActor
    private func model() async throws -> WhisperKit {
        if let whisper { return whisper }
        if let loading { return try await loading.value }

        let task = Task { @MainActor () throws -> WhisperKit in
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Omnity/whisper")
            let variant = WhisperKit.recommendedModels().default
            var folder = base.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(variant)")

            // Downloaded before: load offline, without asking the hub.
            let downloaded = ["AudioEncoder", "TextDecoder", "MelSpectrogram"].allSatisfy {
                FileManager.default.fileExists(atPath: folder.appendingPathComponent("\($0).mlmodelc").path)
            }
            if !downloaded {
                self.setPhase(.downloading(0))
                folder = try await WhisperKit.download(variant: variant, downloadBase: base) { progress in
                    let fraction = progress.fractionCompleted
                    DispatchQueue.main.async {
                        if case .downloading = self.phase { self.phase = .downloading(fraction) }
                    }
                }
            }

            self.setPhase(.loading)
            let config = WhisperKitConfig(
                model: variant,
                modelFolder: folder.path,
                verbose: false,
                logLevel: .error,
                prewarm: true,
                load: true,
                download: false)
            return try await WhisperKit(config)
        }
        loading = task
        do {
            let whisper = try await task.value
            self.whisper = whisper
            setPhase(.ready)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if self.phase == .ready { self.setPhase(.idle) }
            }
            return whisper
        } catch {
            loading = nil
            fail("Speech model: \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: Recording

    private func start(on surface: Ghostty.SurfaceView) {
        guard phase == .idle || phase == .ready || phase.isFailed else {
            Self.log.notice("right option ignored while \(String(describing: self.phase), privacy: .public)")
            return
        }
        self.surface = surface
        surfaceID = surface.id

        guard whisper != nil else {
            // Not ready yet: model() shows the download and load progress.
            Task { _ = try? await self.model() }
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    self.fail(granted ? "Microphone allowed, hold right ⌥ again" : "Microphone not allowed")
                }
            }
            return
        default:
            fail("Allow the microphone for Omnity in System Settings › Privacy")
            return
        }

        do {
            try startEngine()
            startedAt = Date()
            levels = levels.map { _ in 0 }
            setPhase(.listening)
        } catch {
            fail("Microphone: \(error.localizedDescription)")
        }
    }

    private func startEngine() throws {
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()

        // A new engine each time follows the current default input (AirPods
        // connected since the last recording, etc.).
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: target) else {
            throw RemoteDropError(message: "no input device")
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16000 / format.sampleRate) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed {
                    status.pointee = .noDataNow
                    return nil
                }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, let data = out.floatChannelData?[0] else { return }
            self?.append(Array(UnsafeBufferPointer(start: data, count: Int(out.frameLength))))
        }
        engine.prepare()
        try engine.start()
    }

    /// Called on the audio thread.
    private func append(_ chunk: [Float]) {
        lock.lock(); samples.append(contentsOf: chunk); lock.unlock()
        guard !chunk.isEmpty else { return }
        let rms = sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count))
        let level = min(1, rms * 12)
        DispatchQueue.main.async {
            self.levels.removeFirst()
            self.levels.append(level)
        }
    }

    private func stopEngine() -> [Float] {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        lock.lock(); defer { lock.unlock() }
        return samples
    }

    private func cancel() {
        guard phase == .listening else { return }
        _ = stopEngine()
        setPhase(.idle)
    }

    private func stop() {
        guard phase == .listening else { return }
        let audio = stopEngine()

        // A tap of the key, not speech.
        guard Date().timeIntervalSince(startedAt) > 0.35, audio.count > 16000 / 3 else {
            setPhase(.idle)
            return
        }

        setPhase(.transcribing)
        Task {
            do {
                let text = try await self.transcribe(audio)
                await MainActor.run {
                    if !text.isEmpty { self.surface?.surfaceModel?.sendText(text) }
                    self.setPhase(.idle)
                }
            } catch {
                await MainActor.run { self.fail(error.localizedDescription) }
            }
        }
    }

    private func transcribe(_ audio: [Float]) async throws -> String {
        let whisper = try await model()
        var prompt: [Int]?
        if let tokenizer = whisper.tokenizer {
            prompt = tokenizer.encode(text: " " + Self.vocabulary)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        }
        let options = DecodingOptions(
            task: .transcribe,
            language: "pt",
            temperatureFallbackCount: 3,
            usePrefillPrompt: true,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            promptTokens: prompt,
            chunkingStrategy: .vad)
        let results = try await whisper.transcribe(audioArray: audio, decodeOptions: options)
        let text = results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.hallucinations.contains(text) ? "" : text
    }

    // MARK: State

    private func setPhase(_ phase: Phase) {
        if case .downloading = phase {} else {
            Self.log.notice("phase \(String(describing: phase), privacy: .public)")
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { self.phase = phase }
    }

    private func fail(_ message: String) {
        setPhase(.failed(message))
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if self.phase == .failed(message) { self.setPhase(.idle) }
        }
    }
}

private extension Dictation.Phase {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    /// Model setup is shown on every surface; the rest on the dictated one.
    var isSetup: Bool {
        switch self {
        case .downloading, .loading, .ready: return true
        default: return false
        }
    }
}

/// The dictation pill, bottom-center of the surface being dictated into.
struct DictationBadge: View {
    let surfaceID: UUID
    @ObservedObject private var dictation = Dictation.shared

    var body: some View {
        ZStack(alignment: .bottom) {
            if dictation.phase != .idle,
               dictation.phase.isSetup || dictation.surfaceID == nil || dictation.surfaceID == surfaceID {
                pill
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .allowsHitTesting(false)
    }

    private var pill: some View {
        HStack(spacing: 10) {
            icon
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 20)

            switch dictation.phase {
            case .listening:
                Waveform(levels: dictation.levels)
                    .frame(width: 150, height: 22)
                Text("Listening")
                if let mic = AVCaptureDevice.default(for: .audio)?.localizedName {
                    Text("· \(mic)").foregroundStyle(.secondary).lineLimit(1)
                }
            case .transcribing:
                TranscribingDots()
                Text("Transcribing")
            case .downloading(let fraction):
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Downloading speech model")
                        Spacer(minLength: 12)
                        Text("\(Int(fraction * 100))%").monospacedDigit().foregroundStyle(.secondary)
                    }
                    ProgressBar(fraction: fraction)
                }
                .frame(width: 260)
            case .loading:
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Loading speech model")
                        Spacer(minLength: 12)
                        Text("first time takes a minute").foregroundStyle(.secondary)
                    }
                    ProgressBar(fraction: nil)
                }
                .frame(width: 300)
            case .ready:
                Text("Speech ready · hold right ⌥ to talk")
            case .failed(let message):
                Text(message).lineLimit(2)
            case .idle:
                EmptyView()
            }
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .frame(maxWidth: 420)
    }

    @ViewBuilder
    private var icon: some View {
        switch dictation.phase {
        case .listening:
            Image(systemName: "mic.fill").foregroundStyle(.red)
        case .transcribing:
            Image(systemName: "waveform").foregroundStyle(Color.accentColor)
        case .downloading:
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
        case .loading:
            Image(systemName: "cpu").foregroundStyle(Color.accentColor)
        case .ready:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .idle:
            EmptyView()
        }
    }
}

/// A thin progress bar; nil fraction slides back and forth.
private struct ProgressBar: View {
    let fraction: Double?
    @State private var offset: CGFloat = -1

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                if let fraction {
                    Capsule()
                        .fill(LinearGradient(
                            colors: [Color.accentColor.opacity(0.75), Color.accentColor],
                            startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(geo.size.width * fraction, 4))
                        .animation(.easeOut(duration: 0.2), value: fraction)
                } else {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: geo.size.width * 0.3)
                        .offset(x: (offset + 1) / 2 * geo.size.width * 0.7)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                                offset = 1
                            }
                        }
                }
            }
        }
        .frame(height: 5)
    }
}

/// Live bars from the microphone level.
private struct Waveform: View {
    let levels: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(Color.red.opacity(0.85))
                    .frame(width: 3, height: max(3, CGFloat(level) * 22))
            }
        }
        .animation(.easeOut(duration: 0.08), value: levels)
    }
}

/// Three dots pulsing in turn while Whisper works.
private struct TranscribingDots: View {
    @State private var phase = 0
    private let timer = Timer.publish(every: 0.3, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
                    .opacity(phase == i ? 1 : 0.3)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: phase)
        .onReceive(timer) { _ in phase = (phase + 1) % 3 }
    }
}
