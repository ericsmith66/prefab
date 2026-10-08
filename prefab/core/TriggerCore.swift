//
//  TriggerCore.swift
//  Prefab — PRD-1-07 Track A: HomeKit trigger routes, HomeKit-free core (PRD-1-07 implementation plan §§ 4–8 and its
//  2026-10-08 amendments A-1…A-10). Shipped inside Prefab S″.
//
//  HMTrigger / HMEventTrigger cannot be built in a test, so the routes work on plain snapshots behind the TriggerStore
//  protocol; the app's HomeKitTriggerStore (prefab/model) converts HomeKit objects into them. Compiled into the Prefab
//  app and the hostless prefabLogicTests target; never the CLI target. Nothing here imports HomeKit.
//

import Foundation
import Hummingbird

// MARK: - Snapshots (what the GET contract encodes)

struct TriggerSnapshot {
    enum Kind {
        case timer(TimerSnapshot)
        case event(EventTriggerSnapshot)
        /// A trigger class other than HMTimerTrigger / HMEventTrigger — `kind:"unknown"` (Track B: ineligible).
        case unknown(className: String)
    }
    var uuid: UUID
    var name: String
    var enabled: Bool
    var lastFireDate: Date?
    var kind: Kind
    /// In HomeKit's order.
    var actionSets: [ActionSetSnapshot]
}

struct TimerSnapshot {
    var fireDate: Date
    var recurrence: DateComponents?
    var timeZone: TimeZone?
}

struct EventTriggerSnapshot {
    var events: [EventSnapshot]
    var endEvents: [EventSnapshot] = []
    /// NSPredicate.predicateFormat, as HomeKit holds it (never truncated).
    var predicateFormat: String? = nil
    /// The predicate as a token tree (PredicateWalker); nil when there is no predicate.
    var predicate: PredicateNode? = nil
    /// HMEventTrigger.recurrences (Apple weekdays, 1 = Sunday).
    var recurrences: [DateComponents]? = nil
    var executeOnce: Bool = false
}

enum SignificantEvent: String {
    case sunrise, sunset, unknown
}

enum EventSnapshot {
    case calendar(DateComponents)
    case significantTime(event: SignificantEvent, offset: DateComponents?)
    case characteristic(accessoryUUID: String?, serviceType: String?, characteristicType: String?, triggerValue: String?)
    case threshold(accessoryUUID: String?, characteristicType: String?, min: Double?, max: Double?)
    /// presenceType ∈ every_entry, every_exit, first_entry, last_exit, at_home, not_at_home, unknown;
    /// userType ∈ current_user, home_users, custom_users, unknown (the adapter maps HomeKit's enums).
    case presence(presenceType: String, userType: String)
    /// No coordinates, ever.
    case location
    case duration(seconds: Double)
    case unknown(className: String)
}

enum ActionSetKind: String {
    case userDefined = "user_defined"
    case triggerOwned = "trigger_owned"
    case builtin
    case unknown

    /// HMActionSetType → kind. The adapter passes HomeKit's constants; anything not listed → unknown (fail closed).
    static func classify(_ raw: String, userDefined: String, triggerOwned: String, builtins: Set<String>) -> ActionSetKind {
        if raw == userDefined { return .userDefined }
        if raw == triggerOwned { return .triggerOwned }
        if builtins.contains(raw) { return .builtin }
        return .unknown
    }
}

struct ActionSetSnapshot {
    var uuid: UUID
    var name: String
    var kind: ActionSetKind
    /// actions.count in HomeKit (every kind of action).
    var totalActions: Int
    /// The characteristic-write actions, as GET /scenes/:home/:scene shows them (decoded_actions = their count).
    var actions: [SceneAction]
}

// MARK: - The predicate token tree (PredicateWalker builds it; decodePredicate reads it)

enum ComparisonOp: String {
    case lt = "<", le = "<=", eq = "==", ne = "!=", ge = ">=", gt = ">"
}

enum PredicateKey: Equatable {
    case time, significantEvent, characteristic, characteristicValue, presence, other
}

enum PredicateValue: Equatable {
    case timeOfDay(hour: Int, minute: Int)
    case significantEvent(event: String, offsetSeconds: Int)
    case characteristic(accessoryUUID: String, characteristicType: String)
    case scalar(String)
    case other
}

indirect enum PredicateNode: Equatable {
    case and([PredicateNode])
    case or([PredicateNode])
    case not(PredicateNode)
    case comparison(key: PredicateKey, op: ComparisonOp, value: PredicateValue)
    case other
}

enum TimePoint: Equatable {
    case clock(hour: Int, minute: Int)
    case sun(event: String, offsetSeconds: Int)
}

enum DecodedPredicate: Equatable {
    case window(after: TimePoint?, before: TimePoint?)
    case characteristic(accessoryUUID: String, characteristicType: String, op: ComparisonOp, value: String)
}

// MARK: - A tiny JSON tree (encoded by JSONEncoder with sorted keys, so names escape like every other route)

indirect enum JSONValue: Encodable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    private struct Key: CodingKey {
        var stringValue: String
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .object(let o):
            var c = encoder.container(keyedBy: Key.self)
            for (k, v) in o { try c.encode(v, forKey: Key(k)) }
        case .array(let a):
            var c = encoder.unkeyedContainer()
            for v in a { try c.encode(v) }
        case .string(let s): var c = encoder.singleValueContainer(); try c.encode(s)
        case .int(let i): var c = encoder.singleValueContainer(); try c.encode(i)
        case .double(let d): var c = encoder.singleValueContainer(); try c.encode(d)
        case .bool(let b): var c = encoder.singleValueContainer(); try c.encode(b)
        case .null: var c = encoder.singleValueContainer(); try c.encodeNil()
        }
    }

    static func optional(_ s: String?) -> JSONValue { s.map { .string($0) } ?? .null }
    static func optional(_ i: Int?) -> JSONValue { i.map { .int($0) } ?? .null }

    /// An Encodable value (a SceneAction) as a JSON tree, keyed exactly as its own Codable encoding.
    static func of<E: Encodable>(_ value: E) -> JSONValue {
        guard let data = try? JSONEncoder().encode(value), let obj = try? JSONSerialization.jsonObject(with: data) else { return .null }
        return from(obj)
    }

    private static func from(_ any: Any) -> JSONValue {
        switch any {
        case let d as [String: Any]: return .object(d.mapValues(from))
        case let a as [Any]: return .array(a.map(from))
        case let s as String: return .string(s)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            if CFNumberIsFloatType(n) { return .double(n.doubleValue) }
            return .int(n.intValue)
        default: return .null
        }
    }
}

// MARK: - The GET contract (FR-07-A1; plan § 5)

enum TriggerJSON {
    /// Every trigger carries every one of these keys (`null` when it does not apply).
    static let triggerKeys: Set<String> = ["uuid", "name", "enabled", "last_fire_at", "kind", "timer", "events", "end_events",
                                           "predicate", "predicate_decoded", "recurrence_weekdays", "execute_once", "action_sets"]

    /// `{home, count, write_enabled, triggers:[…]}` — keys sorted; triggers sorted by name, then uuid. Built from
    /// snapshots in memory: no readValue, no HomeKit call.
    static func encode(home: String, triggers: [TriggerSnapshot], writeEnabled: Bool) -> String {
        let sorted = triggers.sorted { ($0.name, $0.uuid.uuidString) < ($1.name, $1.uuid.uuidString) }
        let root = JSONValue.object(["home": .string(home), "count": .int(sorted.count), "write_enabled": .bool(writeEnabled),
                                     "triggers": .array(sorted.map(trigger))])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(data: (try? encoder.encode(root)) ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
    }

    static func trigger(_ t: TriggerSnapshot) -> JSONValue {
        var o: [String: JSONValue] = [
            "uuid": .string(t.uuid.uuidString), "name": .string(t.name), "enabled": .bool(t.enabled),
            "last_fire_at": t.lastFireDate.map { .string(iso($0)) } ?? .null,
            "timer": .null, "events": .array([]), "end_events": .array([]), "predicate": .null, "predicate_decoded": .null,
            "recurrence_weekdays": .null, "execute_once": .bool(false),
            "action_sets": .array(t.actionSets.map(actionSet)),
        ]
        switch t.kind {
        case .timer(let tm):
            o["kind"] = .string("timer")
            o["timer"] = .object(["fire_date": .string(iso(tm.fireDate)),
                                  "recurrence": tm.recurrence.map(components) ?? .null,
                                  "time_zone": .optional(tm.timeZone?.identifier)])
        case .event(let e):
            o["kind"] = .string("event")
            o["events"] = .array(e.events.map(event))
            o["end_events"] = .array(e.endEvents.map(event))
            o["predicate"] = .optional(e.predicateFormat)
            o["predicate_decoded"] = decodePredicate(e.predicate).map(decoded) ?? .null
            o["recurrence_weekdays"] = isoWeekdays(e.recurrences).map { .array($0.map { .int($0) }) } ?? .null
            o["execute_once"] = .bool(e.executeOnce)
        case .unknown:
            o["kind"] = .string("unknown")
        }
        return .object(o)
    }

    static func event(_ e: EventSnapshot) -> JSONValue {
        switch e {
        case .calendar(let d):
            var o: [String: JSONValue] = ["type": .string("calendar"), "hour": .optional(d.hour), "minute": .optional(d.minute)]
            if let s = d.second { o["second"] = .int(s) }
            return .object(o)
        case .significantTime(let ev, let offset):
            return .object(["type": .string("significant_time"), "event": .string(ev.rawValue), "offset_s": .int(offsetSeconds(offset))])
        case .characteristic(let acc, let svc, let chr, let value):
            return .object(["type": .string("characteristic"), "accessory_uuid": .optional(acc), "service_type": .optional(svc),
                            "characteristic_type": .optional(chr), "trigger_value": .optional(value)])
        case .threshold(let acc, let chr, let min, let max):
            var o: [String: JSONValue] = ["type": .string("threshold"), "accessory_uuid": .optional(acc), "characteristic_type": .optional(chr)]
            if let min { o["min"] = number(min) }
            if let max { o["max"] = number(max) }
            return .object(o)
        case .presence(let p, let u):
            return .object(["type": .string("presence"), "presence_type": .string(p), "user_type": .string(u)])
        case .location:
            return .object(["type": .string("location")])
        case .duration(let s):
            return .object(["type": .string("duration"), "seconds": number(s)])
        case .unknown(let cls):
            return .object(["type": .string("unknown"), "class": .string(cls)])
        }
    }

    static func actionSet(_ a: ActionSetSnapshot) -> JSONValue {
        .object(["uuid": .string(a.uuid.uuidString), "name": .string(a.name), "type": .string(a.kind.rawValue),
                 "total_actions": .int(a.totalActions), "decoded_actions": .int(a.actions.count),
                 "actions": .array(a.actions.map { JSONValue.of($0) })])
    }

    /// Whole numbers as integers (25, not 25.0); anything else as a double.
    static func number(_ d: Double) -> JSONValue {
        if d.isFinite, d == d.rounded(), abs(d) < 1e15 { return .int(Int(d)) }
        return .double(d)
    }

    /// The SET components only.
    static func components(_ d: DateComponents) -> JSONValue {
        var o: [String: JSONValue] = [:]
        let parts: [(String, Int?)] = [("era", d.era), ("year", d.year), ("month", d.month), ("day", d.day), ("hour", d.hour),
                                       ("minute", d.minute), ("second", d.second), ("nanosecond", d.nanosecond), ("weekday", d.weekday),
                                       ("weekdayOrdinal", d.weekdayOrdinal), ("quarter", d.quarter), ("weekOfMonth", d.weekOfMonth),
                                       ("weekOfYear", d.weekOfYear), ("yearForWeekOfYear", d.yearForWeekOfYear)]
        for (k, v) in parts { if let v { o[k] = .int(v) } }
        return .object(o)
    }

    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    /// HMEventTrigger.recurrences → ISO weekdays (1 = Monday … 7 = Sunday), sorted, unique.
    /// nil → nil ("every day"). A recurrence without a weekday, or with one outside 1…7, or an empty list → [] —
    /// never read as every day (Track B treats [] as ineligible).
    static func isoWeekdays(_ recurrences: [DateComponents]?) -> [Int]? {
        guard let recurrences else { return nil }
        var out = Set<Int>()
        for r in recurrences {
            guard let w = r.weekday, (1...7).contains(w) else { return [] }
            out.insert(w == 1 ? 7 : w - 1)                 // Apple 1 = Sunday … 7 = Saturday
        }
        return out.isEmpty ? [] : out.sorted()
    }

    /// hours·3600 + minutes·60 + seconds of an HMSignificantTimeEvent offset; none → 0.
    static func offsetSeconds(_ offset: DateComponents?) -> Int {
        guard let o = offset else { return 0 }
        return (o.hour ?? 0) * 3600 + (o.minute ?? 0) * 60 + (o.second ?? 0)
    }

    // MARK: predicate_decoded

    /// A time window (one comparison, or an AND of one "after" and one "before" on the time / sun key), or a
    /// characteristic comparison (an AND of `characteristic == <accessory, type>` and `characteristicValue <op> <value>`).
    /// Anything else — `==` on time, OR, NOT, presence, location, three or more children, a mismatched value — → nil.
    static func decodePredicate(_ node: PredicateNode?) -> DecodedPredicate? {
        guard let node else { return nil }
        switch node {
        case .comparison:
            return window(node)
        case .and(let children) where children.count == 2:
            if let a = window(children[0]), let b = window(children[1]),
               case .window(let a1, let b1) = a, case .window(let a2, let b2) = b {
                if let after = a1, b1 == nil, a2 == nil, let before = b2 { return .window(after: after, before: before) }
                if let after = a2, b2 == nil, a1 == nil, let before = b1 { return .window(after: after, before: before) }
                return nil
            }
            return characteristic(children[0], children[1]) ?? characteristic(children[1], children[0])
        default:
            return nil
        }
    }

    private static func point(_ key: PredicateKey, _ value: PredicateValue) -> TimePoint? {
        guard key == .time || key == .significantEvent else { return nil }
        switch value {
        case .timeOfDay(let h, let m): return .clock(hour: h, minute: m)
        case .significantEvent(let e, let o): return .sun(event: e, offsetSeconds: o)
        default: return nil
        }
    }

    private static func window(_ node: PredicateNode) -> DecodedPredicate? {
        guard case .comparison(let key, let op, let value) = node, let p = point(key, value) else { return nil }
        switch op {
        case .gt, .ge: return .window(after: p, before: nil)
        case .lt, .le: return .window(after: nil, before: p)
        case .eq, .ne: return nil
        }
    }

    private static func characteristic(_ a: PredicateNode, _ b: PredicateNode) -> DecodedPredicate? {
        guard case .comparison(.characteristic, .eq, .characteristic(let acc, let type)) = a,
              case .comparison(.characteristicValue, let op, .scalar(let v)) = b else { return nil }
        return .characteristic(accessoryUUID: acc, characteristicType: type, op: op, value: v)
    }

    static func decoded(_ d: DecodedPredicate) -> JSONValue {
        func pt(_ p: TimePoint?) -> JSONValue {
            switch p {
            case .clock(let h, let m)?: return .object(["hour": .int(h), "minute": .int(m)])
            case .sun(let e, let o)?: return .object(["event": .string(e), "offset_s": .int(o)])
            case nil: return .null
            }
        }
        switch d {
        case .window(let after, let before):
            return .object(["kind": .string("window"), "after": pt(after), "before": pt(before)])
        case .characteristic(let acc, let type, let op, let value):
            return .object(["kind": .string("characteristic"), "accessory_uuid": .string(acc), "characteristic_type": .string(type),
                            "op": .string(op.rawValue), "value": .string(value)])
        }
    }
}

// MARK: - The TriggerStore seam

enum TriggerLookup: Equatable {
    case noHome
    case noTrigger
    case found(uuid: UUID, enabled: Bool)
}

struct TriggerStoreError: Error, Equatable {
    let code: Int
    let message: String
}

protocol TriggerStore {
    /// Every trigger of the home, as snapshots; nil = no such home.
    func triggers(home: String) -> [TriggerSnapshot]?
    /// A trigger by uuid (compared case-insensitively).
    func lookup(home: String, uuid: String) -> TriggerLookup
    /// HMTrigger.enable(_:) — calls `completion` at most once, with nil on success; may never call back.
    func setEnabled(home: String, uuid: UUID, enabled: Bool, completion: @escaping (TriggerStoreError?) -> Void)
    /// isEnabled read back after a successful enable.
    func isEnabled(home: String, uuid: UUID) -> Bool?
}

enum TriggerAPI {
    /// GET /triggers/:home — 404 `{"error":"not_found","what":"home"}` for an unknown home.
    static func getTriggers(home: String, store: TriggerStore, writeEnabled: Bool) throws -> String {
        guard let snapshots = store.triggers(home: home) else { throw PrefabJSONError.notFound("home") }
        return TriggerJSON.encode(home: home, triggers: snapshots, writeEnabled: writeEnabled)
    }
}

// MARK: - The write flag (S10; plan § 6, amendment A-3)

/// `PUT /triggers/:home/:uuid/enabled` works only while this file exists: next to PREFAB_CONFIG_PATH, a REGULAR file
/// (not a symlink, not a directory), owned by the uid Prefab runs as, mode exactly 0600. Its content is ignored. It is
/// checked on every request, so creating or removing it needs no restart. Any lstat error (ENOENT or another) = absent.
struct TriggerWriteFlag {
    struct Attributes: Equatable {
        enum Kind: Equatable { case regular, symlink, directory, other }
        var kind: Kind
        var uid: uid_t
        var mode: mode_t
    }

    enum Status: Equatable {
        case valid
        /// reason ∈ absent, symlink, not_regular_file, owner, mode
        case invalid(reason: String)
    }

    static let fileName = "triggers-write-enabled"

    let path: String
    let uid: uid_t
    let read: (String) -> Attributes?

    init(path: String, uid: uid_t = getuid(), read: @escaping (String) -> Attributes? = TriggerWriteFlag.lstatAttributes) {
        self.path = path; self.uid = uid; self.read = read
    }

    /// The directory of PREFAB_CONFIG_PATH + "/triggers-write-enabled". In production:
    /// /Users/ericsmith66/Library/Application Support/Prefab/triggers-write-enabled
    static func path(configPath: String) -> String {
        (configPath as NSString).deletingLastPathComponent + "/" + fileName
    }

    /// lstat (never follows a symlink); nil for any error.
    static func lstatAttributes(_ path: String) -> Attributes? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let kind: Attributes.Kind
        switch st.st_mode & S_IFMT {
        case S_IFREG: kind = .regular
        case S_IFLNK: kind = .symlink
        case S_IFDIR: kind = .directory
        default: kind = .other
        }
        return Attributes(kind: kind, uid: st.st_uid, mode: st.st_mode & 0o7777)
    }

    func check() -> Status {
        guard let a = read(path) else { return .invalid(reason: "absent") }
        switch a.kind {
        case .symlink: return .invalid(reason: "symlink")
        case .directory, .other: return .invalid(reason: "not_regular_file")
        case .regular: break
        }
        guard a.uid == uid else { return .invalid(reason: "owner") }
        guard a.mode & 0o7777 == 0o600 else { return .invalid(reason: "mode") }
        return .valid
    }
}

// MARK: - PUT /triggers/:home/:uuid/enabled (FR-07-A2; plan § 6 with amendment A-2)

extension TriggerAPI {
    struct PutResult {
        let status: HTTPResponseStatus
        let payload: [String: Any]
    }

    /// In this order: (1) flag not valid → 403 `{"error":"triggers_write_disabled"}` — no home lookup, no body parse,
    /// no store call; (2) unknown home → 404 what:home; (3) a body that is not a JSON object with a JSON-boolean
    /// `enabled` → 400 what:enabled; (4) unknown trigger → 404 what:trigger; (5) already in that state → 200
    /// changed:false, no HomeKit call; (6) `enable(<b>)` with the guard: no completion → 504 write_timeout; an error →
    /// 502 homekit_error (code, message); isEnabled read back differs → 502 homekit_error code -2; else 200 changed:true.
    /// Every PUT writes exactly ONE outcome line
    ///   `[triggers] <rid> PUT <uuid> enabled=<true|false|?> → <status> <ok|error>[ (<reason>)]`  (reason: flag 403 only)
    /// and one `[triggers] <rid> <uuid> Attempting enable=<b>` line only right before a HomeKit call.
    static func putEnabled(home: String, uuid: String, body: Data?, requestId: String, store: TriggerStore,
                           flag: TriggerWriteFlag, log: (String) -> Void, guardSeconds: TimeInterval) -> PutResult {
        var requested: Bool?
        func done(_ status: HTTPResponseStatus, _ payload: [String: Any], reason: String? = nil) -> PutResult {
            let outcome = status == .ok ? "ok" : (payload["error"] as? String ?? "error")
            let b = requested.map { $0 ? "true" : "false" } ?? "?"
            log("[triggers] \(requestId) PUT \(uuid) enabled=\(b) → \(status.code) \(outcome)" + (reason.map { " (\($0))" } ?? ""))
            return PutResult(status: status, payload: payload)
        }

        if case .invalid(let reason) = flag.check() {
            return done(.forbidden, ["error": "triggers_write_disabled"], reason: reason)
        }
        let found = store.lookup(home: home, uuid: uuid)
        if found == .noHome { return done(.notFound, ["error": "not_found", "what": "home"]) }
        guard let b = enabledValue(body) else { return done(.badRequest, ["error": "bad_request", "what": "enabled"]) }
        requested = b
        guard case .found(let id, let current) = found else { return done(.notFound, ["error": "not_found", "what": "trigger"]) }
        if current == b { return done(.ok, ["changed": false, "enabled": b, "uuid": id.uuidString]) }

        log("[triggers] \(requestId) \(uuid) Attempting enable=\(b)")
        let outcome = Completion()
        store.setEnabled(home: home, uuid: id, enabled: b) { outcome.finish($0) }
        guard let error = outcome.wait(seconds: guardSeconds) else {
            return done(.gatewayTimeout, ["error": "write_timeout"])                       // outcome unknown: GET shows the state
        }
        if let e = error {
            return done(.badGateway, ["error": "homekit_error", "code": e.code, "message": e.message])
        }
        let now = store.isEnabled(home: home, uuid: id)
        guard now == b else {
            let shown = now.map { $0 ? "true" : "false" } ?? "unknown"
            return done(.badGateway, ["error": "homekit_error", "code": -2, "message": "isEnabled is \(shown) after enable(\(b))"])
        }
        return done(.ok, ["changed": true, "enabled": b, "uuid": id.uuidString])
    }

    /// The body must be a JSON object whose `enabled` is a JSON boolean (`"no"`, `1`, `null`, a missing key, bad JSON or
    /// an empty body → nil).
    static func enabledValue(_ body: Data?) -> Bool? {
        guard let body, !body.isEmpty,
              let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let n = obj["enabled"] as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }

    /// The setEnabled completion, waited for at most `seconds`. A completion after the guard expired is dropped.
    private final class Completion {
        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private var result: TriggerStoreError??
        func finish(_ e: TriggerStoreError?) {
            lock.lock(); let first = result == nil; if first { result = .some(e) }; lock.unlock()
            if first { semaphore.signal() }
        }
        /// nil = no completion in time; .some(nil) = success; .some(error) = HomeKit error.
        func wait(seconds: TimeInterval) -> TriggerStoreError?? {
            guard semaphore.wait(timeout: .now() + seconds) == .success else { return nil }
            lock.lock(); defer { lock.unlock() }
            return result
        }
    }
}

// MARK: - The route table (AC-07-03: no other trigger mutation exists)

enum TriggerRoutes {
    /// Exactly these two; no create, delete, rename or edit route.
    static let paths: [(method: String, path: String)] = [("GET", "triggers/:home"), ("PUT", "triggers/:home/:uuid/enabled")]

    /// Called once, from Server.startServer(), after the existing routes.
    static func register(router: HBRouterBuilder, store: TriggerStore, flagPath: String, log: @escaping (String) -> Void,
                         guardSeconds: TimeInterval) {
        register(router: router, store: store, flag: TriggerWriteFlag(path: flagPath), log: log, guardSeconds: guardSeconds)
    }

    static func register(router: HBRouterBuilder, store: TriggerStore, flag: TriggerWriteFlag, log: @escaping (String) -> Void,
                         guardSeconds: TimeInterval) {
        router.get(paths[0].path) { request -> HBResponse in
            let home = request.parameters.get("home").flatMap { $0.removingPercentEncoding } ?? ""
            return json(.ok, try TriggerAPI.getTriggers(home: home, store: store, writeEnabled: flag.check() == .valid))
        }
        router.put(paths[1].path) { request -> HBResponse in
            let home = request.parameters.get("home").flatMap { $0.removingPercentEncoding } ?? ""
            let uuid = request.parameters.get("uuid") ?? ""
            let body = request.body.buffer.map { Data($0.readableBytesView) }
            let r = TriggerAPI.putEnabled(home: home, uuid: uuid, body: body, requestId: request.id, store: store, flag: flag,
                                          log: log, guardSeconds: guardSeconds)
            guard r.status == .ok else { throw PrefabJSONError(status: r.status, payload: r.payload) }
            let data = (try? JSONSerialization.data(withJSONObject: r.payload, options: [.sortedKeys])) ?? Data("{}".utf8)
            return json(.ok, String(decoding: data, as: UTF8.self))
        }
    }

    private static func json(_ status: HTTPResponseStatus, _ body: String) -> HBResponse {
        HBResponse(status: status, headers: ["content-type": "application/json; charset=utf-8"], body: .byteBuffer(ByteBuffer(string: body)))
    }
}

// MARK: - The predicate walker (amendment A-1 / PC-9: Foundation-only, so it is tested hostless — T7A-19)

/// The left key paths of HomeKit's predicates. HMCharacteristicKeyPath, HMCharacteristicValueKeyPath and HMPresenceKeyPath
/// are HomeKit constants; the time and sun key paths are read once from HomeKit's own predicate builders
/// (PredicateKeyPaths.calibrated, in the app's HomeKitTriggerStore). An empty string never matches anything.
struct PredicateKeyPaths: Equatable {
    var time: String
    var significantEvent: String
    var characteristic: String
    var characteristicValue: String
    var presence: String

    func key(_ keyPath: String) -> PredicateKey {
        guard !keyPath.isEmpty else { return .other }
        if keyPath == time { return .time }
        if keyPath == significantEvent { return .significantEvent }
        if keyPath == characteristic { return .characteristic }
        if keyPath == characteristicValue { return .characteristicValue }
        if keyPath == presence { return .presence }
        return .other
    }
}

extension PredicateValue {
    /// Foundation values: DateComponents with an hour → a time of day; a number or a string → a scalar; anything else →
    /// other. The adapter's classifier handles HomeKit's own objects (a significant-time event, a characteristic) first.
    static func foundation(_ v: Any?) -> PredicateValue {
        switch v {
        case let d as DateComponents:
            guard let h = d.hour else { return .other }
            return .timeOfDay(hour: h, minute: d.minute ?? 0)
        case let n as NSNumber: return .scalar(n.stringValue)
        case let s as String: return .scalar(s)
        default: return .other
        }
    }
}

enum PredicateWalker {
    /// NSPredicate → token tree. Any shape it does not know — OR, NOT, a function or subquery expression, an
    /// aggregate modifier, a custom selector, an operator other than < <= == != >= >, an unknown key path, a value the
    /// classifier cannot read, reversed sides, or an AND with ANY child it cannot place — makes the WHOLE tree `.other`,
    /// so `predicate_decoded` is null. Never a partial window (Track B then marks the automation ineligible).
    static func walk(_ predicate: NSPredicate, keys: PredicateKeyPaths,
                     values: (Any?) -> PredicateValue = PredicateValue.foundation) -> PredicateNode {
        if let c = predicate as? NSCompoundPredicate {
            guard c.compoundPredicateType == .and, let subs = c.subpredicates as? [NSPredicate], !subs.isEmpty else { return .other }
            let nodes = subs.map { walk($0, keys: keys, values: values) }
            return nodes.contains(.other) ? .other : .and(nodes)
        }
        // (`customSelector` reads `compare:` even for plain comparisons; a real custom selector is operator type
        // .customSelector, which op(_:) refuses.)
        guard let c = predicate as? NSComparisonPredicate, c.comparisonPredicateModifier == .direct,
              c.leftExpression.expressionType == .keyPath, c.rightExpression.expressionType == .constantValue else { return .other }
        let key = keys.key(c.leftExpression.keyPath)
        guard key != .other, let op = op(c.predicateOperatorType) else { return .other }
        let value = values(c.rightExpression.constantValue)
        guard value != .other else { return .other }
        return .comparison(key: key, op: op, value: value)
    }

    private static func op(_ t: NSComparisonPredicate.Operator) -> ComparisonOp? {
        switch t {
        case .lessThan: return .lt
        case .lessThanOrEqualTo: return .le
        case .equalTo: return .eq
        case .notEqualTo: return .ne
        case .greaterThanOrEqualTo: return .ge
        case .greaterThan: return .gt
        default: return nil
        }
    }
}

// MARK: - Executing an action set (plan § 4's Routes+Scenes row; amendments A-3, A-6)

enum ActionSetLocation: Equatable {
    /// In home.actionSets (a scene, or a set HomeKit also lists among the home's scenes).
    case home
    /// Found only through a trigger's action sets (the hidden "trigger-owned" set of an automation).
    case triggerOnly
    case notFound
}

enum ExecuteDecision: Equatable {
    case execute
    /// 403 `{"error":"triggers_write_disabled"}`, no HomeKit call.
    case refuse
    /// 404 `{"error":"not_found","what":"scene"}`.
    case notFound
}

enum ActionSetExecution {
    /// home.actionSets first, then every trigger's actionSets.
    static func locate(_ id: UUID, homeSets: [UUID], triggerSets: [UUID]) -> ActionSetLocation {
        if homeSets.contains(id) { return .home }
        if triggerSets.contains(id) { return .triggerOnly }
        return .notFound
    }

    /// A home set executes as before (the flag is irrelevant). A set found ONLY through a trigger executes only while the
    /// write flag is valid. A set HomeKit also lists among the home's scenes is `.home`: executable before S″, and still.
    static func executeDecision(location: ActionSetLocation, flagEnabled: Bool) -> ExecuteDecision {
        switch location {
        case .home: return .execute
        case .triggerOnly: return flagEnabled ? .execute : .refuse
        case .notFound: return .notFound
        }
    }

    /// GET /scenes/:home/:scene is read-only: a trigger-only set reads without the flag.
    static func readable(_ location: ActionSetLocation) -> Bool { location != .notFound }

    /// The same 403 as the trigger PUT.
    static let refusal = PrefabJSONError(status: .forbidden, payload: ["error": "triggers_write_disabled"])

    /// One line per execute: `[executeScene] <requestId> <uuid> → <status> <ok|error>`.
    static func logLine(requestId: String, uuid: String, status: Int, outcome: String) -> String {
        "[executeScene] \(requestId) \(uuid) → \(status) \(outcome)"
    }
}
