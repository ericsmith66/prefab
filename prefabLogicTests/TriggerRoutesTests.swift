//
//  TriggerRoutesTests.swift
//  prefabLogicTests — PRD-1-07 Track A, the write route and the flag (plan § 6, amendments A-2, A-3): T7A-08 … T7A-10.
//  The routes run on a real Hummingbird router in HummingbirdXCT's `.embedded` mode, against FakeTriggerStore.
//  R8-6: the flag lives in a temporary directory, never the production path.
//

import XCTest
import Hummingbird
import HummingbirdXCT

final class TriggerRoutesTests: XCTestCase {
    private var dir: URL!
    private var flagPath: String { dir.appendingPathComponent("triggers-write-enabled").path }
    private var store: FakeTriggerStore!
    private var sink: LineSink!
    private let on = uuid(1), off = uuid(2)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("prefab-trigger-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = FakeTriggerStore(homes: [homeName: [eventTrigger(1, "Morning lights", events: [calendar(5, 0)], enabled: true),
                                                    eventTrigger(2, "skynet test automation", events: [calendar(3, 33)], enabled: false)]])
        sink = LineSink()
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func createFlag(mode: Int = 0o600) throws {
        try Data("FR-07-A4 proof 2026-10-08, Eric present\n".utf8).write(to: URL(fileURLWithPath: flagPath))
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: flagPath)
    }

    /// A router with the trigger routes registered, as Server.startServer() registers them (plus the flag reader).
    private func withApp(flag: TriggerWriteFlag? = nil, _ body: (HBApplication) throws -> Void) throws {
        let app = HBApplication(testing: .embedded)
        TriggerRoutes.register(router: app.router, store: store, flag: flag ?? TriggerWriteFlag(path: flagPath),
                               log: { [sink] in sink!.append($0) }, guardSeconds: PrefabTimeouts.writeSeconds)
        try app.XCTStart()
        defer { app.XCTStop() }
        try body(app)
    }

    private struct Answer { var status: HTTPResponseStatus; var body: String; var contentType: String? }

    private func put(_ app: HBApplication, _ u: String, _ body: String?, home: String = homeName) throws -> Answer {
        try app.XCTExecute(uri: "/triggers/\(home)/\(u)/enabled", method: .PUT, headers: ["content-type": "application/json"],
                           body: body.map { ByteBuffer(string: $0) }) { r in
            Answer(status: r.status, body: r.body.map { String(buffer: $0) } ?? "", contentType: r.headers.first(name: "content-type"))
        }
    }

    private func get(_ app: HBApplication, home: String = homeName) throws -> Answer {
        try app.XCTExecute(uri: "/triggers/\(home)", method: .GET) { r in
            Answer(status: r.status, body: r.body.map { String(buffer: $0) } ?? "", contentType: r.headers.first(name: "content-type"))
        }
    }

    private var outcomeLines: [String] { sink.lines.filter { $0.hasPrefix("[triggers]") && $0.contains(" PUT ") } }
    private var attemptLines: [String] { sink.lines.filter { $0.contains(" Attempting enable=") } }

    // MARK: T7A-08 — the PUT matrix, flag present

    func test_T7A08_disable_thenAgain_changedTrueThenFalse_oneHomeKitCall() throws {
        try createFlag()
        try withApp { app in
            let a = try put(app, on.uuidString, #"{"enabled": false}"#)
            XCTAssertEqual(a.status, .ok)
            XCTAssertEqual(a.body, "{\"changed\":true,\"enabled\":false,\"uuid\":\"\(on.uuidString)\"}")
            XCTAssertEqual(a.contentType, "application/json; charset=utf-8")
            XCTAssertEqual(store.setEnabledCalls.count, 1)
            XCTAssertEqual(store.setEnabledCalls.first?.enabled, false)
            let b = try put(app, on.uuidString, #"{"enabled": false}"#)
            XCTAssertEqual(b.status, .ok)
            XCTAssertEqual(b.body, "{\"changed\":false,\"enabled\":false,\"uuid\":\"\(on.uuidString)\"}")
            XCTAssertEqual(store.setEnabledCalls.count, 1, "already in that state → no HomeKit call")
        }
        XCTAssertEqual(outcomeLines.count, 2, "exactly one outcome line per request")
        XCTAssertEqual(attemptLines.count, 1, "one Attempting line, only when setEnabled is called")
        XCTAssertTrue(outcomeLines[0].hasSuffix("PUT \(on.uuidString) enabled=false → 200 ok"), outcomeLines[0])
        XCTAssertTrue(attemptLines[0].hasSuffix("\(on.uuidString) Attempting enable=false"), attemptLines[0])
        XCTAssertTrue(outcomeLines[0].hasPrefix("[triggers] "))
    }

    func test_T7A08_lowercaseUuidInThePath_findsTheTrigger() throws {
        try createFlag()
        try withApp { app in
            let a = try put(app, off.uuidString.lowercased(), #"{"enabled": true}"#)
            XCTAssertEqual(a.status, .ok)
            XCTAssertEqual(a.body, "{\"changed\":true,\"enabled\":true,\"uuid\":\"\(off.uuidString)\"}", "the response names the uuid in HomeKit's form")
        }
    }

    func test_T7A08_unknownTrigger_404_unknownHome_404() throws {
        try createFlag()
        try withApp { app in
            let t = try put(app, uuid(99).uuidString, #"{"enabled": false}"#)
            XCTAssertEqual(t.status, .notFound); XCTAssertEqual(t.body, #"{"error":"not_found","what":"trigger"}"#)
            let h = try put(app, on.uuidString, #"{"enabled": false}"#, home: "Elsewhere")
            XCTAssertEqual(h.status, .notFound); XCTAssertEqual(h.body, #"{"error":"not_found","what":"home"}"#)
        }
        XCTAssertTrue(store.setEnabledCalls.isEmpty)
        XCTAssertEqual(outcomeLines.count, 2)
        XCTAssertTrue(outcomeLines[0].hasSuffix("enabled=false → 404 not_found"), outcomeLines[0])
        XCTAssertTrue(outcomeLines[1].hasSuffix("enabled=? → 404 not_found"), outcomeLines[1])
        XCTAssertTrue(attemptLines.isEmpty)
    }

    func test_T7A08_homeKitError_502_withCodeAndMessage() throws {
        try createFlag()
        store.outcome = .error(code: 74, message: "Accessory is not reachable.")
        try withApp { app in
            let a = try put(app, on.uuidString, #"{"enabled": false}"#)
            XCTAssertEqual(a.status, .badGateway)
            XCTAssertEqual(a.body, #"{"code":74,"error":"homekit_error","message":"Accessory is not reachable."}"#)
        }
        XCTAssertTrue(outcomeLines[0].hasSuffix("→ 502 homekit_error"), outcomeLines[0])
        XCTAssertEqual(attemptLines.count, 1)
    }

    func test_T7A08_neverCompletes_504_writeTimeout_after4s() throws {
        try createFlag()
        store.outcome = .neverComplete
        try withApp { app in
            let t0 = Date()
            let a = try put(app, on.uuidString, #"{"enabled": false}"#)
            let dt = Date().timeIntervalSince(t0)
            XCTAssertEqual(a.status, .gatewayTimeout)
            XCTAssertEqual(a.body, #"{"error":"write_timeout"}"#)
            XCTAssertGreaterThanOrEqual(dt, 4.0); XCTAssertLessThanOrEqual(dt, 4.6, "the 4 s guard (PrefabTimeouts.writeSeconds)")
        }
        XCTAssertTrue(outcomeLines[0].hasSuffix("→ 504 write_timeout"), outcomeLines[0])
    }

    func test_T7A08_readBackMismatch_502_codeMinus2() throws {
        try createFlag()
        store.outcome = .succeedWithoutFlipping
        try withApp { app in
            let a = try put(app, on.uuidString, #"{"enabled": false}"#)
            XCTAssertEqual(a.status, .badGateway)
            XCTAssertEqual(a.body, #"{"code":-2,"error":"homekit_error","message":"isEnabled is true after enable(false)"}"#)
        }
    }

    func test_T7A08_badBodies_400_whatEnabled_noHomeKitCall() throws {
        try createFlag()
        try withApp { app in
            for body in [#"{"enabled":"no"}"#, #"{"enabled":1}"#, #"{"enabled":0}"#, #"{"enabled":null}"#, #"{}"#, #"{"enable":true}"#,
                         #"[true]"#, #"true"#, #"{"enabled": tru"#, ""] {
                let a = try put(app, on.uuidString, body)
                XCTAssertEqual(a.status, .badRequest, body)
                XCTAssertEqual(a.body, #"{"error":"bad_request","what":"enabled"}"#, body)
            }
            let none = try put(app, on.uuidString, nil)
            XCTAssertEqual(none.status, .badRequest, "no body at all")
        }
        XCTAssertTrue(store.setEnabledCalls.isEmpty)
        XCTAssertEqual(outcomeLines.count, 11, "one outcome line per request")
        XCTAssertTrue(outcomeLines.allSatisfy { $0.hasSuffix("enabled=? → 400 bad_request") }, outcomeLines.joined(separator: "\n"))
    }

    // MARK: T7A-09 — the flag (S10)

    func test_T7A09_flagAbsent_403_exactBodyAndHeader_zeroStoreCalls_evenForBadInput() throws {
        try withApp { app in
            for (u, body, home) in [(on.uuidString, #"{"enabled": false}"#, homeName), (on.uuidString, "garbage", homeName),
                                    (uuid(99).uuidString, #"{"enabled": true}"#, homeName), (on.uuidString, #"{"enabled": true}"#, "Elsewhere")] {
                let a = try put(app, u, body, home: home)
                XCTAssertEqual(a.status, .forbidden)
                XCTAssertEqual(a.body, #"{"error":"triggers_write_disabled"}"#)
                XCTAssertEqual(a.contentType, "application/json; charset=utf-8")
            }
        }
        XCTAssertTrue(store.calls.isEmpty, "the 403 comes before any store call: \(store.calls)")
        XCTAssertEqual(outcomeLines.count, 4)
        XCTAssertTrue(outcomeLines.allSatisfy { $0.hasSuffix("enabled=? → 403 triggers_write_disabled (absent)") }, outcomeLines.joined(separator: "\n"))
        XCTAssertTrue(attemptLines.isEmpty)
    }

    func test_T7A09_get_reportsWriteEnabled_falseThenTrue() throws {
        try withApp { app in
            let a = try get(app)
            XCTAssertEqual(a.status, .ok)
            XCTAssertEqual(parse(a.body)["write_enabled"] as? Bool, false)
            XCTAssertEqual(parse(a.body)["count"] as? Int, 2)
            XCTAssertEqual(a.contentType, "application/json; charset=utf-8")
            try createFlag()
            XCTAssertEqual(parse(try get(app).body)["write_enabled"] as? Bool, true)
            XCTAssertEqual(try get(app, home: "Elsewhere").status, .notFound)
        }
    }

    func test_T7A09_createdAndRemovedBetweenRequests_isFollowed_withoutARestart() throws {
        try withApp { app in
            XCTAssertEqual(try put(app, off.uuidString, #"{"enabled": true}"#).status, .forbidden)
            try createFlag()
            XCTAssertEqual(try put(app, off.uuidString, #"{"enabled": true}"#).status, .ok)
            try FileManager.default.removeItem(atPath: flagPath)
            XCTAssertEqual(try put(app, off.uuidString, #"{"enabled": false}"#).status, .forbidden)
        }
        XCTAssertEqual(store.setEnabledCalls.count, 1)
    }

    func test_T7A09_realFiles_symlink_directory_mode0644_rejected_withTheReason() throws {
        let target = dir.appendingPathComponent("real-flag").path
        try Data("x".utf8).write(to: URL(fileURLWithPath: target))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target)
        try FileManager.default.createSymbolicLink(atPath: flagPath, withDestinationPath: target)
        XCTAssertEqual(TriggerWriteFlag(path: flagPath).check(), .invalid(reason: "symlink"))
        try FileManager.default.removeItem(atPath: flagPath)
        try FileManager.default.createDirectory(atPath: flagPath, withIntermediateDirectories: false)
        XCTAssertEqual(TriggerWriteFlag(path: flagPath).check(), .invalid(reason: "not_regular_file"))
        try FileManager.default.removeItem(atPath: flagPath)
        try createFlag(mode: 0o644)
        XCTAssertEqual(TriggerWriteFlag(path: flagPath).check(), .invalid(reason: "mode"))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: flagPath)
        XCTAssertEqual(TriggerWriteFlag(path: flagPath).check(), .valid)
    }

    func test_T7A09_injectedAttributes_eachReasonInTheLogLine() throws {
        let cases: [(TriggerWriteFlag.Attributes?, String)] = [
            (nil, "absent"),
            (.init(kind: .symlink, uid: getuid(), mode: 0o600), "symlink"),
            (.init(kind: .directory, uid: getuid(), mode: 0o600), "not_regular_file"),
            (.init(kind: .other, uid: getuid(), mode: 0o600), "not_regular_file"),
            (.init(kind: .regular, uid: getuid() &+ 1, mode: 0o600), "owner"),
            (.init(kind: .regular, uid: getuid(), mode: 0o644), "mode"),
            (.init(kind: .regular, uid: getuid(), mode: 0o4600), "mode"),
        ]
        for (attrs, reason) in cases {
            sink = LineSink()
            let flag = TriggerWriteFlag(path: "/injected", read: { _ in attrs })
            XCTAssertEqual(flag.check(), .invalid(reason: reason))
            try withApp(flag: flag) { app in XCTAssertEqual(try put(app, on.uuidString, #"{"enabled": false}"#).status, .forbidden) }
            XCTAssertEqual(outcomeLines.last.map { $0.hasSuffix("→ 403 triggers_write_disabled (\(reason))") }, true, "\(reason): \(outcomeLines)")
        }
        let ok = TriggerWriteFlag(path: "/injected", read: { _ in .init(kind: .regular, uid: getuid(), mode: 0o600) })
        XCTAssertEqual(ok.check(), .valid)
        XCTAssertTrue(store.calls.isEmpty)
    }

    func test_T7A09_anLstatErrorOtherThanENOENT_isAbsent() throws {
        let file = dir.appendingPathComponent("plainfile").path
        try Data("x".utf8).write(to: URL(fileURLWithPath: file))
        let path = file + "/triggers-write-enabled"                       // ENOTDIR, not ENOENT
        errno = 0
        var st = stat()
        XCTAssertNotEqual(lstat(path, &st), 0)
        XCTAssertEqual(errno, ENOTDIR)
        XCTAssertEqual(TriggerWriteFlag(path: path).check(), .invalid(reason: "absent"))
    }

    func test_T7A09_flagPath_isNextToTheConfig() {
        XCTAssertEqual(TriggerWriteFlag.path(configPath: "/Users/x/Library/Application Support/Prefab/config.json"),
                       "/Users/x/Library/Application Support/Prefab/triggers-write-enabled")
        XCTAssertEqual(TriggerWriteFlag.path(configPath: "/tmp/scratch/c.json"), "/tmp/scratch/triggers-write-enabled")
    }

    // MARK: T7A-10 — the route table

    func test_T7A10_routeTable_isExactlyGetAndPutEnabled() {
        XCTAssertEqual(TriggerRoutes.paths.map { "\($0.method) \($0.path)" }, ["GET triggers/:home", "PUT triggers/:home/:uuid/enabled"])
    }

    func test_T7A10_noOtherMethodOrPathUnderTriggers() throws {
        try createFlag()
        try withApp { app in
            let u = on.uuidString
            for (uri, method) in [("/triggers/\(homeName)", HTTPMethod.POST), ("/triggers/\(homeName)/\(u)/enabled", .DELETE),
                                  ("/triggers/\(homeName)/\(u)/enabled", .PATCH), ("/triggers/\(homeName)/\(u)", .PUT),
                                  ("/triggers/\(homeName)/\(u)", .DELETE), ("/triggers/\(homeName)/\(u)/name", .PUT),
                                  ("/triggers", .GET), ("/triggers/\(homeName)/\(u)/enabled", .GET)] {
                try app.XCTExecute(uri: uri, method: method, body: ByteBuffer(string: #"{"enabled": false}"#)) { r in
                    XCTAssertEqual(r.status, .notFound, "\(method) \(uri)")
                }
            }
        }
        XCTAssertTrue(store.setEnabledCalls.isEmpty)
    }
}
