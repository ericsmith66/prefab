//
//  HTTPTransportTests.swift
//  prefabLogicTests — F-1 (PRD-1-01 plan § 15.18 R7-6, § 15.19 R8-5): PT-136, PT-137, PT-138.
//
//  The server under test is PrefabHTTP.makeApplication — the same factory Server.startServer() uses — on
//  127.0.0.1:0 with two stub routes. Every test passes an EXPLICIT event-loop group (owner note R8-5): Hummingbird's
//  `.singleton` means BSD sockets on native macOS but Network.framework under Mac Catalyst, so only an explicit group
//  makes this hostless test run the transport production runs.
//
//  The six raw request shapes (R7-6 step 1):
//    (a) HTTP/1.1 keep-alive · (b) `Connection: close` (×10) · (c) HTTP/1.0 (×10) · (d) HTTP/1.0 + `Connection: keep-alive`
//    (e) two pipelined requests in one write · (f) 50 sequential `Connection: close` requests
//

import XCTest
import Hummingbird
import NIOPosix
import NIOTransportServices

enum F1Case: String { case a, b, c, d, e, f }

final class HTTPTransportTests: XCTestCase {
    static let versionBody = #"{"stub":"version"}"#
    static let pingBody = #"{"stub":"ping"}"#

    // MARK: harness

    private func startStub(_ group: EventLoopGroup) throws -> (HBApplication, Int) {
        let app = PrefabHTTP.makeApplication(port: 0, eventLoopGroupProvider: .shared(group))
        app.router.get("version") { _ in HTTPTransportTests.versionBody }
        app.router.get("ping") { _ in HTTPTransportTests.pingBody }
        try app.start()
        let port = try XCTUnwrap(app.server.channel?.localAddress?.port, "the listener has no bound port")
        return (app, port)
    }

    private func stop(_ app: HBApplication) { app.stop(); app.wait() }

    /// The transport production serves HTTP on (PrefabHTTP.productionEventLoopGroup).
    private func onProduction(_ body: (Int) throws -> Void) throws {
        let (app, port) = try startStub(PrefabHTTP.productionEventLoopGroup)
        defer { stop(app) }
        try body(port)
    }

    /// Network.framework through NIOTransportServices — what Hummingbird's `.singleton` gives a Mac Catalyst app (S′).
    private func onNIOTS(_ body: (Int) throws -> Void) throws {
        let group = NIOTSEventLoopGroup(loopCount: 1, defaultQoS: .default)
        defer { try? group.syncShutdownGracefully() }
        let (app, port) = try startStub(group)
        defer { stop(app) }
        try body(port)
    }

    /// (b) and (c) are each sent this many times on new connections (DV-S2-2).
    private static let attempts = 10
    private static let keepAliveRequest = "GET /version HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
    private static let closeRequest = "GET /version HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"

    /// Asserts one case. Every assertion names its case, so an expected failure is attributable.
    private func check(_ c: F1Case, port: Int, file: StaticString = #filePath, line: UInt = #line) {
        let one: ([UInt8]) -> Bool = { RawHTTPClient.parseResponses($0).count >= 1 }
        switch c {
        case .a:
            let x = RawHTTPClient.exchange(port: port, request: Self.keepAliveRequest, stopWhen: one)
            let r = RawHTTPClient.parseResponses(x.bytes)
            XCTAssertEqual(r.count, 1, "(a) one complete response", file: file, line: line)
            XCTAssertEqual(r.first?.status, 200, "(a) status", file: file, line: line)
            XCTAssertEqual(r.first?.bodyString, Self.versionBody, "(a) body", file: file, line: line)
            XCTAssertEqual(r.first?.headers["connection"], "keep-alive", "(a) connection header", file: file, line: line)
            XCTAssertFalse(x.closedByServer, "(a) the connection stays open", file: file, line: line)
        case .b:
            // Ten attempts, each a new connection (DV-S2-2): on Network.framework the loss is a race (measured 1/200 and
            // 46/200 complete), so one attempt could pass by luck; ten make PT-137's strict expected failure deterministic.
            for attempt in 1...Self.attempts {
                let x = RawHTTPClient.exchange(port: port, request: Self.closeRequest)
                let r = RawHTTPClient.parseResponses(x.bytes)
                XCTAssertEqual(r.count, 1, "(b) #\(attempt) Connection: close → one complete response (got \(x.bytes.count) bytes)", file: file, line: line)
                XCTAssertEqual(r.first?.status, 200, "(b) #\(attempt) status", file: file, line: line)
                XCTAssertEqual(r.first?.bodyString, Self.versionBody, "(b) #\(attempt) body", file: file, line: line)
                XCTAssertEqual(r.first?.headers["connection"], "close", "(b) #\(attempt) connection: close header", file: file, line: line)
                XCTAssertTrue(x.closedByServer, "(b) #\(attempt) then the server closes", file: file, line: line)
            }
        case .c:
            for attempt in 1...Self.attempts {
                let x = RawHTTPClient.exchange(port: port, request: "GET /version HTTP/1.0\r\n\r\n")
                let r = RawHTTPClient.parseResponses(x.bytes)
                XCTAssertEqual(r.count, 1, "(c) #\(attempt) HTTP/1.0 → one complete response (got \(x.bytes.count) bytes)", file: file, line: line)
                XCTAssertEqual(r.first?.status, 200, "(c) #\(attempt) status", file: file, line: line)
                XCTAssertEqual(r.first?.version, "HTTP/1.0", "(c) #\(attempt) answered as HTTP/1.0", file: file, line: line)
                XCTAssertEqual(r.first?.bodyString, Self.versionBody, "(c) #\(attempt) body", file: file, line: line)
                XCTAssertTrue(x.closedByServer, "(c) #\(attempt) then the server closes", file: file, line: line)
            }
        case .d:
            let x = RawHTTPClient.exchange(port: port, request: "GET /version HTTP/1.0\r\nConnection: keep-alive\r\n\r\n", stopWhen: one)
            let r = RawHTTPClient.parseResponses(x.bytes)
            XCTAssertEqual(r.count, 1, "(d) HTTP/1.0 + keep-alive → one complete response", file: file, line: line)
            XCTAssertEqual(r.first?.status, 200, "(d) status", file: file, line: line)
            XCTAssertEqual(r.first?.headers["connection"], "keep-alive", "(d) connection header", file: file, line: line)
            XCTAssertFalse(x.closedByServer, "(d) the connection stays open", file: file, line: line)
        case .e:
            let x = RawHTTPClient.exchange(port: port, request: "GET /version HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\nGET /ping HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
                                           stopWhen: { RawHTTPClient.parseResponses($0).count >= 2 })
            let r = RawHTTPClient.parseResponses(x.bytes)
            XCTAssertEqual(r.map(\.status), [200, 200], "(e) two complete responses", file: file, line: line)
            XCTAssertEqual(r.map(\.bodyString), [Self.versionBody, Self.pingBody], "(e) in request order", file: file, line: line)
        case .f:
            var complete = 0
            for _ in 1...50 {
                let x = RawHTTPClient.exchange(port: port, request: Self.closeRequest)
                let r = RawHTTPClient.parseResponses(x.bytes)
                if r.count == 1, r[0].status == 200, r[0].bodyString == Self.versionBody, x.closedByServer { complete += 1 }
            }
            XCTAssertEqual(complete, 50, "(f) 50 sequential Connection: close requests → 50 complete 200s", file: file, line: line)
        }
    }

    // MARK: PT-136 — the production factory answers all six (F-1 fixed; R8-5 branch 1)

    func test_PT136_a_keepAlive() throws { try onProduction { check(.a, port: $0) } }
    func test_PT136_b_connectionClose() throws { try onProduction { check(.b, port: $0) } }
    func test_PT136_c_http10() throws { try onProduction { check(.c, port: $0) } }
    func test_PT136_d_http10KeepAlive() throws { try onProduction { check(.d, port: $0) } }
    func test_PT136_e_pipelined() throws { try onProduction { check(.e, port: $0) } }
    func test_PT136_f_fiftySequentialClose() throws { try onProduction { check(.f, port: $0) } }

    func test_PT136_factory_matchesStartServer_bindAndLogLevel() {
        let app = PrefabHTTP.makeApplication(port: 8080, eventLoopGroupProvider: .shared(PrefabHTTP.productionEventLoopGroup))
        XCTAssertEqual(app.logger.logLevel, .debug)
        guard case .hostname(let host, let port) = app.configuration.address else { return XCTFail("not a hostname bind") }
        XCTAssertEqual(host, "127.0.0.1")
        XCTAssertEqual(port, 8080)
    }

    // MARK: PT-137 — Network.framework (NIOTS): H1's evidence. An unexpected pass of (b)/(c)/(f) fails the test = the R8-5 stop.

    func test_PT137_NIOTS_a_keepAlive_passes() throws { try onNIOTS { check(.a, port: $0) } }
    func test_PT137_NIOTS_d_http10KeepAlive_passes() throws { try onNIOTS { check(.d, port: $0) } }
    func test_PT137_NIOTS_e_pipelined_passes() throws { try onNIOTS { check(.e, port: $0) } }

    func test_PT137_NIOTS_b_connectionClose_failsAsInProduction() throws {
        try onNIOTS { port in
            XCTExpectFailure("F-1 / H1: on Network.framework the close after the write loses the response (S′: curl exit 52)") { check(.b, port: port) }
        }
    }
    func test_PT137_NIOTS_c_http10_failsAsInProduction() throws {
        try onNIOTS { port in
            XCTExpectFailure("F-1 / H1: HTTP/1.0 is not keep-alive, so the same close-after-write loses the response") { check(.c, port: port) }
        }
    }
    func test_PT137_NIOTS_f_fiftySequentialClose_failsAsInProduction() throws {
        try onNIOTS { port in
            XCTExpectFailure("F-1 / H1: sequential Connection: close requests lose their responses") { check(.f, port: port) }
        }
    }

    // MARK: PT-138 — the production listener is 127.0.0.1 only (P12)

    func test_PT138_productionListener_isLoopbackOnly() throws {
        let (app, port) = try startStub(PrefabHTTP.productionEventLoopGroup)
        defer { stop(app) }
        XCTAssertEqual(app.server.channel?.localAddress?.ipAddress, "127.0.0.1")
        XCTAssertEqual(RawHTTPClient.connectErrno(host: "127.0.0.1", port: port), 0, "loopback connects")
        let lan = try XCTUnwrap(RawHTTPClient.nonLoopbackIPv4(), "this Mac needs one non-loopback IPv4 address for PT-138")
        XCTAssertEqual(RawHTTPClient.connectErrno(host: lan, port: port), ECONNREFUSED, "\(lan):\(port) must be refused")
    }
}
