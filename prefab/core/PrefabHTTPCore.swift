//
//  PrefabHTTPCore.swift
//  Prefab — HomeKit-free HTTP core (PRD-1-01 plan § 15.18 R7-5 / R7-11).
//
//  Compiled into the `Prefab` app target AND the hostless `prefabLogicTests` target (native macOS, no TEST_HOST),
//  never into the `prefab` CLI target (it links no Hummingbird). Nothing in prefab/core may import HomeKit.
//

import Foundation
import Hummingbird

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
