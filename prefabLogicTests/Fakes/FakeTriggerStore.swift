//
//  FakeTriggerStore.swift
//  prefabLogicTests — a programmable TriggerStore (PRD-1-07 plan § 4). No HomeKit: HMTrigger cannot be built in a test,
//  which is why the routes run against the TriggerStore seam.
//

import Foundation

final class FakeTriggerStore: TriggerStore {
    /// What setEnabled does (T7A-08): flip the state, succeed without flipping, fail, or never call back.
    enum Outcome { case succeed, succeedWithoutFlipping, error(code: Int, message: String), neverComplete }

    private let lock = NSLock()
    private var homes: [String: [TriggerSnapshot]]
    var outcome: Outcome = .succeed
    /// Every store method call, in order — "zero store calls" is checked on this.
    private(set) var calls: [String] = []
    private(set) var setEnabledCalls: [(home: String, uuid: UUID, enabled: Bool)] = []

    init(homes: [String: [TriggerSnapshot]]) { self.homes = homes }

    private func record(_ s: String) { lock.lock(); calls.append(s); lock.unlock() }

    func triggers(home: String) -> [TriggerSnapshot]? {
        record("triggers(\(home))")
        return homes[home]
    }

    func lookup(home: String, uuid: String) -> TriggerLookup {
        record("lookup(\(home),\(uuid))")
        guard let list = homes[home] else { return .noHome }
        guard let t = list.first(where: { $0.uuid.uuidString.caseInsensitiveCompare(uuid) == .orderedSame }) else { return .noTrigger }
        return .found(uuid: t.uuid, enabled: t.enabled)
    }

    func setEnabled(home: String, uuid: UUID, enabled: Bool, completion: @escaping (TriggerStoreError?) -> Void) {
        record("setEnabled(\(home),\(uuid.uuidString),\(enabled))")
        lock.lock(); setEnabledCalls.append((home, uuid, enabled)); lock.unlock()
        switch outcome {
        case .succeed:
            setState(home: home, uuid: uuid, enabled: enabled)
            completion(nil)
        case .succeedWithoutFlipping:
            completion(nil)
        case .error(let code, let message):
            completion(TriggerStoreError(code: code, message: message))
        case .neverComplete:
            break
        }
    }

    func isEnabled(home: String, uuid: UUID) -> Bool? {
        record("isEnabled(\(home),\(uuid.uuidString))")
        return homes[home]?.first(where: { $0.uuid == uuid })?.enabled
    }

    func setState(home: String, uuid: UUID, enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard var list = homes[home], let i = list.firstIndex(where: { $0.uuid == uuid }) else { return }
        list[i].enabled = enabled
        homes[home] = list
    }
}
