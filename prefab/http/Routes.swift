//
//  Routes.swift
//  rikerd
//
//  Created by Kelly Plummer on 2/14/24.
//

import Foundation
import HomeKit
import Hummingbird
import OSLog

extension Server {
    /// GET /version (FR-A2) — exempt from the HomeKit auth middleware, so parity is provable even at 403.
    func getVersion(_ request: HBRequest) throws -> String {
        let info = VersionInfo(
            git_sha: PrefabBuildInfo.current.gitSHA, git_dirty: PrefabBuildInfo.current.gitDirty,
            built_at: PrefabBuildInfo.current.builtAt, bundle_version: PrefabBuildInfo.bundleVersion,
            bind: "127.0.0.1:\(PrefabEnvironment.port)", bonjour: false,
            config_path: PrefabEnvironment.configPath, debug_log: PrefabEnvironment.logPath,
            timeouts: VersionTimeouts())
        return String(data: try JSONEncoder().encode(info), encoding: .utf8)!
    }
}

// MARK: - PRD-1-01 (FR-A2/A3/A4): version, single-characteristic read, write result, typed JSON errors

struct VersionTimeouts: Encodable {
    var write_s = Int(PrefabTimeouts.writeSeconds)
    var scene_s = Int(PrefabTimeouts.sceneSeconds)
    var read_all_s = Int(PrefabTimeouts.readAllSeconds)
    var read_one_s = Int(PrefabTimeouts.readOneSeconds)
}

struct VersionInfo: Encodable {
    var git_sha: String; var git_dirty: Bool; var built_at: String; var bundle_version: String
    var bind: String; var bonjour: Bool; var config_path: String; var debug_log: String
    var timeouts: VersionTimeouts
}

struct CharacteristicValue: Encodable { var uniqueIdentifier: String; var type: String; var typeName: String; var value: String?; var format: String? }
struct CharacteristicRead: Encodable { var uniqueIdentifier: String; var isReachable: Bool; var characteristic: CharacteristicValue }
struct WriteResult: Encodable { var ok: Bool; var characteristicId: String; var value: String }

// `PrefabJSONError` moved unchanged to prefab/core/PrefabHTTPCore.swift (S″ S2-1: the hostless logic tests use it).

/// RM-1 (FR-A4 shape; QA m3): `value` and `format` are keys of the single-characteristic read's `characteristic`
/// object — encoded as JSON null when HomeKit has none, instead of being omitted.
extension CharacteristicValue {
    private enum EncodingKeys: String, CodingKey { case uniqueIdentifier, type, typeName, value, format }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: EncodingKeys.self)
        try c.encode(uniqueIdentifier, forKey: .uniqueIdentifier)
        try c.encode(type, forKey: .type)
        try c.encode(typeName, forKey: .typeName)
        if let value { try c.encode(value, forKey: .value) } else { try c.encodeNil(forKey: .value) }
        if let format { try c.encode(format, forKey: .format) } else { try c.encodeNil(forKey: .format) }
    }
}
