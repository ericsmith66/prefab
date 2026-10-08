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
