//
//  PollingTests.swift
//  prefabLogicTests — failed-only polling (PRD-1-01 plan § 15.18 R7-7, § 15.19 R8-6): PT-141 … PT-149.
//  Everything here is HomeKit-free: the ledger, planner, scheduler and coordinator run on fakes and an injected clock.
//

import XCTest

// MARK: - fakes

/// Collects log lines from any thread.
final class LineSink {
    private let lock = NSLock()
    private var _lines: [String] = []
    func append(_ s: String) { lock.lock(); _lines.append(s); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return _lines }
    func count(prefix: String) -> Int { lines.filter { $0.hasPrefix(prefix) }.count }
}

final class FakePollTimer: PollTimer {
    let interval: TimeInterval
    let fire: () -> Void
    private(set) var cancelled = false
    init(interval: TimeInterval, fire: @escaping () -> Void) { self.interval = interval; self.fire = fire }
    func cancel() { cancelled = true }
}

/// A coordinator wired to fakes: a manual clock, captured timers and deadlines, programmable reads.
final class CoordinatorHarness {
    let queue = DispatchQueue(label: "prefabLogicTests.polling")
    let sink = LineSink()
    var settings = PollSettings(enabled: true, rawLimit: nil, reportEvery: 60)
    var excludedAccessories: Set<String> = []
    var now: TimeInterval = 0
    private(set) var timers: [FakePollTimer] = []
    private(set) var deadlines: [() -> Void] = []
    private(set) var reads: [String] = []                       // characteristic ids, in start order
    var readResult: (Subscription) -> Int? = { _ in nil }       // nil = success, else the error code
    var completeReadsImmediately = true
    private(set) var pendingReadDones: [(String, (Int?) -> Void)] = []
    private(set) var reports = 0
    lazy var coordinator: PollingCoordinator = PollingCoordinator(
        queue: queue,
        settings: { [unowned self] in self.settings },
        include: { [unowned self] id, _ in !self.excludedAccessories.contains(id) },
        log: { [unowned self] in self.sink.append($0) },
        startRead: { [unowned self] sub, done in
            self.reads.append(sub.characteristicId)
            if self.completeReadsImmediately { done(self.readResult(sub)) } else { self.pendingReadDones.append((sub.characteristicId, done)) }
        },
        clock: { [unowned self] in self.now },
        makeTimer: { [unowned self] interval, fire in let t = FakePollTimer(interval: interval, fire: fire); self.timers.append(t); return t },
        scheduleAfter: { [unowned self] _, block in self.deadlines.append(block) },
        onReport: { [unowned self] _ in self.reports += 1 })

    func drain() { coordinator.drain() }
    var liveTimer: FakePollTimer? { timers.last.flatMap { $0.cancelled ? nil : $0 } }
    /// Fires the live timer at `t` and drains (the timer handler runs on the coordinator's queue in production).
    func tick(at t: TimeInterval) { now = t; if let tm = liveTimer { queue.sync { tm.fire() } }; drain() }
}

func sub(_ id: String, acc: String = "A1", bridge: String = "B1", name: String? = nil) -> Subscription {
    Subscription(characteristicId: id, accessoryId: acc, accessoryName: name ?? "Acc \(acc)", characteristicName: "Char \(id)", bridgeKey: bridge, state: .pending)
}

// MARK: - PT-141 … PT-149

final class PollingTests: XCTestCase {

    // PT-141 — the ledger counts every completion once; 60 s settles with pending
    func test_PT141_ledger_7ok_2failed_1pending_atTheDeadline() {
        var ledger = SubscriptionLedger()
        for i in 0..<10 { ledger.register(sub("C\(i)")) }
        XCTAssertNil(ledger.finishSetup(), "completions still missing")
        for i in 0..<7 { XCTAssertNil(ledger.complete(characteristicId: "C\(i)", errorCode: nil)) }
        XCTAssertNil(ledger.complete(characteristicId: "C7", errorCode: -70))
        XCTAssertNil(ledger.complete(characteristicId: "C8", errorCode: -70))
        XCTAssertEqual(ledger.deadlineReached(), .settled)
        XCTAssertEqual(ledger.counts, LedgerCounts(subscriptions: 10, ok: 7, failed: 2, pending: 1))
        XCTAssertEqual(ledger.failed.map(\.characteristicId), ["C7", "C8"])
        XCTAssertEqual(ledger.failed.first?.state, .failed(code: -70))
        XCTAssertNil(ledger.deadlineReached(), "settles once")
    }

    func test_PT141_completionsFrom4ThreadsAtOnce_areCountedExactlyOnceEach() {
        let h = CoordinatorHarness()
        h.settings.enabled = false
        for i in 0..<400 { h.coordinator.register(sub("C\(i)", acc: "A\(i % 7)")) }
        h.coordinator.finishSetup()
        let group = DispatchGroup()
        for t in 0..<4 {
            DispatchQueue.global().async(group: group) {
                for i in stride(from: t, to: 400, by: 4) {
                    h.coordinator.complete(characteristicId: "C\(i)", errorCode: i % 10 == 0 ? -70 : nil)
                    h.coordinator.complete(characteristicId: "C\(i)", errorCode: nil)        // a duplicate completion is ignored
                }
            }
        }
        group.wait(); h.drain()
        XCTAssertEqual(h.coordinator.countsForTests(), LedgerCounts(subscriptions: 400, ok: 360, failed: 40, pending: 0))
        XCTAssertEqual(h.sink.count(prefix: "Polling: mode=failed-only"), 1)
        XCTAssertEqual(h.sink.lines.last, "Polling: mode=failed-only enabled=false subscriptions=400 ok=360 failed=40 pending=0 excluded=0 polled=0 bridges=0 limit=6/min/bridge")
    }

    // PT-142 — the exact O27 strings with no failure; no timer; one line even when the deadline races the last completion
    func test_PT142_noFailures_exactStrings_offAndOn_andNoTimer() {
        for enabled in [false, true] {
            let h = CoordinatorHarness()
            h.settings.enabled = enabled
            for i in 0..<12 { h.coordinator.register(sub("C\(i)", bridge: "B\(i % 3)")) }
            for i in 0..<12 { h.coordinator.complete(characteristicId: "C\(i)", errorCode: nil) }
            h.coordinator.finishSetup(); h.drain()
            XCTAssertEqual(h.sink.lines, ["Polling: mode=failed-only enabled=\(enabled) subscriptions=12 ok=12 failed=0 pending=0 excluded=0 polled=0 bridges=0 limit=6/min/bridge"])
            XCTAssertTrue(h.timers.isEmpty, "no failures → no timer (enabled=\(enabled))")
            XCTAssertTrue(h.reads.isEmpty)
        }
    }

    func test_PT142_deadlineRacesTheLastCompletion_exactlyOneStartupLine() {
        for round in 0..<200 {
            let h = CoordinatorHarness()
            for i in 0..<3 { h.coordinator.register(sub("C\(i)")) }
            h.coordinator.complete(characteristicId: "C0", errorCode: nil)
            h.coordinator.complete(characteristicId: "C1", errorCode: nil)
            h.coordinator.finishSetup(); h.drain()
            XCTAssertEqual(h.deadlines.count, 1, "one 60 s deadline is scheduled")
            let deadline = h.deadlines[0]
            let go = DispatchGroup()
            DispatchQueue.global().async(group: go) { deadline() }
            DispatchQueue.global().async(group: go) { h.coordinator.complete(characteristicId: "C2", errorCode: nil) }
            go.wait(); h.drain()
            XCTAssertEqual(h.sink.count(prefix: "Polling: mode=failed-only"), 1, "round \(round): exactly one startup line")
            XCTAssertEqual(h.sink.count(prefix: "Polling: changed"), 0, "round \(round): a late success changes nothing visible")
        }
    }

    func test_PT142_excludedIsComputedWithPollingOff() {
        let h = CoordinatorHarness()
        h.settings.enabled = false
        h.excludedAccessories = ["A2"]
        h.coordinator.register(sub("C1", acc: "A1")); h.coordinator.register(sub("C2", acc: "A2")); h.coordinator.register(sub("C3", acc: "A2"))
        h.coordinator.complete(characteristicId: "C1", errorCode: -70)
        h.coordinator.complete(characteristicId: "C2", errorCode: -70)
        h.coordinator.complete(characteristicId: "C3", errorCode: nil)
        h.coordinator.finishSetup(); h.drain()
        XCTAssertEqual(h.sink.lines, ["Polling: mode=failed-only enabled=false subscriptions=3 ok=1 failed=2 pending=0 excluded=1 polled=0 bridges=0 limit=6/min/bridge"])
    }

    // PT-143 — per-bridge limit, one read in flight, round robin, abandonment after 30 s
    func test_PT143_twoBridges_limit6_tenMinutes_neverMoreThanOnePerTickOrSixPerMinute_roundRobin() {
        let plan = PollPlan(polled: [sub("X1", bridge: "X"), sub("X2", bridge: "X"), sub("X3", bridge: "X"), sub("Y1", bridge: "Y"), sub("Y2", bridge: "Y")], excluded: 0)
        let s = PollScheduler(plan: plan, limit: 6)
        XCTAssertEqual(s.tickInterval, 10)
        var log: [(t: TimeInterval, id: String, bridge: String)] = []
        var t: TimeInterval = 0
        while t < 600 {
            let r = s.tick(now: t)
            XCTAssertLessThanOrEqual(Dictionary(grouping: r.start, by: \.bridgeKey).values.map(\.count).max() ?? 0, 1, "≤ 1 read per bridge per tick")
            for x in r.start { log.append((t, x.characteristicId, x.bridgeKey)); _ = s.complete(characteristicId: x.characteristicId, errorCode: nil, now: t) }
            t += s.tickInterval
        }
        for bridge in ["X", "Y"] {
            let times = log.filter { $0.bridge == bridge }.map(\.t)
            for start in stride(from: 0.0, through: 600.0, by: 1.0) {
                XCTAssertLessThanOrEqual(times.filter { $0 >= start && $0 < start + 60 }.count, 6, "\(bridge): ≤ 6 reads in [\(start), \(start + 60))")
            }
        }
        XCTAssertEqual(Array(log.filter { $0.bridge == "X" }.map(\.id).prefix(6)), ["X1", "X2", "X3", "X1", "X2", "X3"], "round robin")
        XCTAssertEqual(Array(log.filter { $0.bridge == "Y" }.map(\.id).prefix(4)), ["Y1", "Y2", "Y1", "Y2"])
        XCTAssertEqual(Set(log.map(\.id)), ["X1", "X2", "X3", "Y1", "Y2"], "every failed characteristic is covered")
        XCTAssertEqual(log.filter { $0.bridge == "X" }.count, 60)
    }

    func test_PT143_aReadInFlight_makesItsBridgeSkipTheTick() {
        let s = PollScheduler(plan: PollPlan(polled: [sub("X1", bridge: "X"), sub("X2", bridge: "X"), sub("Y1", bridge: "Y")], excluded: 0), limit: 6)
        XCTAssertEqual(s.tick(now: 0).start.map(\.characteristicId), ["X1", "Y1"])
        _ = s.complete(characteristicId: "Y1", errorCode: nil, now: 1)              // X1 still in flight
        XCTAssertEqual(s.tick(now: 10).start.map(\.characteristicId), ["Y1"], "X skips while X1 is in flight")
        _ = s.complete(characteristicId: "Y1", errorCode: nil, now: 11)
        XCTAssertEqual(s.tick(now: 20).start.map(\.characteristicId), ["Y1"])
        XCTAssertTrue(s.complete(characteristicId: "X1", errorCode: nil, now: 25).accepted)
        XCTAssertEqual(s.tick(now: 30).start.map(\.characteristicId), ["X2"], "free again after its read completed")
    }

    func test_PT143_aReadOlderThan30s_isAbandoned_loggedAsFailing_andTheBridgeReadsAgainOnTheNextTick() {
        let s = PollScheduler(plan: PollPlan(polled: [sub("X1", bridge: "X", name: "Lamp"), sub("X2", bridge: "X", name: "Lamp")], excluded: 0), limit: 6)
        XCTAssertEqual(s.tick(now: 0).start.map(\.characteristicId), ["X1"])          // never completes
        XCTAssertEqual(s.tick(now: 10).start.count, 0)
        XCTAssertEqual(s.tick(now: 20).start.count, 0)
        let at30 = s.tick(now: 30)
        XCTAssertEqual(at30.start.count, 0, "30 s is not older than 30 s")
        XCTAssertTrue(at30.lines.isEmpty)
        let at40 = s.tick(now: 40)
        XCTAssertEqual(at40.start.count, 0, "abandoned at this tick; the bridge reads again on the next one")
        XCTAssertEqual(at40.lines, ["Polling: read failing Lamp / Char X1 code=-1"])
        XCTAssertEqual(s.tick(now: 50).start.map(\.characteristicId), ["X2"])
        XCTAssertFalse(s.complete(characteristicId: "X1", errorCode: nil, now: 55).accepted, "a late answer of an abandoned read is dropped")
    }

    // PT-144 — the Lutron case: 300 failures on one bridge
    func test_PT144_threeHundredFailuresOnOneBridge_sixAMinute_eachReadOnceEvery50Minutes_otherBridgeUnaffected() {
        var polled = (0..<300).map { sub("L\($0)", bridge: "LUTRON") }
        polled.append(sub("M1", bridge: "OTHER"))
        let s = PollScheduler(plan: PollPlan(polled: polled, excluded: 0), limit: 6)
        var lutron: [(TimeInterval, String)] = [], other = 0
        var t: TimeInterval = 0
        while t < 3600 {
            for x in s.tick(now: t).start {
                if x.bridgeKey == "LUTRON" { lutron.append((t, x.characteristicId)) } else { other += 1 }
                _ = s.complete(characteristicId: x.characteristicId, errorCode: nil, now: t)
            }
            t += 10
        }
        for minute in 0..<60 {
            XCTAssertLessThanOrEqual(lutron.filter { $0.0 >= Double(minute * 60) && $0.0 < Double(minute * 60 + 60) }.count, 6)
        }
        let first50 = lutron.filter { $0.0 < 3000 }.map(\.1)
        XCTAssertEqual(first50.count, 300)
        XCTAssertEqual(Set(first50).count, 300, "each characteristic exactly once in the first 50 minutes")
        let l0 = lutron.filter { $0.1 == "L0" }.map(\.0)
        XCTAssertEqual(l0, [0, 3000], "L0 again after 50 minutes")
        XCTAssertEqual(other, 360, "the other bridge reads every tick (6 a minute), unaffected")
    }

    // PT-145 — polling off: counts printed, nothing read
    func test_PT145_pollingOff_withFiveFailures_printsFailed5_polled0_andReadsNothing() {
        let h = CoordinatorHarness()
        h.settings.enabled = false
        for i in 0..<8 { h.coordinator.register(sub("C\(i)", bridge: "B\(i % 2)")) }
        for i in 0..<8 { h.coordinator.complete(characteristicId: "C\(i)", errorCode: i < 5 ? -70 : nil) }
        h.coordinator.finishSetup(); h.drain()
        XCTAssertEqual(h.sink.lines, ["Polling: mode=failed-only enabled=false subscriptions=8 ok=3 failed=5 pending=0 excluded=0 polled=0 bridges=0 limit=6/min/bridge"])
        XCTAssertTrue(h.timers.isEmpty)
        XCTAssertTrue(h.reads.isEmpty)
    }

    // PT-146 — the device registry excludes failures from polling
    func test_PT146_blacklistExcludes2of5Failed_excluded2_polled3() {
        let registry = PrefabConfig.DeviceRegistry(mode: .blacklist, devices: ["A3", "Hall Lamp"])
        let h = CoordinatorHarness()
        let names = ["A1": "Porch", "A2": "Garage", "A3": "Den", "A4": "Hall Lamp", "A5": "Attic"]
        let coordinator = PollingCoordinator(
            queue: h.queue, settings: { PollSettings(enabled: true, rawLimit: nil, reportEvery: 60) },
            include: { id, name in registry.includes(uuid: id, name: name) },
            log: { h.sink.append($0) }, startRead: { _, done in done(nil) }, clock: { 0 },
            makeTimer: { i, f in FakePollTimer(interval: i, fire: f) }, scheduleAfter: { _, _ in }, onReport: { _ in })
        for (i, acc) in ["A1", "A2", "A3", "A4", "A5"].enumerated() {
            coordinator.register(sub("C\(i)", acc: acc, bridge: "B\(i)", name: names[acc]))
            coordinator.complete(characteristicId: "C\(i)", errorCode: -70)
        }
        coordinator.finishSetup(); coordinator.drain()
        XCTAssertEqual(h.sink.lines, ["Polling: mode=failed-only enabled=true subscriptions=5 ok=0 failed=5 pending=0 excluded=2 polled=3 bridges=3 limit=6/min/bridge"])
    }

    func test_PT146_registryRule_matchesShouldPollAccessory() {
        let all = PrefabConfig.DeviceRegistry(mode: .all, devices: ["X"])
        let white = PrefabConfig.DeviceRegistry(mode: .whitelist, devices: ["U1", "Lamp"])
        let black = PrefabConfig.DeviceRegistry(mode: .blacklist, devices: ["U1", "Lamp"])
        XCTAssertTrue(all.includes(uuid: "U1", name: "n"))
        XCTAssertTrue(white.includes(uuid: "U1", name: "n")); XCTAssertTrue(white.includes(uuid: "U9", name: "Lamp")); XCTAssertFalse(white.includes(uuid: "U9", name: "n"))
        XCTAssertFalse(black.includes(uuid: "U1", name: "n")); XCTAssertFalse(black.includes(uuid: "U9", name: "Lamp")); XCTAssertTrue(black.includes(uuid: "U9", name: "n"))
    }

    // PT-147 — the limit is clamped to 1…30 with one line
    func test_PT147_limitClamp_resolve() {
        XCTAssertEqual(PollingLimit.resolve(nil).limit, 6); XCTAssertNil(PollingLimit.resolve(nil).clampLine)
        XCTAssertEqual(PollingLimit.resolve(1).limit, 1); XCTAssertNil(PollingLimit.resolve(1).clampLine)
        XCTAssertEqual(PollingLimit.resolve(30).limit, 30); XCTAssertNil(PollingLimit.resolve(30).clampLine)
        XCTAssertEqual(PollingLimit.resolve(0).limit, 1); XCTAssertEqual(PollingLimit.resolve(0).clampLine, "Polling: limit 0 outside 1..30, using 1")
        XCTAssertEqual(PollingLimit.resolve(100).limit, 30); XCTAssertEqual(PollingLimit.resolve(100).clampLine, "Polling: limit 100 outside 1..30, using 30")
        XCTAssertEqual(PollingLimit.resolve(-5).limit, 1)
    }

    func test_PT147_limit0_and_limit100_eachLogExactlyOneClampLine() {
        for (raw, lim, tick) in [(0, 1, 60.0), (100, 30, 2.0)] {
            let h = CoordinatorHarness()
            h.settings.rawLimit = raw
            h.coordinator.register(sub("C1")); h.coordinator.complete(characteristicId: "C1", errorCode: -70)
            h.coordinator.finishSetup(); h.drain()                                        // settles: clamp line + startup line
            h.coordinator.register(sub("C2")); h.coordinator.complete(characteristicId: "C2", errorCode: -70); h.drain()   // a change after settle
            XCTAssertEqual(h.sink.lines, ["Polling: limit \(raw) outside 1..30, using \(lim)",
                                          "Polling: mode=failed-only enabled=true subscriptions=1 ok=0 failed=1 pending=0 excluded=0 polled=1 bridges=1 limit=\(lim)/min/bridge",
                                          "Polling: changed failed=2 pending=0 polled=2 bridges=1"], "exactly one clamp line")
            XCTAssertEqual(h.liveTimer?.interval, tick, "tick every 60/limit s")
        }
    }

    // PT-148 — read errors are logged on a change of state only
    func test_PT148_fiveFailuresThenSuccess_oneFailingLine_oneOkAgainLine() {
        let s = PollScheduler(plan: PollPlan(polled: [sub("C1", name: "Lamp")], excluded: 0), limit: 6)
        var lines: [String] = []
        var t: TimeInterval = 0
        for i in 0..<8 {
            lines += s.tick(now: t).lines
            lines += s.complete(characteristicId: "C1", errorCode: i < 5 ? 74 : nil, now: t).lines
            t += 10
        }
        XCTAssertEqual(lines, ["Polling: read failing Lamp / Char C1 code=74", "Polling: read ok again Lamp / Char C1"])
    }

    func test_PT148_throughTheCoordinator_readsGoToHomeKitAndLinesAreStateChangesOnly() {
        let h = CoordinatorHarness()
        var calls = 0
        h.readResult = { _ in calls += 1; return calls <= 5 ? 74 : nil }
        h.coordinator.register(sub("C1", name: "Lamp")); h.coordinator.complete(characteristicId: "C1", errorCode: -70)
        h.coordinator.finishSetup(); h.drain()
        for k in 0..<8 { h.tick(at: Double(k) * 10) }
        XCTAssertEqual(h.reads.count, 8)
        XCTAssertEqual(h.sink.lines.filter { $0.hasPrefix("Polling: read") }, ["Polling: read failing Lamp / Char C1 code=74", "Polling: read ok again Lamp / Char C1"])
    }

    // PT-149 — late changes
    func test_PT149_failureAfterTheStartupLine_oneChangeLine_andARecomputedPlan_lateSuccessChangesNothing() {
        let h = CoordinatorHarness()
        for i in 0..<3 { h.coordinator.register(sub("C\(i)")) }
        h.coordinator.complete(characteristicId: "C0", errorCode: nil)
        h.coordinator.complete(characteristicId: "C1", errorCode: nil)
        h.coordinator.finishSetup(); h.drain()
        h.deadlines[0](); h.drain()
        XCTAssertEqual(h.sink.lines, ["Polling: mode=failed-only enabled=true subscriptions=3 ok=2 failed=0 pending=1 excluded=0 polled=0 bridges=0 limit=6/min/bridge"])
        XCTAssertNil(h.liveTimer)
        h.coordinator.complete(characteristicId: "C2", errorCode: -70); h.drain()
        XCTAssertEqual(h.sink.lines.last, "Polling: changed failed=1 pending=0 polled=1 bridges=1")
        XCTAssertNotNil(h.liveTimer, "the recomputed plan polls the new failure")
        h.tick(at: 0)
        XCTAssertEqual(h.reads, ["C2"])
        // a subscription made later (home(_:didAdd:)) that succeeds: nothing visible
        h.coordinator.register(sub("C9", acc: "A9")); h.coordinator.complete(characteristicId: "C9", errorCode: nil); h.drain()
        XCTAssertEqual(h.sink.count(prefix: "Polling: changed"), 1)
        XCTAssertEqual(h.coordinator.countsForTests(), LedgerCounts(subscriptions: 4, ok: 3, failed: 1, pending: 0))
    }

    func test_PT149_aLateFailureWithPollingOff_logsTheChange_butStillReadsNothing() {
        let h = CoordinatorHarness()
        h.settings.enabled = false
        h.coordinator.register(sub("C0")); h.coordinator.finishSetup(); h.drain()
        h.deadlines[0](); h.drain()
        h.coordinator.complete(characteristicId: "C0", errorCode: -70); h.drain()
        XCTAssertEqual(h.sink.lines.last, "Polling: changed failed=1 pending=0 polled=0 bridges=0")
        XCTAssertTrue(h.timers.isEmpty)
    }

    // support — the report cadence keeps polling.intervalSeconds' only role (ticksPerReport), crash-free
    func test_reportPeriod_isIntervalTimesTicksPerReport_andNeverDividesByZero() {
        XCTAssertEqual(PollingReport.period(intervalSeconds: 15, reportIntervalSeconds: 60), 60)
        XCTAssertEqual(PollingReport.period(intervalSeconds: 5, reportIntervalSeconds: 60), 60)
        XCTAssertEqual(PollingReport.period(intervalSeconds: 25, reportIntervalSeconds: 60), 50)
        XCTAssertEqual(PollingReport.period(intervalSeconds: 0, reportIntervalSeconds: 60), 60)
        XCTAssertEqual(PollingReport.period(intervalSeconds: 100, reportIntervalSeconds: 60), 100)
        XCTAssertEqual(PollingReport.period(intervalSeconds: 15, reportIntervalSeconds: 0), 60)
    }

    func test_reportFires_onlyWhilePolling_atTheReportPeriod() {
        let h = CoordinatorHarness()
        h.settings.reportEvery = 60
        h.coordinator.register(sub("C1")); h.coordinator.complete(characteristicId: "C1", errorCode: -70)
        h.coordinator.finishSetup(); h.drain()
        for k in 0..<13 { h.tick(at: Double(k) * 10) }      // 0 … 120 s
        XCTAssertEqual(h.reports, 2, "at 60 s and 120 s")
    }
}
