//
//  HomeKitTriggerStore.swift
//  Prefab — PRD-1-07 Track A: the TriggerStore over HomeKit (app target only; `import HomeKit`).
//
//  Converts HMTrigger / HMEventTrigger / HMTimerTrigger and their events and action sets into the core snapshots that
//  TriggerJSON encodes (plan § 5's mapping table). Everything is read from HomeKit's in-memory model: no readValue,
//  no request to an accessory. The only HomeKit call is HMTrigger.enable(_:) on a PUT that passed the flag.
//  HomeKit objects are read on Hummingbird's threads, as every existing route has done since 2024 (R7A-5).
//

import Foundation
import HomeKit

final class HomeKitTriggerStore: TriggerStore {
    private func home(_ name: String) -> HMHome? { HomeBase.shared.homes.first { $0.name == name } }
    private func trigger(_ home: HMHome, _ uuid: UUID) -> HMTrigger? { home.triggers.first { $0.uniqueIdentifier == uuid } }

    func triggers(home name: String) -> [TriggerSnapshot]? {
        guard let h = home(name) else { return nil }
        let keys = PredicateKeyPaths.calibrated
        return h.triggers.map { Self.snapshot($0, keys: keys) }
    }

    func lookup(home name: String, uuid: String) -> TriggerLookup {
        guard let h = home(name) else { return .noHome }
        guard let t = h.triggers.first(where: { $0.uniqueIdentifier.uuidString.caseInsensitiveCompare(uuid) == .orderedSame }) else { return .noTrigger }
        return .found(uuid: t.uniqueIdentifier, enabled: t.isEnabled)
    }

    func setEnabled(home name: String, uuid: UUID, enabled: Bool, completion: @escaping (TriggerStoreError?) -> Void) {
        guard let h = home(name), let t = trigger(h, uuid) else {
            completion(TriggerStoreError(code: -1, message: "trigger not found")); return
        }
        t.enable(enabled) { error in
            completion(error.map { TriggerStoreError(code: ($0 as NSError).code, message: $0.localizedDescription) })
        }
    }

    func isEnabled(home name: String, uuid: UUID) -> Bool? {
        guard let h = home(name), let t = trigger(h, uuid) else { return nil }
        return t.isEnabled
    }

    // MARK: snapshots (plan § 5)

    static func snapshot(_ t: HMTrigger, keys: PredicateKeyPaths) -> TriggerSnapshot {
        let kind: TriggerSnapshot.Kind
        if let e = t as? HMEventTrigger {
            kind = .event(EventTriggerSnapshot(events: e.events.map(event), endEvents: e.endEvents.map(event),
                                               predicateFormat: e.predicate?.predicateFormat,
                                               predicate: e.predicate.map { PredicateWalker.walk($0, keys: keys, values: predicateValue) },
                                               recurrences: e.recurrences, executeOnce: e.executeOnce))
        } else if let timer = t as? HMTimerTrigger {
            kind = .timer(TimerSnapshot(fireDate: timer.fireDate, recurrence: timer.recurrence, timeZone: timer.timeZone))
        } else {
            kind = .unknown(className: String(describing: type(of: t)))
        }
        // lastFireDate is "No longer supported" (deprecated, iOS 17): it may always be nil → last_fire_at null.
        return TriggerSnapshot(uuid: t.uniqueIdentifier, name: t.name, enabled: t.isEnabled, lastFireDate: t.lastFireDate,
                               kind: kind, actionSets: t.actionSets.map(actionSet))
    }

    static func event(_ e: HMEvent) -> EventSnapshot {
        switch e {
        case let c as HMCalendarEvent:
            return .calendar(c.fireDateComponents)
        case let s as HMSignificantTimeEvent:
            return .significantTime(event: significant(s.significantEvent), offset: s.offset)
        case let c as HMCharacteristicEvent<NSCopying>:
            return .characteristic(accessoryUUID: c.characteristic.service?.accessory?.uniqueIdentifier.uuidString,
                                   serviceType: c.characteristic.service?.serviceType,
                                   characteristicType: c.characteristic.characteristicType,
                                   triggerValue: c.triggerValue.map { "\($0)" })
        case let r as HMCharacteristicThresholdRangeEvent:
            return .threshold(accessoryUUID: r.characteristic.service?.accessory?.uniqueIdentifier.uuidString,
                              characteristicType: r.characteristic.characteristicType,
                              min: r.thresholdRange.minValue?.doubleValue, max: r.thresholdRange.maxValue?.doubleValue)
        case let p as HMPresenceEvent:
            return .presence(presenceType: presenceType(p.presenceEventType), userType: userType(p.presenceUserType))
        case is HMLocationEvent:
            return .location                                                   // never the region's coordinates
        case let d as HMDurationEvent:
            return .duration(seconds: d.duration)
        default:
            return .unknown(className: String(describing: type(of: e)))
        }
    }

    static func significant(_ e: HMSignificantEvent) -> SignificantEvent {
        if e == .sunrise { return .sunrise }
        if e == .sunset { return .sunset }
        return .unknown
    }

    /// HomeKit's at_home / not_at_home are aliases of first_entry / last_exit (same raw values), so they read as those.
    static func presenceType(_ t: HMPresenceEventType) -> String {
        switch t {
        case .everyEntry: return "every_entry"
        case .everyExit: return "every_exit"
        case .firstEntry: return "first_entry"
        case .lastExit: return "last_exit"
        @unknown default: return "unknown"
        }
    }

    static func userType(_ u: HMPresenceEventUserType) -> String {
        switch u {
        case .currentUser: return "current_user"
        case .homeUsers: return "home_users"
        case .customUsers: return "custom_users"
        @unknown default: return "unknown"
        }
    }

    static func actionSet(_ a: HMActionSet) -> ActionSetSnapshot {
        ActionSetSnapshot(uuid: a.uniqueIdentifier, name: a.name,
                          kind: ActionSetKind.classify(a.actionSetType, userDefined: HMActionSetTypeUserDefined,
                                                       triggerOwned: HMActionSetTypeTriggerOwned,
                                                       builtins: [HMActionSetTypeWakeUp, HMActionSetTypeSleep,
                                                                  HMActionSetTypeHomeDeparture, HMActionSetTypeHomeArrival]),
                          totalActions: a.actions.count, actions: actionSnapshots(of: a))
    }

    /// The walker's classifier: HomeKit's own constants first (a significant-time event, a characteristic), then Foundation.
    static func predicateValue(_ v: Any?) -> PredicateValue {
        if let s = v as? HMSignificantTimeEvent {
            return .significantEvent(event: significant(s.significantEvent).rawValue, offsetSeconds: TriggerJSON.offsetSeconds(s.offset))
        }
        if let c = v as? HMCharacteristic {
            return .characteristic(accessoryUUID: c.service?.accessory?.uniqueIdentifier.uuidString ?? "", characteristicType: c.characteristicType)
        }
        return PredicateValue.foundation(v)
    }
}

extension PredicateKeyPaths {
    /// Calibrated once from HomeKit's own predicate builders (plan § 5 "Key-path calibration"; A-1): the left key path of
    /// "before 01:00" is the time key, that of "after sunset" the significant-event key. Nothing is hard-coded; if a
    /// builder ever returns another shape, its key stays "" and matches nothing, so such predicates decode to null.
    static let calibrated: PredicateKeyPaths = {
        func leftKeyPath(_ p: NSPredicate) -> String {
            guard let c = p as? NSComparisonPredicate, c.leftExpression.expressionType == .keyPath else { return "" }
            return c.leftExpression.keyPath
        }
        return PredicateKeyPaths(
            time: leftKeyPath(HMEventTrigger.predicateForEvaluatingTrigger(occurringBefore: DateComponents(hour: 1))),
            significantEvent: leftKeyPath(HMEventTrigger.predicateForEvaluatingTriggerOccurring(
                afterSignificantEvent: HMSignificantTimeEvent(significantEvent: .sunset, offset: nil))),
            characteristic: HMCharacteristicKeyPath, characteristicValue: HMCharacteristicValueKeyPath, presence: HMPresenceKeyPath)
    }()
}

/// The characteristic-write actions of an action set, as GET /scenes/:home/:scene shows them — shared by that route and
/// the trigger GET (plan § 4).
func actionSnapshots(of actionSet: HMActionSet) -> [SceneAction] {
    actionSet.actions.compactMap { $0 as? HMCharacteristicWriteAction<NSCopying> }.map { a in
        SceneAction(accessoryName: a.characteristic.service?.accessory?.name ?? "", serviceName: a.characteristic.service?.name ?? "",
                    characteristicType: a.characteristic.characteristicType, targetValue: "\(a.targetValue)",
                    accessoryUniqueIdentifier: a.characteristic.service?.accessory?.uniqueIdentifier.uuidString,
                    serviceUniqueIdentifier: a.characteristic.service?.uniqueIdentifier.uuidString,
                    serviceType: a.characteristic.service?.serviceType,
                    characteristicUniqueIdentifier: a.characteristic.uniqueIdentifier.uuidString)
    }
}
