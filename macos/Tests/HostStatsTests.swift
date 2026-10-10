//
//  HostStatsTests.swift
//  GhosttyTests
//
//  Omnity: tests for the host stats in the session tab bar (parsing, thresholds).
//
import Testing
import Foundation
@testable import Ghostty

struct HostStatsTests {
    static let out = """
    cpu  1000 0 500 8000 500 0 0 0 0 0
    MemTotal:       24000000 kB
    MemAvailable:   18000000 kB
    0.52 0.40 0.31 2/345 6789
    4
    ---
    Filesystem      1B-blocks        Used   Available Use% Mounted on
    /dev/mapper/pve-root 42949672960 33822867456 9126805504  79% /
    node 12.3
    """

    @Test func cpuLine() throws {
        let c = try #require(HostStatsParser.cpu("cpu  1000 0 500 8000 500 0 0 0 0 0"))
        #expect(c.total == 10000)
        #expect(c.busy == 1500)
        #expect(HostStatsParser.cpu("cpu0 1 2 3 4 5") == nil)
        #expect(HostStatsParser.cpu("cpu  x y z") == nil)
    }

    @Test func cpuDelta() throws {
        let a = HostStatsSample(cpuBusy: 1500, cpuTotal: 10000)
        let b = HostStatsSample(cpuBusy: 1620, cpuTotal: 10400)
        #expect(HostStatsParser.cpuPercent(from: a, to: b) == 30)
        #expect(HostStatsParser.cpuPercent(from: b, to: b) == nil)
    }

    @Test func meminfo() {
        #expect(HostStatsParser.kb("MemTotal:       24000000 kB") == 24_000_000)
        #expect(HostStatsParser.kb("MemTotal:") == nil)
    }

    @Test func dfLine() throws {
        let d = try #require(HostStatsParser.df(
            "Filesystem 1B-blocks Used Available Use% Mounted on\n/dev/sda1 42949672960 33822867456 9126805504 79% /"))
        #expect(d.percent == 79)
        #expect(HostStatsParser.gb(d.free) == "8.5")
        #expect(HostStatsParser.df("garbage") == nil)
    }

    @Test func topProcess() {
        #expect(HostStatsParser.top("node 12.3") == "node 12%")
        #expect(HostStatsParser.top("Web Content 3.6") == "Web Content 4%")
        #expect(HostStatsParser.top("") == nil)
    }

    @Test func fullOutput() throws {
        let s = try #require(HostStatsParser.parse(Self.out))
        #expect(s.cores == 4)
        #expect(s.load == "0.52 0.40 0.31")
        #expect(s.memTotalKB == 24_000_000 && s.memAvailKB == 18_000_000)
        #expect(s.disk?.percent == 79)
        #expect(s.top == "node 12%")
        // Without the disk part (most ticks).
        let short = try #require(HostStatsParser.parse(Self.out.components(separatedBy: "\n---\n")[0]))
        #expect(short.disk == nil && short.top == nil)
        #expect(HostStatsParser.parse("nonsense") == nil)
    }

    @Test func diskSurvivesAMissingProcessLine() throws {
        // No `ps` line after df (it used to take the df line for it and lose the disk, leaving the old value on screen).
        let noTop = Self.out.replacingOccurrences(of: "\nnode 12.3", with: "")
        let s = try #require(HostStatsParser.parse(noTop))
        #expect(s.disk?.percent == 79 && s.top == nil)
    }
    @Test func diskCacheDropsAStaleReading() throws {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var c = HostDiskCache()
        #expect(c.due(t0) && c.current(t0).disk == nil)
        let s = try #require(HostStatsParser.parse(Self.out))
        c.update(s, now: t0)
        #expect(!c.due(t0.addingTimeInterval(59)) && c.due(t0.addingTimeInterval(60)))
        #expect(c.current(t0.addingTimeInterval(120)).disk?.percent == 79)
        // A newer reading replaces it; a sample without disk changes nothing.
        var fresh = s
        fresh.disk = HostDisk(used: 32_000_000_000, total: 64_000_000_000, free: 32_000_000_000)
        c.update(fresh, now: t0.addingTimeInterval(60))
        c.update(HostStatsSample(), now: t0.addingTimeInterval(65))
        #expect(c.current(t0.addingTimeInterval(70)).disk?.percent == 50)
        // Readings that stop arriving are dropped after maxAge, never shown as current.
        #expect(c.current(t0.addingTimeInterval(60 + HostDiskCache.maxAge + 1)).disk == nil)
    }
    @Test func thresholds() {
        #expect(HostStatsParser.level(79) == .ok)
        #expect(HostStatsParser.level(80) == .warn)
        #expect(HostStatsParser.level(89) == .warn)
        #expect(HostStatsParser.level(90) == .bad)
        #expect(HostStatsParser.level(100) == .bad)
    }

    @Test func fitsBesideTheTabs() {
        #expect(HostStatsView.fit(room: 500) == true)
        #expect(HostStatsView.fit(room: 300) == false)
        #expect(HostStatsView.fit(room: 100) == nil)
    }

    @Test func state() throws {
        var s = HostStatsState(fresh: true, cpu: 12, memUsedKB: 6_000_000, memTotalKB: 24_000_000, load: "0.5 0.4 0.3", cores: 4)
        #expect(s.memPercent == 25)
        #expect(s.memText == "5.7G")
        let same = s
        s.cpu = 13
        #expect(s != same)
    }
}
