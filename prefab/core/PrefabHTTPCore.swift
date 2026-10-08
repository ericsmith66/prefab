//
//  PrefabHTTPCore.swift
//  Prefab — HomeKit-free HTTP core (PRD-1-01 plan § 15.18 R7-5 / R7-11).
//
//  Compiled into the `Prefab` app target AND the hostless `prefabLogicTests` target (native macOS, no TEST_HOST),
//  never into the `prefab` CLI target (it links no Hummingbird). Nothing in prefab/core may import HomeKit.
//

import Foundation
import Hummingbird
import NIOPosix

// MARK: - F-1: the HTTP server factory (S2-2; plan § 15.18 R7-6, § 15.19 R8-5)

enum PrefabHTTP {
    /// Builds the server exactly as Server.startServer() did at S′: bound to 127.0.0.1 only (P12) on `port`, logger at
    /// debug, HBLogRequestsMiddleware(.debug) first. The caller adds HomeKitAuthLogger and the routes. The transport is
    /// the caller's choice (owner note R8-5): production passes `.shared(productionEventLoopGroup)`; tests pass an
    /// explicit group so they run the transport production runs.
    static func makeApplication(port: Int, eventLoopGroupProvider: HBApplication.EventLoopGroupProvider) -> HBApplication {
        let app = HBApplication(configuration: .init(address: .hostname("127.0.0.1", port: port)), eventLoopGroupProvider: eventLoopGroupProvider)
        app.logger.logLevel = .debug
        app.middleware.add(HBLogRequestsMiddleware(.debug))
        return app
    }

    /// The event-loop group production serves HTTP on — R8-5 branch 1 (H1 confirmed by PT-137, 2026-10-08): BSD
    /// sockets through NIOPosix. S′ used Hummingbird's `.singleton`, which under Mac Catalyst (compiled as `os(iOS)`)
    /// is NIOTSEventLoopGroup.singleton — Network.framework, where hummingbird-core's close right after the response
    /// write loses the response for `Connection: close` and HTTP/1.0 requests (F-1). hummingbird-core logs once that
    /// BSD sockets on iOS are "not recommended"; harmless on a Mac. Same bind, port, routes and middleware.
    static var productionEventLoopGroup: EventLoopGroup { MultiThreadedEventLoopGroup.singleton }
}

// MARK: - Moved unchanged from Routes.swift and Routes+Accessories.swift (S2-1)

/// Typed JSON error with the right status; Hummingbird renders any thrown HBHTTPResponseError as the response.
struct PrefabJSONError: Error, HBHTTPResponseError {
    let status: HTTPResponseStatus
    let payload: [String: Any]
    var headers: HTTPHeaders { ["content-type": "application/json; charset=utf-8"] }
    func body(allocator: ByteBufferAllocator) -> ByteBuffer? {
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data("{\"error\":\"internal\"}".utf8)
        return allocator.buffer(data: data)
    }
    static func notFound(_ what: String) -> PrefabJSONError { .init(status: .notFound, payload: ["error": "not_found", "what": what]) }
}

/// Completion-handler result holder (the completion fires once, before group.leave()).
final class ErrorBox { var error: Error? }

// MARK: - S2-5: full-detail reads are HomeKit's cache by default (plan § 15.18 R7-8)

extension PrefabJSONError {
    /// 400 `{"error":"bad_request","what":<what>}`.
    static func badRequest(_ what: String) -> PrefabJSONError { .init(status: .badRequest, payload: ["error": "bad_request", "what": what]) }
}

/// How a full-detail route reads (`GET /accessories/:home/id/:uuid`, `GET /accessories/:home/:room/:accessory`).
enum ReadMode: Equatable {
    /// No `readValue` at all: ids, types, names, metadata and HomeKit's cached values ("the structure-only id route").
    case cache
    /// One `readValue` per characteristic, as S′ always did, bounded by the 12 s guard.
    case live
    /// `?characteristic=` alone: exactly one `readValue` of that characteristic (the id route's readOne; unchanged).
    case single(String)

    /// `read` absent or `cache` → cache; `live` → live; any other `read` value, or `read` together with
    /// `characteristic` → 400 `{"error":"bad_request","what":"read"}`. `characteristic` alone → single.
    static func parse(read: String?, characteristic: String?) throws -> ReadMode {
        if let read {
            guard characteristic == nil, read == "cache" || read == "live" else { throw PrefabJSONError.badRequest("read") }
            return read == "live" ? .live : .cache
        }
        if let characteristic { return .single(characteristic) }
        return .cache
    }
}

enum DetailValues {
    static let cache = "cache"
    static let live = "live"
    /// Every full-detail response says where its values came from: `values:"cache"`, or `values:"live"` with
    /// `readErrors` (R7-8 item 3). nil → cache.
    static func label(_ a: inout Accessory, liveReadErrors: Int?) {
        if let liveReadErrors { a.values = live; a.readErrors = liveReadErrors } else { a.values = cache; a.readErrors = nil }
    }
}

/// The debug-log lines of the read guards (R6-8 item 6 / R7-8 item 5). Cache mode logs nothing.
enum DetailLog {
    static func readAllTimeout(_ accessoryId: String) -> String { "[readAll] \(accessoryId) → 504 read_timeout" }
    static func readOneTimeout(_ characteristicId: String) -> String { "[readOne] \(characteristicId) → 504 read_timeout" }
    /// One line per live full read, so live reads can be counted.
    static func readAllCount(_ accessoryId: String, _ reads: Int) -> String { "[readAll] \(accessoryId) readValue x\(reads)" }
}

/// Counts the failed reads of one live full read; the completions arrive on HomeKit's threads.
final class ReadTally {
    private let lock = NSLock()
    private var count = 0
    func record(_ error: Error?) {
        guard error != nil else { return }
        lock.lock(); count += 1; lock.unlock()
    }
    var errors: Int { lock.lock(); defer { lock.unlock() }; return count }
}

// MARK: - S2-6: the HomeKit-auth 403 body (plan § 15.18 R7-9 item 1, as amended by § 15.19 R8-7 / PC-5)

enum AuthFailure {
    static let message = "Prefab is not authorized to access your HomeKit data."
    /// Debug builds name the switch when PREFAB_FORCE_UNAUTHORIZED is the cause; Release compiles the cause branch out,
    /// so the signed Release carries no switch string (PT-157 counts 0). Every other 403 keeps S′'s exact bytes.
    static func body(forced: Bool) -> String {
        #if DEBUG
        if forced { return "{\"error\": \"\(message)\", \"cause\": \"PREFAB_FORCE_UNAUTHORIZED\"}" }
        #endif
        return "{\"error\": \"\(message)\"}"     // S′'s exact bytes
    }
}
