//
//  ConfigTests.swift
//  prefabLogicTests — config safety (PRD-1-01 plan § 15.18 R7-7, § 15.19 R8-6): PT-139, PT-140.
//
//  R8-6 rule: these tests use temporary directories only. They never touch PrefabConfigManager.shared,
//  PrefabEnvironment.configPath or the trigger flag path, so a test run can never write a config on this Mac.
//

import XCTest

final class ConfigTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("prefab-config-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try FileManager.default.removeItem(at: dir)
    }

    private func fixtureData() throws -> Data {
        let url = try XCTUnwrap(Bundle(for: ConfigTests.self).url(forResource: "production-config-keys", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    /// Key paths with JSON value kinds, the way W1 v2 prints them.
    private func keyPaths(_ data: Data) throws -> [String] {
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        func walk(_ o: [String: Any], _ p: String) -> [String] {
            o.keys.sorted().flatMap { k -> [String] in
                let q = p.isEmpty ? k : p + "." + k
                if let d = o[k] as? [String: Any] { return walk(d, q) }
                return [q]
            }
        }
        return walk(obj, "")
    }

    // MARK: PT-139 — the production key set decodes; the new key is optional; the default no longer polls

    func test_PT139_fixture_isTheProductionKeySet() throws {
        XCTAssertEqual(try keyPaths(fixtureData()), [
            "deviceRegistry.devices", "deviceRegistry.mode",
            "logging.enabled", "logging.logAllCallbacks", "logging.logOnlyChanges", "logging.maxCallbacksPerSecond",
            "polling.enabled", "polling.intervalSeconds", "polling.reportIntervalSeconds",
            "webhook.authToken", "webhook.enabled", "webhook.url",
        ])
    }

    func test_PT139_productionKeySet_decodes_andTheMissingLimitMeansSix() throws {
        let url = dir.appendingPathComponent("config.json")
        try fixtureData().write(to: url)
        let c = try PrefabConfig.loadOrCreate(at: url)
        XCTAssertNil(c.polling.maxReadsPerMinutePerBridge, "absent in an S′ config")
        XCTAssertEqual(c.polling.maxReadsPerMinutePerBridgeOrDefault, 6)
        XCTAssertFalse(c.polling.enabled)
        XCTAssertEqual(c.polling.intervalSeconds, 15.5)
        XCTAssertTrue(c.logging.enabled)
        XCTAssertEqual(c.webhook.authToken, "dummy-not-a-real-token")
        XCTAssertEqual(c.deviceRegistry.mode, .all)
    }

    func test_PT139_explicitLimit_decodes() throws {
        var obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: fixtureData()) as? [String: Any])
        var polling = try XCTUnwrap(obj["polling"] as? [String: Any]); polling["maxReadsPerMinutePerBridge"] = 12; obj["polling"] = polling
        let url = dir.appendingPathComponent("config.json")
        try JSONSerialization.data(withJSONObject: obj).write(to: url)
        XCTAssertEqual(try PrefabConfig.loadOrCreate(at: url).polling.maxReadsPerMinutePerBridgeOrDefault, 12)
    }

    func test_PT139_defaultConfig_hasPollingOff() {
        XCTAssertFalse(PrefabConfig.default.polling.enabled)
        XCTAssertNil(PrefabConfig.default.polling.maxReadsPerMinutePerBridge)
    }

    // MARK: PT-140 — loadOrCreate: missing → default written; decodable → returned untouched; undecodable → throws, nothing written

    func test_PT140_missingFile_writesTheDefault_withPollingOff_andReturnsIt() throws {
        let url = dir.appendingPathComponent("sub/dir/config.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let c = try PrefabConfig.loadOrCreate(at: url)
        XCTAssertFalse(c.polling.enabled)
        let written = try JSONDecoder().decode(PrefabConfig.self, from: Data(contentsOf: url))
        XCTAssertFalse(written.polling.enabled, "the file written for a missing config never polls")
        XCTAssertEqual(written.webhook.url, PrefabConfig.default.webhook.url)
    }

    func test_PT140_decodableFile_isReturned_andItsBytesAreUnchanged() throws {
        let url = dir.appendingPathComponent("config.json")
        let bytes = try fixtureData()
        try bytes.write(to: url)
        _ = try PrefabConfig.loadOrCreate(at: url)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func test_PT140_missingRequiredKey_throws_andNothingIsWritten() throws {
        var obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: fixtureData()) as? [String: Any])
        var webhook = try XCTUnwrap(obj["webhook"] as? [String: Any]); webhook.removeValue(forKey: "url"); obj["webhook"] = webhook
        let url = dir.appendingPathComponent("config.json")
        let bytes = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        try bytes.write(to: url)
        XCTAssertThrowsError(try PrefabConfig.loadOrCreate(at: url)) { e in
            XCTAssertTrue(String(describing: e).hasPrefix("invalid PREFAB_CONFIG_PATH: "), String(describing: e))
            guard case PrefabConfigLoadError.undecodable = e else { return XCTFail("expected .undecodable, got \(e)") }
        }
        XCTAssertEqual(try Data(contentsOf: url), bytes, "an undecodable config is never overwritten")
    }

    func test_PT140_badJSON_throws_andNothingIsWritten() throws {
        let url = dir.appendingPathComponent("config.json")
        let bytes = Data("{\"webhook\": {\"url\": ".utf8)
        try bytes.write(to: url)
        XCTAssertThrowsError(try PrefabConfig.loadOrCreate(at: url)) { e in
            guard case PrefabConfigLoadError.undecodable = e else { return XCTFail("expected .undecodable, got \(e)") }
        }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func test_PT140_unreadablePath_aDirectory_throws_andNothingIsWritten() throws {
        let url = dir.appendingPathComponent("config.json")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        XCTAssertThrowsError(try PrefabConfig.loadOrCreate(at: url)) { e in
            guard case PrefabConfigLoadError.unreadable = e else { return XCTFail("expected .unreadable, got \(e)") }
        }
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue, "still the directory")
    }

    func test_PT140_missingFile_inAReadOnlyDirectory_returnsTheDefault_withoutThrowing() throws {
        // S′'s saveConfig ignored a failed write; loadOrCreate keeps that for the missing-file case only.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        let url = dir.appendingPathComponent("config.json")
        let c = try PrefabConfig.loadOrCreate(at: url)
        XCTAssertFalse(c.polling.enabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
