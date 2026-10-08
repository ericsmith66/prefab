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

/// S2-5 — full-detail read modes, the encoder's key sets (C2-5) and the 504 log lines (plan § 15.18 R7-8).
final class DetailTests: XCTestCase {
    private let allocator = ByteBufferAllocator()

    private func assertBadRead(_ read: String?, _ characteristic: String?, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try ReadMode.parse(read: read, characteristic: characteristic), file: file, line: line) { e in
            guard let j = e as? PrefabJSONError else { return XCTFail("not a PrefabJSONError: \(e)", file: file, line: line) }
            XCTAssertEqual(j.status, .badRequest, file: file, line: line)
            XCTAssertEqual(j.body(allocator: allocator).map { String(buffer: $0) }, #"{"error":"bad_request","what":"read"}"#, file: file, line: line)
        }
    }

    // PT-151 — the read mode of both full-detail routes
    func test_PT151_readMode_parse() throws {
        XCTAssertEqual(try ReadMode.parse(read: nil, characteristic: nil), .cache, "no query → cache")
        XCTAssertEqual(try ReadMode.parse(read: "cache", characteristic: nil), .cache)
        XCTAssertEqual(try ReadMode.parse(read: "live", characteristic: nil), .live)
        XCTAssertEqual(try ReadMode.parse(read: nil, characteristic: "C-1"), .single("C-1"), "characteristic alone → one readValue")
        assertBadRead("bogus", nil)
        assertBadRead("", nil)
        assertBadRead("LIVE", nil)
        assertBadRead("live", "C-1")
        assertBadRead("cache", "C-1")
    }

    // PT-152 — C2-5: the explicit encoder carries the new fields on details only (PT-125's key-set comparison re-run)
    private func keys(_ a: Accessory) throws -> Set<String> {
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(a)) as? [String: Any])
        return Set(obj.keys)
    }
    /// An item as summaryJSON builds it for the list, room and summary-filtered routes (every list field set).
    private func listItem(bridgedBy: String? = nil) -> Accessory {
        Accessory(home: "Waverly", room: "Kitchenette", name: "Rear Attic Lights", uniqueIdentifier: "U-1", isDefaultRoom: false,
                  bridgedBy: bridgedBy, category: "Lightbulb", isReachable: true, isBridged: bridgedBy != nil,
                  firmwareVersion: "1.0", manufacturer: "Lutron", model: "RRD")
    }
    private func detailItem() -> Accessory {
        var a = listItem(bridgedBy: "B-1")
        a.supportsIdentify = true
        a.services = [Service(uniqueIdentifier: UUID(), name: "Light", typeName: "Lightbulb", type: "00000043-0000-1000-8000-0026BB765291",
                              isPrimary: true, isUserInteractive: true, associatedType: nil, characteristics: [])]
        return a
    }
    /// S′'s key sets (prefab b2ca6d3, Data.swift RM-1 encoder): list items omit supportsIdentify and services.
    private let sPrimeList: Set<String> = ["home", "room", "name", "uniqueIdentifier", "isDefaultRoom", "bridgedBy", "category",
                                          "isReachable", "isBridged", "firmwareVersion", "manufacturer", "model"]
    private var sPrimeDetail: Set<String> { sPrimeList.union(["supportsIdentify", "services"]) }

    func test_PT152_listRoomAndSummaryItems_keepSPrimesKeySet_andBridgedByIsAnExplicitNull() throws {
        XCTAssertEqual(try keys(listItem()), sPrimeList)
        XCTAssertEqual(try keys(listItem(bridgedBy: "B-1")), sPrimeList)
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(listItem()), encoding: .utf8))
        XCTAssertTrue(json.contains(#""bridgedBy":null"#), json)
    }

    func test_PT152_cacheDetail_addsValuesCache_only() throws {
        var a = detailItem()
        DetailValues.label(&a, liveReadErrors: nil)
        XCTAssertEqual(try keys(a), sPrimeDetail.union(["values"]))
        XCTAssertEqual(a.values, "cache")
        XCTAssertNil(a.readErrors)
    }

    func test_PT152_liveDetail_addsValuesLive_andReadErrors() throws {
        var a = detailItem()
        DetailValues.label(&a, liveReadErrors: 2)
        XCTAssertEqual(try keys(a), sPrimeDetail.union(["values", "readErrors"]))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(a)) as? [String: Any])
        XCTAssertEqual(obj["values"] as? String, "live")
        XCTAssertEqual(obj["readErrors"] as? Int, 2)
    }

    func test_PT152_unlabelledDetail_isSPrimesDetailKeySet() throws {
        XCTAssertEqual(try keys(detailItem()), sPrimeDetail)
    }

    func test_PT152_decodingAnSPrimeDetail_leavesTheNewFieldsNil() throws {
        let data = try JSONEncoder().encode(detailItem())
        let back = try JSONDecoder().decode(Accessory.self, from: data)
        XCTAssertNil(back.values); XCTAssertNil(back.readErrors)
    }

    // PT-153 — the 504 and readValue lines (the guard-expiry branches calling them are reviewed in Routes+Accessories.swift)
    func test_PT153_logLines() {
        XCTAssertEqual(DetailLog.readAllTimeout("A-UUID"), "[readAll] A-UUID → 504 read_timeout")
        XCTAssertEqual(DetailLog.readOneTimeout("C-UUID"), "[readOne] C-UUID → 504 read_timeout")
        XCTAssertEqual(DetailLog.readAllCount("A-UUID", 8), "[readAll] A-UUID readValue x8")
    }

    // E-87 support — per-read errors of a live full read are counted exactly, from HomeKit's completion threads
    func test_E87_readTally_countsErrorsFromManyThreads() {
        let tally = ReadTally()
        DispatchQueue.concurrentPerform(iterations: 1000) { i in tally.record(i % 4 == 0 ? NSError(domain: "HMErrorDomain", code: 74) : nil) }
        XCTAssertEqual(tally.errors, 250)
    }
}
