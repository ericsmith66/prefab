//
//  PollingCore.swift
//  Prefab — failed-only polling, HomeKit-free (PRD-1-01 plan § 15.18 R7-7, § 15.19 R8-6).
//
//  S′ polled EVERY readable characteristic of every accessory when polling was on and no subscription had failed
//  (its poll-all fallback, PD-20: ~800 reads per 15 s on the Lutron Processor (2) on 2026-10-02). S″:
//  only characteristics whose HomeKit notification subscription FAILED are polled, at most `limit` reads a minute per
//  bridge with one read in flight per bridge; no code path polls everything. HomeBase is the thin HomeKit adapter: it
//  registers subscriptions, reports their completions and performs the reads this coordinator asks for.
//
//  Compiled into the Prefab app and the hostless prefabLogicTests target; never the CLI target.
//

import Foundation

// MARK: - O27: the exact lines (each written by HomeBase.logToFile, so prefixed `[<ISO-8601 UTC>] ` in the debug log)

enum PollingLines {
    /// Once per start: `N = ok + failed + pending`; `excluded ≤ failed`; with polling off `polled=0 bridges=0`.
    static func startup(enabled: Bool, counts: LedgerCounts, plan: PollPlan, limit: Int) -> String {
        "Polling: mode=failed-only enabled=\(enabled) subscriptions=\(counts.subscriptions) ok=\(counts.ok) failed=\(counts.failed) "
            + "pending=\(counts.pending) excluded=\(plan.excluded) polled=\(plan.polled.count) bridges=\(plan.bridges) limit=\(limit)/min/bridge"
    }
    /// Only after the startup line, only when the failed set changes.
    static func change(counts: LedgerCounts, plan: PollPlan) -> String {
        "Polling: changed failed=\(counts.failed) pending=\(counts.pending) polled=\(plan.polled.count) bridges=\(plan.bridges)"
    }
    static func clamp(raw: Int, using limit: Int) -> String { "Polling: limit \(raw) outside 1..30, using \(limit)" }
    static func readFailing(_ s: Subscription, code: Int) -> String { "Polling: read failing \(s.accessoryName) / \(s.characteristicName) code=\(code)" }
    static func readOkAgain(_ s: Subscription) -> String { "Polling: read ok again \(s.accessoryName) / \(s.characteristicName)" }
}

/// `polling.maxReadsPerMinutePerBridge`: missing → 6; outside 1…30 → clamped, with one line (R7-7 item 5).
enum PollingLimit {
    static let range = 1...30
    static func resolve(_ raw: Int?) -> (limit: Int, clampLine: String?) {
        guard let raw else { return (PrefabConfig.PollingConfig.defaultMaxReadsPerMinutePerBridge, nil) }
        if range.contains(raw) { return (raw, nil) }
        let limit = min(max(raw, range.lowerBound), range.upperBound)
        return (limit, PollingLines.clamp(raw: raw, using: limit))
    }
}

/// The stats report while polling runs keeps S′'s cadence: every `intervalSeconds × ticksPerReport` seconds
/// (`polling.intervalSeconds`' only remaining role, R7-7 item 5). Never divides by zero.
enum PollingReport {
    static func period(intervalSeconds: TimeInterval, reportIntervalSeconds: TimeInterval) -> TimeInterval {
        guard intervalSeconds > 0, reportIntervalSeconds > 0, intervalSeconds.isFinite, reportIntervalSeconds.isFinite else { return 60 }
        let ticks = max(1, Int(min(reportIntervalSeconds / intervalSeconds, 1_000_000)))
        return Double(ticks) * intervalSeconds
    }
}

// MARK: - The subscription ledger

enum SubscriptionState: Equatable {
    case pending
    case ok
    case failed(code: Int)
}

struct Subscription: Equatable {
    let characteristicId: String
    let accessoryId: String
    let accessoryName: String
    let characteristicName: String
    /// The bridge's uniqueIdentifier for a bridged accessory, else the accessory's own id.
    let bridgeKey: String
    var state: SubscriptionState
}

struct LedgerCounts: Equatable {
    var subscriptions: Int
    var ok: Int
    var failed: Int
    var pending: Int
}

enum LedgerEvent: Equatable {
    /// The startup line is due — exactly once per start.
    case settled
    /// After the startup line: the set of failed subscriptions changed.
    case failedSetChanged
}

/// Every readable, event-capable characteristic is registered BEFORE its enableNotification(true); the completion
/// moves it to ok or failed(code). Not thread-safe by itself: PollingCoordinator serialises all access on one queue.
struct SubscriptionLedger {
    private var byId: [String: Subscription] = [:]
    private var order: [String] = []
    private(set) var setupFinished = false
    private(set) var settled = false
    private var announcedFailed: Set<String> = []

    var counts: LedgerCounts {
        var c = LedgerCounts(subscriptions: order.count, ok: 0, failed: 0, pending: 0)
        for id in order {
            switch byId[id]!.state {
            case .pending: c.pending += 1
            case .ok: c.ok += 1
            case .failed: c.failed += 1
            }
        }
        return c
    }

    /// Failed subscriptions in registration order.
    var failed: [Subscription] {
        order.compactMap { byId[$0] }.filter { if case .failed = $0.state { return true } else { return false } }
    }

    private var failedIds: Set<String> { Set(failed.map(\.characteristicId)) }

    /// Registers (or re-registers, as pending) a subscription. Re-registering a failed one can change the failed set.
    @discardableResult
    mutating func register(_ s: Subscription) -> LedgerEvent? {
        if byId[s.characteristicId] == nil { order.append(s.characteristicId) }
        var pending = s
        pending.state = .pending
        byId[s.characteristicId] = pending
        return afterChange()
    }

    /// The enableNotification completion: nil error code → ok. Only a pending subscription moves; a duplicate or an
    /// unknown completion is ignored.
    mutating func complete(characteristicId: String, errorCode: Int?) -> LedgerEvent? {
        guard var s = byId[characteristicId], s.state == .pending else { return nil }
        s.state = errorCode.map { .failed(code: $0) } ?? .ok
        byId[characteristicId] = s
        return afterChange()
    }

    /// Called once, after the initial setup registered everything: settles at once if every completion is already in.
    mutating func finishSetup() -> LedgerEvent? {
        setupFinished = true
        return afterChange()
    }

    /// The 60 s deadline after setup: settles whatever is still pending.
    mutating func deadlineReached() -> LedgerEvent? {
        guard !settled else { return nil }
        return settle()
    }

    private mutating func settle() -> LedgerEvent {
        settled = true
        announcedFailed = failedIds
        return .settled
    }

    private mutating func afterChange() -> LedgerEvent? {
        if !settled {
            return setupFinished && counts.pending == 0 ? settle() : nil
        }
        let now = failedIds
        guard now != announcedFailed else { return nil }
        announcedFailed = now
        return .failedSetChanged
    }
}

// MARK: - The planner

struct PollPlan: Equatable {
    /// Failed subscriptions the device registry includes, and only while polling is enabled.
    let polled: [Subscription]
    /// Failed subscriptions whose accessory the registry excludes — computed whether polling is on or off (R8-6).
    let excluded: Int
    /// Distinct bridge keys among `polled`: ≤ polled, and 0 exactly when polled is 0.
    var bridges: Int { Set(polled.map(\.bridgeKey)).count }
}

enum PollPlanner {
    /// No failures → nothing to poll. With polling off nothing is polled, but every count is still computed.
    static func plan(failed: [Subscription], enabled: Bool, include: (_ accessoryId: String, _ accessoryName: String) -> Bool) -> PollPlan {
        let included = failed.filter { include($0.accessoryId, $0.accessoryName) }
        return PollPlan(polled: enabled ? included : [], excluded: failed.count - included.count)
    }
}

// MARK: - The per-bridge scheduler (pure; the caller supplies the clock)

/// One tick every 60/limit s. On each tick every bridge with polled characteristics reads ONE of them (round robin)
/// unless its previous read is still in flight. A read older than 30 s is abandoned (logged as failing, code -1) and
/// the bridge reads again on the next tick. So a bridge never gets more than `limit` reads a minute, however many of
/// its subscriptions failed. Read errors are logged on a change of state only.
final class PollScheduler {
    static let abandonAfter: TimeInterval = 30
    static let abandonedCode = -1

    struct TickResult { var start: [Subscription]; var lines: [String] }

    private struct Bridge {
        var subs: [Subscription]
        var cursor = 0
        var inFlight: (id: String, startedAt: TimeInterval)?
    }

    let limit: Int
    private var bridges: [String: Bridge] = [:]
    private var bridgeOrder: [String] = []
    private var failing: Set<String> = []

    var tickInterval: TimeInterval { 60.0 / Double(limit) }

    init(plan: PollPlan, limit: Int) {
        self.limit = limit
        replan(plan)
    }

    /// A recomputed plan keeps each surviving bridge's in-flight read (one read in flight per bridge, always).
    func replan(_ plan: PollPlan) {
        var next: [String: Bridge] = [:]
        var order: [String] = []
        for s in plan.polled {
            if next[s.bridgeKey] == nil { order.append(s.bridgeKey); next[s.bridgeKey] = Bridge(subs: [], inFlight: bridges[s.bridgeKey]?.inFlight) }
            next[s.bridgeKey]!.subs.append(s)
        }
        for key in order { next[key]!.cursor = min(bridges[key]?.cursor ?? 0, next[key]!.subs.count - 1) }
        bridges = next
        bridgeOrder = order
        failing = failing.intersection(plan.polled.map(\.characteristicId))
    }

    func tick(now: TimeInterval) -> TickResult {
        var r = TickResult(start: [], lines: [])
        for key in bridgeOrder {
            guard var b = bridges[key], !b.subs.isEmpty else { continue }
            if let f = b.inFlight {
                if now - f.startedAt > Self.abandonAfter {
                    b.inFlight = nil
                    if let s = b.subs.first(where: { $0.characteristicId == f.id }), failing.insert(f.id).inserted {
                        r.lines.append(PollingLines.readFailing(s, code: Self.abandonedCode))
                    }
                }
                bridges[key] = b
                continue                                             // in flight, or freed this tick: next tick
            }
            let s = b.subs[b.cursor % b.subs.count]
            b.cursor = (b.cursor + 1) % b.subs.count
            b.inFlight = (s.characteristicId, now)
            bridges[key] = b
            r.start.append(s)
        }
        return r
    }

    /// A read's completion. `accepted` is false for an abandoned or unknown read (its answer is dropped).
    func complete(characteristicId: String, errorCode: Int?, now: TimeInterval) -> (accepted: Bool, lines: [String]) {
        guard let key = bridgeOrder.first(where: { bridges[$0]?.inFlight?.id == characteristicId }),
              let s = bridges[key]?.subs.first(where: { $0.characteristicId == characteristicId }) else { return (false, []) }
        bridges[key]?.inFlight = nil
        if let code = errorCode {
            return (true, failing.insert(characteristicId).inserted ? [PollingLines.readFailing(s, code: code)] : [])
        }
        return (true, failing.remove(characteristicId) != nil ? [PollingLines.readOkAgain(s)] : [])
    }
}

// MARK: - The coordinator (thread-safe: one serial queue owns the ledger, the plan and the scheduler)

struct PollSettings {
    var enabled: Bool
    /// `polling.maxReadsPerMinutePerBridge` as configured (nil = missing).
    var rawLimit: Int?
    /// PollingReport.period(…) of the config.
    var reportEvery: TimeInterval
}

protocol PollTimer: AnyObject { func cancel() }

/// The production timer: a repeating DispatchSourceTimer whose handler runs on the coordinator's queue.
final class DispatchPollTimer: PollTimer {
    private let source: DispatchSourceTimer
    init(queue: DispatchQueue, interval: TimeInterval, handler: @escaping () -> Void) {
        source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(100))
        source.setEventHandler(handler: handler)
        source.resume()
    }
    func cancel() { source.cancel() }
}

final class PollingCoordinator {
    typealias Include = (_ accessoryId: String, _ accessoryName: String) -> Bool
    /// Perform one read of the subscription's characteristic; call `done` once with nil (ok) or the error code.
    typealias StartRead = (_ s: Subscription, _ done: @escaping (_ errorCode: Int?) -> Void) -> Void

    static let settleDeadline: TimeInterval = 60

    private let queue: DispatchQueue
    private let settings: () -> PollSettings
    private let include: Include
    private let log: (String) -> Void
    private let startRead: StartRead
    private let clock: () -> TimeInterval
    private let makeTimer: (_ interval: TimeInterval, _ handler: @escaping () -> Void) -> PollTimer
    private let scheduleAfter: (_ delay: TimeInterval, _ block: @escaping () -> Void) -> Void
    private let onReport: (_ tick: Int) -> Void

    // queue-confined state
    private var ledger = SubscriptionLedger()
    private var scheduler: PollScheduler?
    private var timer: PollTimer?
    private var ticks = 0
    private var lastReport: TimeInterval = 0

    init(queue: DispatchQueue, settings: @escaping () -> PollSettings, include: @escaping Include, log: @escaping (String) -> Void,
         startRead: @escaping StartRead, clock: @escaping () -> TimeInterval,
         makeTimer: @escaping (_ interval: TimeInterval, _ handler: @escaping () -> Void) -> PollTimer,
         scheduleAfter: @escaping (_ delay: TimeInterval, _ block: @escaping () -> Void) -> Void,
         onReport: @escaping (_ tick: Int) -> Void) {
        self.queue = queue; self.settings = settings; self.include = include; self.log = log; self.startRead = startRead
        self.clock = clock; self.makeTimer = makeTimer; self.scheduleAfter = scheduleAfter; self.onReport = onReport
    }

    // MARK: entry points — callable from any thread (HomeKit completion handlers included)

    func register(_ s: Subscription) { queue.async { self.handle(self.ledger.register(s)) } }

    func complete(characteristicId: String, errorCode: Int?) {
        queue.async { self.handle(self.ledger.complete(characteristicId: characteristicId, errorCode: errorCode)) }
    }

    /// After the initial setup: the startup line prints when every completion is in, or 60 s later, whichever is first.
    func finishSetup() {
        queue.async {
            self.handle(self.ledger.finishSetup())
            self.scheduleAfter(Self.settleDeadline) { [weak self] in self?.deadlineReached() }
        }
    }

    func deadlineReached() { queue.async { self.handle(self.ledger.deadlineReached()) } }

    /// Waits until everything queued so far has run (tests).
    func drain() { queue.sync {} }

    func countsForTests() -> LedgerCounts { queue.sync { ledger.counts } }

    // MARK: queue-confined

    private func handle(_ event: LedgerEvent?) {
        guard let event else { return }
        let s = settings()
        let (limit, clampLine) = PollingLimit.resolve(s.rawLimit)
        let plan = PollPlanner.plan(failed: ledger.failed, enabled: s.enabled, include: include)
        switch event {
        case .settled:
            if let clampLine { log(clampLine) }
            log(PollingLines.startup(enabled: s.enabled, counts: ledger.counts, plan: plan, limit: limit))
        case .failedSetChanged:
            log(PollingLines.change(counts: ledger.counts, plan: plan))
        }
        apply(plan, limit: limit)
    }

    private func apply(_ plan: PollPlan, limit: Int) {
        guard !plan.polled.isEmpty else {
            timer?.cancel(); timer = nil; scheduler = nil
            return
        }
        if let scheduler, scheduler.limit == limit { scheduler.replan(plan) } else { scheduler = PollScheduler(plan: plan, limit: limit) }
        if timer == nil, let scheduler {
            lastReport = clock()
            timer = makeTimer(scheduler.tickInterval) { [weak self] in self?.tick() }
        }
    }

    /// The timer's handler (runs on the queue).
    private func tick() {
        guard let scheduler else { return }
        let now = clock()
        ticks += 1
        let r = scheduler.tick(now: now)
        r.lines.forEach(log)
        for s in r.start {
            startRead(s) { [weak self] code in
                guard let self else { return }
                self.queue.async {
                    guard let scheduler = self.scheduler else { return }
                    scheduler.complete(characteristicId: s.characteristicId, errorCode: code, now: self.clock()).lines.forEach(self.log)
                }
            }
        }
        if now - lastReport >= settings().reportEvery {
            lastReport = now
            onReport(ticks)
        }
    }
}
