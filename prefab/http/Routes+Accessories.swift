//
//  Routes+Accessories.swift
//  Prefab
//
//  Created by kelly on 2/25/24.
//

import Foundation
import HomeKit
import Hummingbird
import OSLog

extension Server {
    func findHome(_ request: HBRequest) throws -> HMHome {
        let homeName = try getRequiredParam(param: "home", request: request)
        guard let home = homeBase.homes.first(where: { $0.name == homeName.removingPercentEncoding }) else { throw PrefabJSONError.notFound("home") }
        return home
    }

    /// P17: an accessory is in the Default Room when it has no room or its room IS roomForEntireHome — never by the literal name.
    func isDefaultRoom(_ a: HMAccessory, in home: HMHome) -> Bool {
        guard let room = a.room else { return true }
        return room.uniqueIdentifier == home.roomForEntireHome().uniqueIdentifier
    }

    func roomName(_ a: HMAccessory, in home: HMHome) -> String { a.room?.name ?? home.roomForEntireHome().name }

    /// bridged accessory uuid → bridge uuid, inverted from each bridge's uniqueIdentifiersForBridgedAccessories (FR-A5).
    func bridgeMap(_ home: HMHome) -> [UUID: UUID] {
        var map: [UUID: UUID] = [:]
        for bridge in home.accessories { for id in bridge.uniqueIdentifiersForBridgedAccessories ?? [] { map[id] = bridge.uniqueIdentifier } }
        return map
    }

    /// Accessories of a room by name over home.accessories, so the Default Room resolves by its localized name.
    func accessories(in home: HMHome, roomNamed name: String) -> [HMAccessory]? {
        guard home.rooms.contains(where: { $0.name == name }) || home.roomForEntireHome().name == name else { return nil }
        return home.accessories.filter { roomName($0, in: home) == name }
    }

    func findAccessory(byId uuidString: String, in home: HMHome) throws -> HMAccessory {
        guard let uuid = UUID(uuidString: uuidString), let a = home.accessories.first(where: { $0.uniqueIdentifier == uuid }) else {
            throw PrefabJSONError.notFound("accessory")
        }
        return a
    }

    func summaryJSON(_ a: HMAccessory, in home: HMHome, bridges: [UUID: UUID]) -> Accessory {
        Accessory(home: home.name, room: roomName(a, in: home), name: a.name,
                  uniqueIdentifier: a.uniqueIdentifier.uuidString, isDefaultRoom: isDefaultRoom(a, in: home),
                  bridgedBy: bridges[a.uniqueIdentifier]?.uuidString, category: a.category.localizedDescription,
                  isReachable: a.isReachable, isBridged: a.isBridged, firmwareVersion: a.firmwareVersion,
                  manufacturer: a.manufacturer, model: a.model)
    }

    func detailJSON(_ a: HMAccessory, in home: HMHome) -> Accessory {
        var acc = summaryJSON(a, in: home, bridges: bridgeMap(home))
        acc.supportsIdentify = a.supportsIdentify
        acc.services = a.services.map { service in
            Service(uniqueIdentifier: service.uniqueIdentifier, name: service.name,
                    typeName: getHAPServiceInfo(fromUUIDString: service.serviceType)?.name ?? "", type: service.serviceType,
                    isPrimary: service.isPrimaryService, isUserInteractive: service.isUserInteractive, associatedType: service.associatedServiceType,
                    characteristics: service.characteristics.map { char in
                        Characteristic(uniqueIdentifier: char.uniqueIdentifier, description: char.localizedDescription, properties: char.properties,
                                       typeName: getHAPCharacteristicInfo(fromUUIDString: char.characteristicType)?.name ?? "", type: char.characteristicType,
                                       metadata: CharacteristicMetadata(manufacturerDescription: char.metadata?.manufacturerDescription,
                                                                        validValues: char.metadata?.validValues?.map { $0.stringValue },
                                                                        minimumValue: char.metadata?.minimumValue?.stringValue, maximumValue: char.metadata?.maximumValue?.stringValue,
                                                                        stepValue: char.metadata?.stepValue?.stringValue, maxLength: char.metadata?.maxLength?.stringValue,
                                                                        format: char.metadata?.format, units: char.metadata?.units),
                                       value: "\(char.value ?? "")")
                    })
        }
        return acc
    }

    /// GET /accessories/:home — List all accessories over home.accessories (P17: the Default Room included; no characteristic reads)
    /// Optional query filters (all combinable):
    ///   ?reachable=true|false
    ///   ?room=RoomName            (compared with roomName(_:in:), so the Default Room filters by its localized name)
    ///   ?category=CategoryName
    ///   ?manufacturer=ManufacturerName
    func getAllAccessories(_ request: HBRequest) throws -> String {
        let home = try findHome(request)

        let reachableFilter: Bool? = request.uri.queryParameters.get("reachable")
            .flatMap { Bool($0) }
        let roomFilter: String? = request.uri.queryParameters.get("room")?
            .removingPercentEncoding
        let categoryFilter: String? = request.uri.queryParameters.get("category")?
            .removingPercentEncoding
        let manufacturerFilter: String? = request.uri.queryParameters.get("manufacturer")?
            .removingPercentEncoding

        let bridges = bridgeMap(home)
        var accessories: [Accessory] = []
        for hmAccessory in home.accessories {
            if let filter = roomFilter, roomName(hmAccessory, in: home) != filter { continue }
            if let filter = reachableFilter, hmAccessory.isReachable != filter { continue }
            if let filter = categoryFilter,
               hmAccessory.category.localizedDescription.lowercased() != filter.lowercased() { continue }
            if let filter = manufacturerFilter,
               (hmAccessory.manufacturer ?? "").lowercased() != filter.lowercased() { continue }
            accessories.append(summaryJSON(hmAccessory, in: home, bridges: bridges))
        }

        let jsonData = try JSONEncoder().encode(accessories)
        return String(data: jsonData, encoding: .utf8)!
    }

    /// GET /accessories/:home/summary — Counts and rollups for dashboard use, over home.accessories (P17)
    func getAccessorySummary(_ request: HBRequest) throws -> String {
        let home = try findHome(request)

        var total = 0
        var reachable = 0
        var byCategory: [String: Int] = [:]
        var byRoom: [String: Int] = [:]
        var byManufacturer: [String: Int] = [:]
        var unreachableByManufacturer: [String: Int] = [:]
        var unreachableByRoom: [String: Int] = [:]

        for hmAccessory in home.accessories {
            total += 1
            let category = hmAccessory.category.localizedDescription.isEmpty
                ? "Uncategorized" : hmAccessory.category.localizedDescription
            let manufacturer = (hmAccessory.manufacturer ?? "Unknown")
            let room = roomName(hmAccessory, in: home)

            byCategory[category, default: 0] += 1
            byRoom[room, default: 0] += 1
            byManufacturer[manufacturer, default: 0] += 1

            if hmAccessory.isReachable {
                reachable += 1
            } else {
                unreachableByManufacturer[manufacturer, default: 0] += 1
                unreachableByRoom[room, default: 0] += 1
            }
        }

        let summary: [String: Any] = [
            "total": total,
            "reachable": reachable,
            "unreachable": total - reachable,
            "byCategory": byCategory,
            "byRoom": byRoom,
            "byManufacturer": byManufacturer,
            "unreachableByManufacturer": unreachableByManufacturer,
            "unreachableByRoom": unreachableByRoom
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
        return String(data: jsonData, encoding: .utf8)!
    }

    /// GET /accessories/:home/:room — the room's accessories over home.accessories; the Default Room resolves by its name (P17)
    func getAccessories(_ request: HBRequest) throws -> String {
        let home = try findHome(request)
        let room = try getRequiredParam(param: "room", request: request).removingPercentEncoding ?? ""
        guard let list = accessories(in: home, roomNamed: room) else { throw PrefabJSONError.notFound("room") }
        let bridges = bridgeMap(home)
        let jsonData = try JSONEncoder().encode(list.map { summaryJSON($0, in: home, bridges: bridges) })
        return String(data: jsonData, encoding: .utf8)!
    }
    
    
    /// GET /accessories/:home/:room/:accessory (name route) — full detail; reads bounded by the 12 s guard (O31).
    func getAccessory(_ request: HBRequest) throws -> String {
        let home = try findHome(request)
        let room = try getRequiredParam(param: "room", request: request).removingPercentEncoding ?? ""
        let name = try getRequiredParam(param: "accessory", request: request).removingPercentEncoding ?? ""
        guard let list = accessories(in: home, roomNamed: room) else { throw PrefabJSONError.notFound("room") }
        guard let accessory = list.first(where: { $0.name == name }) else { throw PrefabJSONError.notFound("accessory") }
        try readAll(accessory)
        return String(data: try JSONEncoder().encode(detailJSON(accessory, in: home)), encoding: .utf8)!
    }

    /// readValue on every characteristic (as today), bounded by the 12 s full-detail guard → 504 read_timeout (O31).
    func readAll(_ accessory: HMAccessory) throws {
        let group = DispatchGroup()
        for service in accessory.services { for char in service.characteristics { group.enter(); char.readValue { _ in group.leave() } } }
        if group.wait(timeout: .now() + PrefabTimeouts.readAllSeconds) == .timedOut {
            throw PrefabJSONError(status: .gatewayTimeout, payload: ["error": "read_timeout"])
        }
    }

    /// Exactly one readValue, bounded by the 5 s single-characteristic guard (S2).
    func readOne(_ accessory: HMAccessory, characteristicId: String) throws -> CharacteristicRead {
        guard let char = accessory.services.flatMap({ $0.characteristics })
                .first(where: { $0.uniqueIdentifier.uuidString.caseInsensitiveCompare(characteristicId) == .orderedSame }) else {
            throw PrefabJSONError.notFound("characteristic")
        }
        HomeBase.shared.logToFile("[readOne] \(char.uniqueIdentifier.uuidString) readValue")
        let box = ErrorBox()
        let group = DispatchGroup(); group.enter()
        char.readValue { error in box.error = error; group.leave() }
        if group.wait(timeout: .now() + PrefabTimeouts.readOneSeconds) == .timedOut {
            throw PrefabJSONError(status: .gatewayTimeout, payload: ["error": "read_timeout"])
        }
        // RM-4 (QA M3): a failed device read is a typed 502, never HomeKit's cached value presented as a live read.
        // Rails (PR 1a) maps any non-2xx read-back to verified: nil, reason readback_failed.
        if let error = box.error {
            let code = (error as NSError).code
            HomeBase.shared.logToFile("[readOne] \(char.uniqueIdentifier.uuidString) → 502 read_failed \(code)")
            throw PrefabJSONError(status: .badGateway, payload: ["error": "read_failed", "hm_code": code, "message": error.localizedDescription])
        }
        return CharacteristicRead(uniqueIdentifier: accessory.uniqueIdentifier.uuidString, isReachable: accessory.isReachable,
            characteristic: CharacteristicValue(uniqueIdentifier: char.uniqueIdentifier.uuidString, type: char.characteristicType,
                typeName: getHAPCharacteristicInfo(fromUUIDString: char.characteristicType)?.name ?? "",
                value: char.value.map { "\($0)" }, format: char.metadata?.format))
    }

    /// GET /accessories/:home/id/:uuid[?characteristic=<uuid>] (FR-A4)
    func getAccessoryById(_ request: HBRequest) throws -> String {
        let home = try findHome(request)
        let accessory = try findAccessory(byId: try getRequiredParam(param: "uuid", request: request), in: home)
        if let charId = request.uri.queryParameters.get("characteristic")?.removingPercentEncoding {
            return String(data: try JSONEncoder().encode(try readOne(accessory, characteristicId: charId)), encoding: .utf8)!
        }
        try readAll(accessory)
        return String(data: try JSONEncoder().encode(detailJSON(accessory, in: home)), encoding: .utf8)!
    }

    /// PUT /accessories/:home/id/:uuid (FR-A4) — same contract as the name route (Task A5).
    func updateAccessoryById(_ request: HBRequest) throws -> String {
        let accessory = try logWriteResolution(request) { () throws -> HMAccessory in
            let home = try findHome(request)
            return try findAccessory(byId: try getRequiredParam(param: "uuid", request: request), in: home)
        }
        return try performWrite(request, accessory: accessory)
    }

    /// PUT /accessories/:home/:room/:accessory (name route; the dashboard sync uses it until PRD-1-03).
    func updateAccessory(_ request: HBRequest) throws -> String {
        let accessory = try logWriteResolution(request) { () throws -> HMAccessory in
            let home = try findHome(request)
            let room = try getRequiredParam(param: "room", request: request).removingPercentEncoding ?? ""
            let name = try getRequiredParam(param: "accessory", request: request).removingPercentEncoding ?? ""
            guard let list = accessories(in: home, roomNamed: room) else { throw PrefabJSONError.notFound("room") }
            guard let accessory = list.first(where: { $0.name == name }) else { throw PrefabJSONError.notFound("accessory") }
            return accessory
        }
        return try performWrite(request, accessory: accessory)
    }

    /// RM-5 (FR-A3, QA PD-7): the write path's resolution failures (404 home/room/accessory) are appended to the debug
    /// log like every other outcome — "[updateAccessory] <requestId> - → 404 not_found <what>" — then rethrown unchanged.
    func logWriteResolution(_ request: HBRequest, _ resolve: () throws -> HMAccessory) throws -> HMAccessory {
        do {
            return try resolve()
        } catch let error as PrefabJSONError {
            HomeBase.shared.logToFile("[updateAccessory] \(request.id) - → \(error.status.code) \(error.payload["error"] ?? "") \(error.payload["what"] ?? "")")
            throw error
        }
    }

    /// FR-A3. Status codes and `error` strings are normative. Debug log (logToFile, precondition logging.enabled):
    /// "[updateAccessory] <requestId> <characteristicUUID> → <status> <error|ok>"; "Attempting write" is logged
    /// immediately before writeValue and never when no write is attempted (AC-01-04/06).
    func performWrite(_ request: HBRequest, accessory: HMAccessory) throws -> String {
        let requestId = request.id
        let log = HomeBase.shared
        func fail(_ status: HTTPResponseStatus, _ payload: [String: Any], charId: String = "-") -> PrefabJSONError {
            log.logToFile("[updateAccessory] \(requestId) \(charId) → \(status.code) \(payload["error"] ?? "")")
            return PrefabJSONError(status: status, payload: payload)
        }
        guard let bodyBuffer = request.body.buffer, bodyBuffer.readableBytes > 0,
              let input = try? JSONDecoder().decode(UpdateAccessoryInput.self, from: bodyBuffer) else {
            throw fail(.badRequest, ["error": "bad_request"])
        }
        guard let hkService = accessory.services.first(where: { $0.uniqueIdentifier.uuidString.caseInsensitiveCompare(input.serviceId) == .orderedSame }) else {
            throw fail(.notFound, ["error": "not_found", "what": "service"])
        }
        guard let hkChar = hkService.characteristics.first(where: { $0.uniqueIdentifier.uuidString.caseInsensitiveCompare(input.characteristicId) == .orderedSame }) else {
            throw fail(.notFound, ["error": "not_found", "what": "characteristic"])
        }
        let charId = hkChar.uniqueIdentifier.uuidString

        #if DEBUG
        // V5-10: PREFAB_FAULT short-circuits after the characteristic is resolved and before decoding/writeValue — nothing is actuated.
        if let fault = PrefabEnvironment.fault {
            if fault == "write_timeout" {
                Thread.sleep(forTimeInterval: PrefabTimeouts.writeSeconds)
                throw fail(.gatewayTimeout, ["error": "write_timeout"], charId: charId)
            }
            throw fail(.badGateway, ["error": "write_failed", "hm_code": -1, "message": "injected by PREFAB_FAULT"], charId: charId)
        }
        #endif

        guard accessory.isReachable else { throw fail(.serviceUnavailable, ["error": "unreachable"], charId: charId) }   // no write attempted

        let format = hkChar.metadata?.format ?? ""
        guard let valueToWrite = try? GetValue(value: input.value, format: format) else {
            throw fail(.badRequest, ["error": "bad_value", "format": format], charId: charId)
        }

        log.logToFile("[updateAccessory] \(requestId) \(charId) Attempting write value=\(input.value)")
        let box = ErrorBox()
        let group = DispatchGroup(); group.enter()
        hkChar.writeValue(valueToWrite) { error in box.error = error; group.leave() }
        if group.wait(timeout: .now() + PrefabTimeouts.writeSeconds) == .timedOut {        // today: unbounded
            throw fail(.gatewayTimeout, ["error": "write_timeout"], charId: charId)
        }
        if let error = box.error {
            let code = (error as NSError).code
            throw fail(.badGateway, ["error": "write_failed", "hm_code": code, "message": error.localizedDescription], charId: charId)
        }
        log.logToFile("[updateAccessory] \(requestId) \(charId) → 200 ok")
        return String(data: try JSONEncoder().encode(WriteResult(ok: true, characteristicId: charId, value: input.value)), encoding: .utf8)!
    }
}

/// Completion-handler result holder (the completion fires once, before group.leave()).
final class ErrorBox { var error: Error? }
