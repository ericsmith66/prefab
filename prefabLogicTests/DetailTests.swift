//
//  DetailTests.swift
//  prefabLogicTests — hostless (no TEST_HOST), native macOS; never touches HomeKit (PRD-1-01 plan § 15.18 R7-5).
//

import XCTest
import Hummingbird

/// S2-1: `PrefabJSONError` and `ErrorBox` moved into `prefab/core/` unchanged (R7-11). These pin their S′ behaviour.
final class MovedTypesTests: XCTestCase {
    private let allocator = ByteBufferAllocator()

    private func bodyString(_ e: PrefabJSONError) -> String? {
        e.body(allocator: allocator).map { String(buffer: $0) }
    }

    func test_S2_1_notFound_hasSortedKeysJSONBody_status404_andJSONContentType() {
        let e = PrefabJSONError.notFound("home")
        XCTAssertEqual(e.status, .notFound)
        XCTAssertEqual(bodyString(e), #"{"error":"not_found","what":"home"}"#)
        XCTAssertEqual(e.headers["content-type"], ["application/json; charset=utf-8"])
    }

    func test_S2_1_payloadWithMixedValues_isEncodedWithSortedKeys() {
        let e = PrefabJSONError(status: .badGateway, payload: ["message": "m", "hm_code": 74, "error": "read_failed"])
        XCTAssertEqual(e.status, .badGateway)
        XCTAssertEqual(bodyString(e), #"{"error":"read_failed","hm_code":74,"message":"m"}"#)
    }

    func test_S2_1_errorBox_holdsTheCompletionError() {
        let box = ErrorBox()
        XCTAssertNil(box.error)
        box.error = NSError(domain: "HMErrorDomain", code: 74)
        XCTAssertEqual((box.error as NSError?)?.code, 74)
    }
}
