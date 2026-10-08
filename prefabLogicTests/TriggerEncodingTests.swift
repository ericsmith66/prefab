//
//  TriggerEncodingTests.swift
//  prefabLogicTests — PRD-1-07 Track A, the GET contract (plan § 5): T7A-01 … T7A-07 (and T7A-19 in TA-3).
//  The snapshots stand in for HMTrigger / HMEventTrigger, which cannot be built in a test (the TriggerStore seam).
//

import XCTest
import Hummingbird

let homeName = "Waverly"

func uuid(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }

func writeAction(_ acc: String, _ type: String = "00000025-0000-1000-8000-0026BB765291", _ value: String = "1") -> SceneAction {
    SceneAction(accessoryName: acc, serviceName: "Light", characteristicType: type, targetValue: value,
                accessoryUniqueIdentifier: "ACC-\(acc)", serviceUniqueIdentifier: "SVC-\(acc)", serviceType: "00000043-0000-1000-8000-0026BB765291",
                characteristicUniqueIdentifier: "CHR-\(acc)")
}

func actionSet(_ n: Int, _ name: String, _ kind: ActionSetKind, actions: [SceneAction], total: Int? = nil) -> ActionSetSnapshot {
    ActionSetSnapshot(uuid: uuid(1000 + n), name: name, kind: kind, totalActions: total ?? actions.count, actions: actions)
}

func eventTrigger(_ n: Int, _ name: String, events: [EventSnapshot], endEvents: [EventSnapshot] = [], predicateFormat: String? = nil,
                  predicate: PredicateNode? = nil, recurrences: [DateComponents]? = nil, executeOnce: Bool = false,
                  sets: [ActionSetSnapshot] = [], enabled: Bool = true, lastFire: Date? = nil) -> TriggerSnapshot {
    TriggerSnapshot(uuid: uuid(n), name: name, enabled: enabled, lastFireDate: lastFire,
                    kind: .event(EventTriggerSnapshot(events: events, endEvents: endEvents, predicateFormat: predicateFormat, predicate: predicate,
                                                      recurrences: recurrences, executeOnce: executeOnce)),
                    actionSets: sets)
}

func weekdays(_ apple: Int?...) -> [DateComponents] { apple.map { var d = DateComponents(); d.weekday = $0; return d } }

func calendar(_ h: Int?, _ m: Int?, _ s: Int? = nil) -> EventSnapshot {
    var d = DateComponents(); d.hour = h; d.minute = m; d.second = s
    return .calendar(d)
}

/// Parses the GET body; fails the test on bad JSON.
func parse(_ json: String, file: StaticString = #filePath, line: UInt = #line) -> [String: Any] {
    guard let o = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else {
        XCTFail("not a JSON object: \(json)", file: file, line: line); return [:]
    }
    return o
}

final class TriggerEncodingTests: XCTestCase {
    private func encode(_ triggers: [TriggerSnapshot], writeEnabled: Bool = false) -> String {
        TriggerJSON.encode(home: homeName, triggers: triggers, writeEnabled: writeEnabled)
    }
    private func only(_ json: String) -> [String: Any] {
        ((parse(json)["triggers"] as? [[String: Any]]) ?? [[:]]).first ?? [:]
    }

    // T7A-01 — AC-07-01 fixture (a)
    func test_T7A01_fixtureA_calendar0500_weekdaysMonFri_userDefinedMorning() {
        let morning = actionSet(1, "Morning", .userDefined, actions: (1...4).map { writeAction("Lamp \($0)") })
        let json = encode([eventTrigger(1, "Weekday 05:00", events: [calendar(5, 0)], recurrences: weekdays(2, 3, 4, 5, 6), sets: [morning])])
        XCTAssertTrue(json.contains(#""kind":"event""#), json)
        XCTAssertTrue(json.contains(#""events":[{"hour":5,"minute":0,"type":"calendar"}]"#), json)
        XCTAssertTrue(json.contains(#""recurrence_weekdays":[1,2,3,4,5]"#), json)
        XCTAssertTrue(json.contains(#""timer":null"#), json)
        XCTAssertTrue(json.contains(#""decoded_actions":4,"name":"Morning","total_actions":4,"type":"user_defined""#), json)
        let sets = only(json)["action_sets"] as? [[String: Any]]
        XCTAssertEqual(sets?.count, 1)
        XCTAssertEqual((sets?.first?["actions"] as? [[String: Any]])?.count, 4)
        XCTAssertEqual((sets?.first?["actions"] as? [[String: Any]])?.first?["accessoryName"] as? String, "Lamp 1", "actions are the scene-detail objects")
    }

    // T7A-02 — fixture (b): significant time, offsets
    func test_T7A02_fixtureB_sunsetMinus15min_and_offsets() {
        let json = encode([eventTrigger(1, "Dusk", events: [.significantTime(event: .sunset, offset: DateComponents(minute: -15))])])
        XCTAssertTrue(json.contains(#"{"event":"sunset","offset_s":-900,"type":"significant_time"}"#), json)
        XCTAssertEqual(TriggerJSON.offsetSeconds(DateComponents(hour: 1, minute: 30)), 5400)
        XCTAssertEqual(TriggerJSON.offsetSeconds(DateComponents(minute: -15)), -900)
        XCTAssertEqual(TriggerJSON.offsetSeconds(DateComponents(hour: -1, minute: -2, second: -3)), -3723)
        XCTAssertEqual(TriggerJSON.offsetSeconds(nil), 0)
        let sunrise = encode([eventTrigger(2, "Dawn", events: [.significantTime(event: .sunrise, offset: nil)])])
        XCTAssertTrue(sunrise.contains(#"{"event":"sunrise","offset_s":0,"type":"significant_time"}"#), sunrise)
        let odd = encode([eventTrigger(3, "Odd", events: [.significantTime(event: .unknown, offset: nil)])])
        XCTAssertTrue(odd.contains(#""event":"unknown""#), odd)
    }

    // T7A-03 — fixture (c): characteristic event + presence predicate → the raw predicate, decoded null
    func test_T7A03_fixtureC_characteristicEvent_presencePredicate_rawStringKept_decodedNull() {
        let format = #"presence == <HMPresenceEvent: every entry, current user>"#
        let t = eventTrigger(1, "Arrive", events: [.characteristic(accessoryUUID: "ACC-DOOR", serviceType: "SVC-T", characteristicType: "CHR-T", triggerValue: "1")],
                             predicateFormat: format, predicate: .comparison(key: .presence, op: .eq, value: .other))
        let json = encode([t])
        XCTAssertTrue(json.contains(#"{"accessory_uuid":"ACC-DOOR","characteristic_type":"CHR-T","service_type":"SVC-T","trigger_value":"1","type":"characteristic"}"#), json)
        XCTAssertEqual(only(json)["predicate"] as? String, format)
        XCTAssertTrue(only(json)["predicate_decoded"] is NSNull)
        let noValue = encode([eventTrigger(2, "Any", events: [.characteristic(accessoryUUID: nil, serviceType: nil, characteristicType: "CHR-T", triggerValue: nil)])])
        XCTAssertTrue(noValue.contains(#"{"accessory_uuid":null,"characteristic_type":"CHR-T","service_type":null,"trigger_value":null,"type":"characteristic"}"#), noValue)
    }

    // T7A-04 — fixture (d): action-set types
    func test_T7A04_fixtureD_triggerOwned_builtin_unknown() {
        let sets = [actionSet(1, "", .triggerOwned, actions: [writeAction("Attic", "00000008-0000-1000-8000-0026BB765291", "30")]),
                    actionSet(2, "Good Morning", .builtin, actions: []), actionSet(3, "Odd", .unknown, actions: [], total: 2)]
        let json = encode([eventTrigger(1, "skynet test automation", events: [calendar(3, 33)], sets: sets)])
        let types = (only(json)["action_sets"] as? [[String: Any]])?.map { $0["type"] as? String }
        XCTAssertEqual(types, ["trigger_owned", "builtin", "unknown"], "HomeKit's order")
        XCTAssertTrue(json.contains(#""decoded_actions":0,"name":"Odd","total_actions":2,"type":"unknown""#), json)
    }

    func test_T7A04_actionSetKind_classify() {
        let builtins: Set = ["T.WakeUp", "T.Sleep", "T.HomeDeparture", "T.HomeArrival"]
        func k(_ raw: String) -> ActionSetKind { ActionSetKind.classify(raw, userDefined: "T.UserDefined", triggerOwned: "T.TriggerOwned", builtins: builtins) }
        XCTAssertEqual(k("T.UserDefined"), .userDefined)
        XCTAssertEqual(k("T.TriggerOwned"), .triggerOwned)
        for b in builtins { XCTAssertEqual(k(b), .builtin) }
        XCTAssertEqual(k("T.SomethingNew"), .unknown)
    }

    // T7A-05 — the rest of the event table, end events, execute_once, timer triggers, unknown kinds, weekdays
    func test_T7A05_eventTable() {
        let events: [EventSnapshot] = [
            .threshold(accessoryUUID: "ACC-T", characteristicType: "CHR-TEMP", min: 18.5, max: nil),
            .threshold(accessoryUUID: "ACC-T", characteristicType: "CHR-TEMP", min: nil, max: 25),
            .presence(presenceType: "every_entry", userType: "current_user"),
            .location,
            .duration(seconds: 300),
            .unknown(className: "HMFutureEvent"),
            calendar(6, 30, 15),
        ]
        let json = encode([eventTrigger(1, "Table", events: events, endEvents: [.duration(seconds: 60)], executeOnce: true)])
        for frag in [#"{"accessory_uuid":"ACC-T","characteristic_type":"CHR-TEMP","min":18.5,"type":"threshold"}"#,
                     #"{"accessory_uuid":"ACC-T","characteristic_type":"CHR-TEMP","max":25,"type":"threshold"}"#,
                     #"{"presence_type":"every_entry","type":"presence","user_type":"current_user"}"#,
                     #"{"type":"location"}"#,
                     #"{"seconds":300,"type":"duration"}"#,
                     #"{"class":"HMFutureEvent","type":"unknown"}"#,
                     #"{"hour":6,"minute":30,"second":15,"type":"calendar"}"#,
                     #""end_events":[{"seconds":60,"type":"duration"}]"#,
                     #""execute_once":true"#] {
            XCTAssertTrue(json.contains(frag), "missing \(frag) in \(json)")
        }
    }

    func test_T7A05_timerTrigger_fireDateUTC_setRecurrenceComponents_timeZone_andTheEventFieldsEmpty() throws {
        var rec = DateComponents(); rec.day = 1; rec.weekOfYear = nil
        let fire = Date(timeIntervalSince1970: 1_791_000_000)          // 2026-10-03T04:00:00Z
        let t = TriggerSnapshot(uuid: uuid(7), name: "Legacy timer", enabled: false, lastFireDate: Date(timeIntervalSince1970: 1_790_900_000),
                                kind: .timer(TimerSnapshot(fireDate: fire, recurrence: rec, timeZone: TimeZone(identifier: "America/Chicago"))),
                                actionSets: [])
        let o = only(encode([t]))
        XCTAssertEqual(o["kind"] as? String, "timer")
        let timer = try XCTUnwrap(o["timer"] as? [String: Any])
        XCTAssertEqual(timer["fire_date"] as? String, "2026-10-03T04:00:00Z")
        XCTAssertEqual(timer["recurrence"] as? [String: Int], ["day": 1], "only the set components")
        XCTAssertEqual(timer["time_zone"] as? String, "America/Chicago")
        XCTAssertEqual(o["last_fire_at"] as? String, "2026-10-02T00:13:20Z")
        XCTAssertEqual((o["events"] as? [Any])?.count, 0)
        XCTAssertEqual((o["end_events"] as? [Any])?.count, 0)
        XCTAssertTrue(o["predicate"] is NSNull); XCTAssertTrue(o["predicate_decoded"] is NSNull); XCTAssertTrue(o["recurrence_weekdays"] is NSNull)
        XCTAssertEqual(o["execute_once"] as? Bool, false)
        let noRec = only(encode([TriggerSnapshot(uuid: uuid(8), name: "One shot", enabled: true, lastFireDate: nil,
                                                 kind: .timer(TimerSnapshot(fireDate: fire, recurrence: nil, timeZone: nil)), actionSets: [])]))
        let t2 = try XCTUnwrap(noRec["timer"] as? [String: Any])
        XCTAssertTrue(t2["recurrence"] is NSNull); XCTAssertTrue(t2["time_zone"] is NSNull); XCTAssertTrue(noRec["last_fire_at"] is NSNull)
    }

    func test_T7A05_unknownTriggerKind_carriesEveryKey() throws {
        let o = only(encode([TriggerSnapshot(uuid: uuid(9), name: "Future", enabled: true, lastFireDate: nil, kind: .unknown(className: "HMFutureTrigger"), actionSets: [])]))
        XCTAssertEqual(o["kind"] as? String, "unknown")
        XCTAssertTrue(o["timer"] is NSNull)
        XCTAssertEqual(Set(o.keys), TriggerJSON.triggerKeys)
    }

    func test_T7A05_isoWeekdays() {
        XCTAssertEqual(TriggerJSON.isoWeekdays(weekdays(2, 3, 4, 5, 6)), [1, 2, 3, 4, 5])
        XCTAssertEqual(TriggerJSON.isoWeekdays(weekdays(1)), [7], "Apple Sunday → ISO 7")
        XCTAssertEqual(TriggerJSON.isoWeekdays(weekdays(7, 1)), [6, 7])
        XCTAssertNil(TriggerJSON.isoWeekdays(nil), "no recurrences = every day")
        XCTAssertEqual(TriggerJSON.isoWeekdays(weekdays(2, nil)), [], "a recurrence without a weekday → [] (never every day)")
        XCTAssertEqual(TriggerJSON.isoWeekdays(weekdays(9)), [])
        XCTAssertEqual(TriggerJSON.isoWeekdays(weekdays(0)), [])
        XCTAssertEqual(TriggerJSON.isoWeekdays([]), [], "an empty recurrence list is unreadable, never every day")
        XCTAssertEqual(TriggerJSON.isoWeekdays(weekdays(2, 2, 3)), [1, 2], "duplicates collapse")
        let json = encode([eventTrigger(1, "x", events: [calendar(5, 0)], recurrences: weekdays(2, nil))])
        XCTAssertTrue(json.contains(#""recurrence_weekdays":[]"#), json)
        let every = encode([eventTrigger(2, "y", events: [calendar(5, 0)])])
        XCTAssertTrue(every.contains(#""recurrence_weekdays":null"#), every)
    }

    // T7A-06 — decodePredicate over the token tree
    func test_T7A06_decodePredicate() {
        let after22 = PredicateNode.comparison(key: .time, op: .gt, value: .timeOfDay(hour: 22, minute: 0))
        let before06 = PredicateNode.comparison(key: .time, op: .lt, value: .timeOfDay(hour: 6, minute: 0))
        XCTAssertEqual(TriggerJSON.decodePredicate(.and([after22, before06])),
                       .window(after: .clock(hour: 22, minute: 0), before: .clock(hour: 6, minute: 0)))
        XCTAssertEqual(TriggerJSON.decodePredicate(.and([before06, after22])),
                       .window(after: .clock(hour: 22, minute: 0), before: .clock(hour: 6, minute: 0)), "either order")
        XCTAssertEqual(TriggerJSON.decodePredicate(.comparison(key: .significantEvent, op: .ge, value: .significantEvent(event: "sunset", offsetSeconds: 1800))),
                       .window(after: .sun(event: "sunset", offsetSeconds: 1800), before: nil))
        XCTAssertEqual(TriggerJSON.decodePredicate(.comparison(key: .time, op: .le, value: .timeOfDay(hour: 7, minute: 30))),
                       .window(after: nil, before: .clock(hour: 7, minute: 30)))
        let isLamp = PredicateNode.comparison(key: .characteristic, op: .eq, value: .characteristic(accessoryUUID: "ACC-1", characteristicType: "CHR-BRI"))
        let above50 = PredicateNode.comparison(key: .characteristicValue, op: .gt, value: .scalar("50"))
        XCTAssertEqual(TriggerJSON.decodePredicate(.and([isLamp, above50])),
                       .characteristic(accessoryUUID: "ACC-1", characteristicType: "CHR-BRI", op: .gt, value: "50"))
        XCTAssertEqual(TriggerJSON.decodePredicate(.and([above50, isLamp])),
                       .characteristic(accessoryUUID: "ACC-1", characteristicType: "CHR-BRI", op: .gt, value: "50"))
        XCTAssertNil(TriggerJSON.decodePredicate(.comparison(key: .time, op: .eq, value: .timeOfDay(hour: 5, minute: 0))), "== → null")
        XCTAssertNil(TriggerJSON.decodePredicate(.or([after22, before06])), "OR → null")
        XCTAssertNil(TriggerJSON.decodePredicate(.not(after22)))
        XCTAssertNil(TriggerJSON.decodePredicate(.comparison(key: .presence, op: .eq, value: .other)), "presence → null")
        XCTAssertNil(TriggerJSON.decodePredicate(.other), "garbage → null")
        XCTAssertNil(TriggerJSON.decodePredicate(.and([after22, after22])), "two afters is not a window")
        XCTAssertNil(TriggerJSON.decodePredicate(.and([after22, before06, before06])), "three children → null, never a partial window")
        XCTAssertNil(TriggerJSON.decodePredicate(.comparison(key: .time, op: .gt, value: .scalar("22:00"))), "a time key with a non-time value")
        XCTAssertNil(TriggerJSON.decodePredicate(nil))
        // the JSON of both shapes
        let w = encode([eventTrigger(1, "Night", events: [calendar(23, 0)], predicateFormat: "p", predicate: .and([after22, before06]))])
        XCTAssertTrue(w.contains(#""predicate_decoded":{"after":{"hour":22,"minute":0},"before":{"hour":6,"minute":0},"kind":"window"}"#), w)
        let sun = encode([eventTrigger(2, "Sun", events: [calendar(23, 0)], predicateFormat: "p",
                                       predicate: .comparison(key: .significantEvent, op: .gt, value: .significantEvent(event: "sunset", offsetSeconds: 1800)))])
        XCTAssertTrue(sun.contains(#""predicate_decoded":{"after":{"event":"sunset","offset_s":1800},"before":null,"kind":"window"}"#), sun)
        let c = encode([eventTrigger(3, "Bright", events: [calendar(23, 0)], predicateFormat: "p", predicate: .and([isLamp, above50]))])
        XCTAssertTrue(c.contains(#""predicate_decoded":{"accessory_uuid":"ACC-1","characteristic_type":"CHR-BRI","kind":"characteristic","op":">","value":"50"}"#), c)
    }

    // T7A-07 — top level
    func test_T7A07_topLevel_homeEchoed_countEqualsLen_sortedByNameThenUuid_everyKey() {
        let ts = [eventTrigger(3, "b", events: []), eventTrigger(2, "a", events: []), eventTrigger(1, "b", events: []), eventTrigger(4, "A", events: [])]
        let o = parse(encode(ts, writeEnabled: true))
        XCTAssertEqual(o["home"] as? String, homeName)
        XCTAssertEqual(o["write_enabled"] as? Bool, true)
        let list = (o["triggers"] as? [[String: Any]]) ?? []
        XCTAssertEqual(o["count"] as? Int, list.count)
        XCTAssertEqual(list.map { $0["name"] as? String }, ["A", "a", "b", "b"])
        XCTAssertEqual(list.map { $0["uuid"] as? String }.suffix(2), [uuid(1).uuidString, uuid(3).uuidString], "same name → by uuid")
        for t in list { XCTAssertEqual(Set(t.keys), TriggerJSON.triggerKeys) }
        XCTAssertEqual(TriggerJSON.triggerKeys, ["uuid", "name", "enabled", "last_fire_at", "kind", "timer", "events", "end_events", "predicate",
                                                "predicate_decoded", "recurrence_weekdays", "execute_once", "action_sets"])
        XCTAssertEqual(Set(o.keys), ["home", "count", "write_enabled", "triggers"])
        XCTAssertEqual(parse(encode([], writeEnabled: false))["count"] as? Int, 0)
    }

    func test_T7A07_namesAndPredicates_areJSONEscaped_untruncated() {
        let weird = "Quote \" back\\slash\nnewline\ttab é 🌅 " + String(repeating: "x", count: 300)
        let o = parse(encode([eventTrigger(1, weird, events: [calendar(5, 0)], predicateFormat: weird, sets: [actionSet(1, weird, .userDefined, actions: [])])]))
        let t = ((o["triggers"] as? [[String: Any]]) ?? [[:]])[0]
        XCTAssertEqual(t["name"] as? String, weird)
        XCTAssertEqual(t["predicate"] as? String, weird)
        XCTAssertEqual(((t["action_sets"] as? [[String: Any]]) ?? [[:]])[0]["name"] as? String, weird)
    }

    func test_T7A07_unknownHome_is404_whatHome() throws {
        let store = FakeTriggerStore(homes: [homeName: []])
        XCTAssertThrowsError(try TriggerAPI.getTriggers(home: "Elsewhere", store: store, writeEnabled: false)) { e in
            let j = e as? PrefabJSONError
            XCTAssertEqual(j?.status, .notFound)
            XCTAssertEqual(j?.payload["what"] as? String, "home")
            XCTAssertEqual(j?.payload["error"] as? String, "not_found")
        }
        let ok = try TriggerAPI.getTriggers(home: homeName, store: store, writeEnabled: false)
        XCTAssertEqual(parse(ok)["count"] as? Int, 0)
    }
}
