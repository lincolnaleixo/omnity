import AppKit
import Combine
import SwiftUI
/// Omnity: host stats (CPU, memory, disk of the switcher host) at the right end of the session tab bar.
/// One command per tick over the switcher's ssh connection (`TmuxSwitchClient.execute`), nothing installed on
/// the host. CPU and memory every 5 s, disk and the top process every 60 s; paused while Omnity is in the
/// background. `OMNITY_HOST_STATS_FIXTURE=<file>` reads the command's output from a file (tests, screenshots).

// MARK: - Parsing

enum HostLevel: Equatable { case ok, warn, bad }

struct HostStatsSample: Equatable {
    var cpuBusy: UInt64 = 0, cpuTotal: UInt64 = 0
    var memTotalKB: UInt64 = 0, memAvailKB: UInt64 = 0
    var load: String = ""
    var cores: Int = 0
    var disk: HostDisk?
    var top: String?
}

struct HostDisk: Equatable {
    var used: UInt64, total: UInt64, free: UInt64
    var percent: Int { total == 0 ? 0 : Int((Double(used) / Double(used + free) * 100).rounded(.up)) }
}

enum HostStatsParser {
    /// The one remote command: CPU, memory, load, cores; with `disk` also `df` and the top process after `---`.
    static func command(disk: Bool) -> String {
        var c = "head -1 /proc/stat; grep -E '^(MemTotal|MemAvailable):' /proc/meminfo; cat /proc/loadavg; nproc"
        if disk { c += "; echo ---; df -B1 /; ps -eo comm,%cpu --sort=-%cpu | sed -n 2p" }
        return c
    }

    /// `cpu  user nice system idle iowait irq softirq steal ...` -> (busy, total) ticks; idle = idle + iowait.
    static func cpu(_ line: String) -> (busy: UInt64, total: UInt64)? {
        let f = line.split(separator: " ", omittingEmptySubsequences: true)
        guard f.first == "cpu", f.count >= 5 else { return nil }
        let n = f.dropFirst().prefix(8).compactMap { UInt64($0) }
        guard n.count == f.dropFirst().prefix(8).count else { return nil }
        let total = n.reduce(0, +)
        let idle = n[3] + (n.count > 4 ? n[4] : 0)
        return (total - min(idle, total), total)
    }

    /// `MemTotal:  24000000 kB` -> 24000000.
    static func kb(_ line: String) -> UInt64? {
        let f = line.split(separator: " ", omittingEmptySubsequences: true)
        return f.count >= 2 ? UInt64(f[1]) : nil
    }

    /// `df -B1 /`: the last line `Filesystem 1B-blocks Used Available Use% Mounted on`.
    static func df(_ text: String) -> HostDisk? {
        guard let line = text.split(separator: "\n").last else { return nil }
        let f = line.split(separator: " ", omittingEmptySubsequences: true)
        guard f.count >= 6, let total = UInt64(f[1]), let used = UInt64(f[2]), let free = UInt64(f[3]), total > 0 else { return nil }
        return HostDisk(used: used, total: total, free: free)
    }

    /// `node 12.3` -> "node 12%". The name may hold spaces: the last word is the CPU.
    static func top(_ line: String) -> String? {
        let f = line.split(separator: " ", omittingEmptySubsequences: true)
        guard f.count >= 2, let v = Double(f[f.count - 1]) else { return nil }
        return "\(f.dropLast().joined(separator: " ")) \(Int(v.rounded()))%"
    }

    static func parse(_ output: String) -> HostStatsSample? {
        let parts = output.components(separatedBy: "\n---\n")
        var s = HostStatsSample()
        var gotCPU = false
        for line in parts[0].split(separator: "\n").map(String.init) {
            if line.hasPrefix("cpu "), let c = cpu(line) { s.cpuBusy = c.busy; s.cpuTotal = c.total; gotCPU = true }
            else if line.hasPrefix("MemTotal:") { s.memTotalKB = kb(line) ?? 0 }
            else if line.hasPrefix("MemAvailable:") { s.memAvailKB = kb(line) ?? 0 }
            else if line.split(separator: " ").count >= 4, line.contains("/") { s.load = line.split(separator: " ").prefix(3).joined(separator: " ") }
            else if let n = Int(line.trimmingCharacters(in: .whitespaces)) { s.cores = n }
        }
        guard gotCPU, s.memTotalKB > 0 else { return nil }
        if parts.count > 1 {
            // Each line on its own: a missing or odd `ps` line must not cost the disk (a stale DISK stayed on screen).
            for line in parts[1].split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
                if let d = df(line) { s.disk = d } else if let t = top(line) { s.top = t }
            }
        }
        return s
    }

    /// Amber from 80%, red from 90%.
    static func level(_ percent: Int) -> HostLevel { percent >= 90 ? .bad : percent >= 80 ? .warn : .ok }

    static func cpuPercent(from a: HostStatsSample, to b: HostStatsSample) -> Int? {
        guard b.cpuTotal > a.cpuTotal else { return nil }
        let busy = Double(b.cpuBusy &- min(a.cpuBusy, b.cpuBusy)), total = Double(b.cpuTotal - a.cpuTotal)
        return min(100, Int((busy / total * 100).rounded()))
    }

    static func gb(_ bytes: UInt64) -> String { String(format: "%.1f", Double(bytes) / 1_073_741_824) }
}

/// The last disk reading. Disk is read every 60 s; one older than `maxAge` is dropped, never shown as current.
struct HostDiskCache {
    static let every: TimeInterval = 60, maxAge: TimeInterval = 180
    private var disk: HostDisk?, top: String?
    private var at = Date.distantPast
    func due(_ now: Date) -> Bool { now.timeIntervalSince(at) >= Self.every }
    mutating func update(_ s: HostStatsSample, now: Date) {
        guard let d = s.disk else { return }
        disk = d; top = s.top; at = now
    }
    func current(_ now: Date) -> (disk: HostDisk?, top: String?) {
        now.timeIntervalSince(at) <= Self.maxAge ? (disk, top) : (nil, nil)
    }
}
// MARK: - Display state

/// What the bar shows. Equatable so an unchanged tick publishes nothing.
struct HostStatsState: Equatable {
    var fresh = false
    var cpu: Int?
    var memUsedKB: UInt64 = 0, memTotalKB: UInt64 = 0
    var load = "", cores = 0
    var disk: HostDisk?
    var top: String?

    var memPercent: Int { memTotalKB == 0 ? 0 : Int((Double(memUsedKB) / Double(memTotalKB) * 100).rounded()) }
    var memText: String { HostStatsParser.gb(memUsedKB * 1024) + "G" }
    var tooltip: String {
        var t = ["Load \(load)  (\(cores) cores)",
                 "Memory \(HostStatsParser.gb(memUsedKB * 1024)) / \(HostStatsParser.gb(memTotalKB * 1024)) GB"]
        if let d = disk {
            t.append("Disk \(HostStatsParser.gb(d.used)) / \(HostStatsParser.gb(d.total)) GB, \(HostStatsParser.gb(d.free)) GB free")
        }
        if let top { t.append("Top: \(top)") }
        return t.joined(separator: "\n")
    }
}

// MARK: - Controller

final class HostStats: ObservableObject {
    static let shared = HostStats()
    @Published private(set) var state = HostStatsState()
    private var timer: Timer?
    private var prev: HostStatsSample?
    private var diskCache = HostDiskCache()
    private var inFlight = false

    func install() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.tick() }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.tick() }
    }

    /// Reads once if Omnity is the active app and a tab bar is on screen.
    func tick() {
        guard NSApp.isActive, SessionTabs.shared.bars > 0, !inFlight else { return }
        let host = SessionTabs.shared.host
        guard !host.isEmpty else { return }
        inFlight = true
        let withDisk = diskCache.due(Date())
        Task {
            var out = await read(host: host, disk: withDisk)
            // The first sample has nothing to compare with: take a second one right away.
            if let first = out, self.prev == nil {
                self.prev = first
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                out = await read(host: host, disk: false)
                out?.disk = first.disk; out?.top = first.top   // keep the disk of the first read
            }
            await MainActor.run { self.apply(out) }
        }
    }

    private func read(host: String, disk: Bool) async -> HostStatsSample? {
        if let path = ProcessInfo.processInfo.environment["OMNITY_HOST_STATS_FIXTURE"] {
            return (try? String(contentsOfFile: path, encoding: .utf8)).flatMap(HostStatsParser.parse)
        }
        guard let r = await TmuxSwitchClient.execute(host: host, [], command: HostStatsParser.command(disk: disk)),
              r.status == 0 else { return nil }
        return HostStatsParser.parse(String(decoding: r.out, as: UTF8.self))
    }

    private func apply(_ s: HostStatsSample?) {
        inFlight = false
        var next = state
        let now = Date()
        if let s {
            diskCache.update(s, now: now)
            let (disk, top) = diskCache.current(now)
            next = HostStatsState(
                fresh: true, cpu: prev.flatMap { HostStatsParser.cpuPercent(from: $0, to: s) } ?? state.cpu,
                memUsedKB: s.memTotalKB - min(s.memAvailKB, s.memTotalKB), memTotalKB: s.memTotalKB,
                load: s.load, cores: s.cores, disk: disk, top: top)
            prev = s
        } else {
            next.fresh = false
            (next.disk, next.top) = diskCache.current(now)
        }
        if next != state { state = next }
    }
}

// MARK: - View

struct HostStatsView: View {
    @ObservedObject private var stats = HostStats.shared
    let host: String
    let palette: SessionTabsPalette
    let labels: Bool

    /// Whether the stats fit in room points beside the tabs: with labels, without, or not at all (nil).
    static func fit(room: CGFloat) -> Bool? { room >= 400 ? true : room >= 270 ? false : nil }

    var body: some View {
        let s = stats.state
        HStack(spacing: 14) {
            HStack(spacing: 5) {
                Circle().fill(s.fresh ? Color(red: 0x7f / 255, green: 0xc9 / 255, blue: 0x7f / 255) : palette.ink(0.3))
                    .frame(width: 6, height: 6)
                Text(host)
            }
            metric("CPU", s.cpu.map { "\($0)%" } ?? "\u{2013}", percent: s.cpu)
            metric("MEM", s.memText, percent: s.memTotalKB == 0 ? nil : s.memPercent)
            if let d = s.disk { metric("DISK", "\(d.percent)%", percent: d.percent) }
        }
        .font(.system(size: 12, design: .monospaced))
        .foregroundColor(palette.ink(0.5))
        .lineLimit(1)
        .fixedSize()
        .help(s.tooltip)
    }

    private func metric(_ label: String, _ value: String, percent: Int?) -> some View {
        let level = percent.map(HostStatsParser.level) ?? .ok
        let color: Color = level == .bad ? Color(red: 0xef / 255, green: 0x6b / 255, blue: 0x73 / 255)
            : level == .warn ? Color(red: 0xe6 / 255, green: 0xb4 / 255, blue: 0x50 / 255) : palette.ink(0.55)
        return HStack(spacing: 6) {
            if labels { Text(label) }
            ZStack(alignment: .leading) {
                Capsule().fill(palette.ink(0.15))
                Capsule().fill(color).frame(width: 34 * CGFloat(min(max(percent ?? 0, 0), 100)) / 100)
            }
            .frame(width: 34, height: 4)
            Text(value).foregroundColor(level == .ok ? palette.ink(0.85) : color)
        }
    }
}
