//
//  Data.swift
//  rikerd
//
//  Created by Kelly Plummer on 2/14/24.
//

import Foundation

struct Home: Encodable, Decodable {
    var name: String
}

struct Room: Encodable, Decodable {
    var home: String
    var name: String
    var isDefaultRoom: Bool?
}

struct Accessory: Encodable, Decodable {
    var home: String
    var room: String
    var name: String
    var uniqueIdentifier: String?
    var isDefaultRoom: Bool?
    var bridgedBy: String?
    
    var category: String?
    var isReachable: Bool?
    var supportsIdentify: Bool?
    var isBridged: Bool?

    var services: [Service]?
    
    var firmwareVersion: String?
    var manufacturer: String?
    var model: String?

    /// S″ (plan R7-8 item 3): set only on full-detail responses — where the values came from: "cache" (HomeKit's cached
    /// values, no device reads; the default) or "live" (`?read=live`). Omitted on list, room and summary items.
    var values: String?
    /// S″: live mode only — how many of the per-characteristic reads failed (those show HomeKit's cached value).
    /// A count for people, not a verification signal: only the single-characteristic read verifies a write.
    var readErrors: Int?

    /// RM-1 (FR-A5, AC-01-07/08; QA PD-6): `bridgedBy` is part of the normative accessory shape, so a non-bridged
    /// accessory carries `"bridgedBy": null` instead of omitting the key. Every other optional keeps the synthesized
    /// behaviour (omitted when nil); decoding stays synthesized (`null` and a missing key both decode to nil).
    /// C2-5 (S″): `values` and `readErrors` are listed here too, or the explicit encoder would silently drop them.
    private enum EncodingKeys: String, CodingKey {
        case home, room, name, uniqueIdentifier, isDefaultRoom, bridgedBy, category, isReachable, supportsIdentify, isBridged,
             services, firmwareVersion, manufacturer, model, values, readErrors
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: EncodingKeys.self)
        try c.encode(home, forKey: .home)
        try c.encode(room, forKey: .room)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(uniqueIdentifier, forKey: .uniqueIdentifier)
        try c.encodeIfPresent(isDefaultRoom, forKey: .isDefaultRoom)
        if let bridgedBy { try c.encode(bridgedBy, forKey: .bridgedBy) } else { try c.encodeNil(forKey: .bridgedBy) }
        try c.encodeIfPresent(category, forKey: .category)
        try c.encodeIfPresent(isReachable, forKey: .isReachable)
        try c.encodeIfPresent(supportsIdentify, forKey: .supportsIdentify)
        try c.encodeIfPresent(isBridged, forKey: .isBridged)
        try c.encodeIfPresent(services, forKey: .services)
        try c.encodeIfPresent(firmwareVersion, forKey: .firmwareVersion)
        try c.encodeIfPresent(manufacturer, forKey: .manufacturer)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(values, forKey: .values)
        try c.encodeIfPresent(readErrors, forKey: .readErrors)
    }
}

struct Service: Encodable, Decodable {
    var uniqueIdentifier: UUID
    var name: String
    var typeName: String
    var type: String
    var isPrimary: Bool
    var isUserInteractive: Bool
    var associatedType: String?
    
    var characteristics: [Characteristic]
}

struct Characteristic: Encodable, Decodable {
    var uniqueIdentifier: UUID
    var description: String
    var properties: [String]
    var typeName: String
    var type: String
    var metadata: CharacteristicMetadata?
    var value: String?
}

struct CharacteristicMetadata: Encodable, Decodable {
    init(manufacturerDescription: String? = nil, validValues: [String]? = nil, minimumValue: String? = nil, maximumValue: String? = nil, stepValue: String? = nil, maxLength: String? = nil, format: String? = nil, units: String? = nil) {
        self.manufacturerDescription = manufacturerDescription
        self.validValues = validValues
        self.minimumValue = minimumValue
        self.maximumValue = maximumValue
        self.stepValue = stepValue
        self.maxLength = maxLength
        self.format = format
        self.units = units
    }
    var manufacturerDescription: String?
    var validValues: [String]?
    var minimumValue: (String)?
    var maximumValue: (String)?
    var stepValue: (String)?
    var maxLength: (String)?
    var format: String?
    var units: String?
}

struct UpdateAccessoryInput: Encodable, Decodable {
    var serviceId: String
    var characteristicId: String
    var value: String
}

enum UnknownFormatError : Error {
    case formatValue(format: String)
}

func GetValue(value: String, format: String) throws -> Any {
    switch format {
    case "bool":
        // S″ (PRD-1-01 plan R7-9 item 6): strict. In any case 1/true/on → true and 0/false/off → false; anything else
        // throws, so performWrite answers 400 {"error":"bad_value","format":"bool"} and writes nothing (S′ wrote false
        // for "abc" or "yes"). updateGroup counts it as failed, as before. Shared with the CLI target (Foundation only).
        switch value.lowercased() {
        case "1", "true", "on": return true
        case "0", "false", "off": return false
        default: throw UnknownFormatError.formatValue(format: format)
        }
    case "uint8":
        guard let v = UInt8(value) else { throw UnknownFormatError.formatValue(format: format) }
        return NSNumber(value: v)
    case "uint16":
        guard let v = UInt16(value) else { throw UnknownFormatError.formatValue(format: format) }
        return NSNumber(value: v)
    case "uint32":
        guard let v = UInt32(value) else { throw UnknownFormatError.formatValue(format: format) }
        return NSNumber(value: v)
    case "uint64":
        guard let v = UInt64(value) else { throw UnknownFormatError.formatValue(format: format) }
        return NSNumber(value: v)
    case "int":
        guard let v = Int(value) else { throw UnknownFormatError.formatValue(format: format) }
        return NSNumber(value: v)
    case "float":
        guard let v = Float(value) else { throw UnknownFormatError.formatValue(format: format) }
        return NSNumber(value: v)
    case "string":
        return value
    default:
        throw UnknownFormatError.formatValue(format: format)
    }
}

// MARK: - Scenes

/// Basic scene info (list view)
struct HomeKitScene: Encodable, Decodable {
    var home: String
    var uniqueIdentifier: UUID
    var name: String
    var isBuiltIn: Bool
}

/// Action within a scene
struct SceneAction: Encodable, Decodable {
    var accessoryName: String
    var serviceName: String
    var characteristicType: String
    var targetValue: String
    var accessoryUniqueIdentifier: String?
    var serviceUniqueIdentifier: String?
    var serviceType: String?
    var characteristicUniqueIdentifier: String?
}

/// Detailed scene info including actions
struct SceneDetail: Encodable, Decodable {
    var home: String
    var uniqueIdentifier: UUID
    var name: String
    var isBuiltIn: Bool
    var actions: [SceneAction]
    var totalActions: Int?
    var decodedActions: Int?
}

// MARK: - Accessory Groups

/// Service within a group
struct GroupService: Encodable, Decodable {
    var accessoryName: String
    var serviceName: String
    var serviceType: String
    var uniqueIdentifier: UUID
}

/// Basic group info (list view)
struct AccessoryGroup: Encodable, Decodable {
    var home: String
    var uniqueIdentifier: UUID
    var name: String
    var serviceCount: Int
}

/// Detailed group info including services
struct AccessoryGroupDetail: Encodable, Decodable {
    var home: String
    var uniqueIdentifier: UUID
    var name: String
    var services: [GroupService]
}

/// Input for updating group characteristics
struct UpdateGroupInput: Encodable, Decodable {
    var characteristicType: String
    var value: String
}
