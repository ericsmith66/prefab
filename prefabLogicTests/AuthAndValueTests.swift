//
//  AuthAndValueTests.swift
//  prefabLogicTests — the 403 body (PT-154; plan R7-9 item 1 as amended by R8-7 / PC-5) and strict bool (PT-155;
//  R7-9 item 6, Eric-pending default "include").
//

import XCTest

final class AuthAndValueTests: XCTestCase {
    /// S′'s exact 403 bytes (prefab b2ca6d3, Server.swift HomeKitAuthLogger).
    private let sPrime403 = "{\"error\": \"Prefab is not authorized to access your HomeKit data.\"}"

    // PT-154 — the logic tests are a Debug build, so both branches are visible here; Release compiles `cause` out
    func test_PT154_notForced_isSPrimesExactBytes() {
        XCTAssertEqual(AuthFailure.body(forced: false), sPrime403)
    }

    func test_PT154_forced_namesTheSwitch_inDebugOnly() {
        #if DEBUG
        XCTAssertEqual(AuthFailure.body(forced: true),
                       "{\"error\": \"Prefab is not authorized to access your HomeKit data.\", \"cause\": \"PREFAB_FORCE_UNAUTHORIZED\"}")
        #else
        XCTAssertEqual(AuthFailure.body(forced: true), sPrime403, "Release never names the switch")
        #endif
    }

    func test_PT154_bothBodiesAreValidJSON() throws {
        for forced in [false, true] {
            let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(AuthFailure.body(forced: forced).utf8)) as? [String: String])
            XCTAssertEqual(obj["error"], AuthFailure.message)
        }
    }

    // PT-155 — GetValue(_, "bool") is strict; the other formats are unchanged
    private func bool(_ v: String) throws -> Bool? { try GetValue(value: v, format: "bool") as? Bool }

    func test_PT155_strictBool_acceptsOnly_1_0_true_false_on_off_inAnyCase() throws {
        for v in ["1", "true", "TRUE", "True", "on", "On", "ON"] { XCTAssertEqual(try bool(v), true, v) }
        for v in ["0", "false", "FALSE", "off", "Off"] { XCTAssertEqual(try bool(v), false, v) }
        for v in ["abc", "yes", "no", "2", "", " 1", "1 ", "-1", "truee"] {
            XCTAssertThrowsError(try GetValue(value: v, format: "bool"), "\(v.debugDescription) must be refused")
        }
    }

    func test_PT155_otherFormats_unchanged() throws {
        XCTAssertEqual((try GetValue(value: "255", format: "uint8") as? NSNumber)?.intValue, 255)
        XCTAssertThrowsError(try GetValue(value: "256", format: "uint8"))
        XCTAssertEqual((try GetValue(value: "65535", format: "uint16") as? NSNumber)?.intValue, 65535)
        XCTAssertEqual((try GetValue(value: "7", format: "uint32") as? NSNumber)?.intValue, 7)
        XCTAssertEqual((try GetValue(value: "7", format: "uint64") as? NSNumber)?.intValue, 7)
        XCTAssertEqual((try GetValue(value: "-3", format: "int") as? NSNumber)?.intValue, -3)
        XCTAssertThrowsError(try GetValue(value: "abc", format: "int"))
        XCTAssertEqual((try GetValue(value: "1.5", format: "float") as? NSNumber)?.floatValue, 1.5)
        XCTAssertEqual(try GetValue(value: "anything", format: "string") as? String, "anything")
        XCTAssertThrowsError(try GetValue(value: "1", format: "tlv8"), "an unknown format still throws")
    }
}
