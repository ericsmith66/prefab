//
//  ActionSetLocatorTests.swift
//  prefabLogicTests — PRD-1-07 Track A, executing an action set (plan § 4 Routes+Scenes row, amendments A-3, A-6): T7A-12.
//  A set found in home.actionSets runs as before; a set found ONLY through a trigger (a trigger-owned set) runs only
//  while the write flag is valid, else 403 triggers_write_disabled with no HomeKit call. Reading it (getScene) is free.
//

import XCTest
import Hummingbird

final class ActionSetLocatorTests: XCTestCase {
    private let homeSet = uuid(10), triggerSet = uuid(20), shared = uuid(30)

    // T7A-12 — locate: home first, then the triggers' sets
    func test_T7A12_locate_homeFirst_thenTriggers_elseNotFound() {
        let homeSets = [homeSet, shared], triggerSets = [triggerSet, shared]
        XCTAssertEqual(ActionSetExecution.locate(homeSet, homeSets: homeSets, triggerSets: triggerSets), .home)
        XCTAssertEqual(ActionSetExecution.locate(shared, homeSets: homeSets, triggerSets: triggerSets), .home,
                       "a set HomeKit also lists among the home's scenes was executable before S″ and stays so (Q-2A, A-6)")
        XCTAssertEqual(ActionSetExecution.locate(triggerSet, homeSets: homeSets, triggerSets: triggerSets), .triggerOnly)
        XCTAssertEqual(ActionSetExecution.locate(uuid(99), homeSets: homeSets, triggerSets: triggerSets), .notFound)
    }

    // T7A-12 — the execute decision
    func test_T7A12_executeDecision() {
        XCTAssertEqual(ActionSetExecution.executeDecision(location: .home, flagEnabled: false), .execute, "a home set: the flag is irrelevant")
        XCTAssertEqual(ActionSetExecution.executeDecision(location: .home, flagEnabled: true), .execute)
        XCTAssertEqual(ActionSetExecution.executeDecision(location: .triggerOnly, flagEnabled: false), .refuse)
        XCTAssertEqual(ActionSetExecution.executeDecision(location: .triggerOnly, flagEnabled: true), .execute)
        XCTAssertEqual(ActionSetExecution.executeDecision(location: .notFound, flagEnabled: true), .notFound)
        XCTAssertEqual(ActionSetExecution.executeDecision(location: .notFound, flagEnabled: false), .notFound)
    }

    func test_T7A12_refusalAndNotFound_bodies() {
        let alloc = ByteBufferAllocator()
        let r = ActionSetExecution.refusal
        XCTAssertEqual(r.status, .forbidden)
        XCTAssertEqual(r.body(allocator: alloc).map { String(buffer: $0) }, #"{"error":"triggers_write_disabled"}"#, "the same 403 as the trigger PUT")
        XCTAssertEqual(r.headers["content-type"], ["application/json; charset=utf-8"])
        let n = PrefabJSONError.notFound("scene")
        XCTAssertEqual(n.body(allocator: alloc).map { String(buffer: $0) }, #"{"error":"not_found","what":"scene"}"#)
    }

    // A-3 — getScene is read-only: a trigger-only set reads without the flag
    func test_T7A12_getScene_readsATriggerOnlySet_withoutTheFlag() {
        XCTAssertTrue(ActionSetExecution.readable(.home))
        XCTAssertTrue(ActionSetExecution.readable(.triggerOnly))
        XCTAssertFalse(ActionSetExecution.readable(.notFound))
    }

    // T7A-12 — every execute writes one line
    func test_T7A12_executeLogLine_format() {
        XCTAssertEqual(ActionSetExecution.logLine(requestId: "R1", uuid: triggerSet.uuidString, status: 200, outcome: "ok"),
                       "[executeScene] R1 \(triggerSet.uuidString) → 200 ok")
        XCTAssertEqual(ActionSetExecution.logLine(requestId: "R2", uuid: triggerSet.uuidString, status: 403, outcome: "triggers_write_disabled"),
                       "[executeScene] R2 \(triggerSet.uuidString) → 403 triggers_write_disabled")
        XCTAssertEqual(ActionSetExecution.logLine(requestId: "R3", uuid: "not-a-uuid", status: 404, outcome: "not_found"),
                       "[executeScene] R3 not-a-uuid → 404 not_found")
    }
}
