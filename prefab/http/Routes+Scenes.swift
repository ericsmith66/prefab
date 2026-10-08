//
//  Routes+Scenes.swift
//  Prefab
//
//  Created by Copilot on 2025.
//

import Foundation
import HomeKit
import Hummingbird
import OSLog

extension Server {
    
    /// GET /scenes/:home - List all scenes in a home
    func getScenes(_ request: HBRequest) throws -> String {
        let homeName = try getRequiredParam(param: "home", request: request)
        
        guard let home = homeBase.homes.first(where: { $0.name == homeName.removingPercentEncoding }) else {
            throw HBHTTPError(.notFound)
        }
        
        let scenes = home.actionSets.map { actionSet in
            HomeKitScene(
                home: home.name,
                uniqueIdentifier: actionSet.uniqueIdentifier,
                name: actionSet.name,
                isBuiltIn: actionSet.actionSetType != HMActionSetTypeUserDefined
            )
        }
        
        let jsonEncoder = JSONEncoder()
        let jsonData = try jsonEncoder.encode(scenes)
        let json = String(data: jsonData, encoding: .utf8)
        
        return json!
    }
    
    /// PRD-1-07 Track A: an action set by uuid — home.actionSets first, then every trigger's actionSets (a trigger-owned set).
    func locateActionSet(_ id: UUID?, in home: HMHome) -> (set: HMActionSet?, location: ActionSetLocation) {
        guard let id else { return (nil, .notFound) }
        let homeSets = home.actionSets
        let triggerSets = home.triggers.flatMap { $0.actionSets }
        let location = ActionSetExecution.locate(id, homeSets: homeSets.map(\.uniqueIdentifier), triggerSets: triggerSets.map(\.uniqueIdentifier))
        switch location {
        case .home: return (homeSets.first { $0.uniqueIdentifier == id }, location)
        case .triggerOnly: return (triggerSets.first { $0.uniqueIdentifier == id }, location)
        case .notFound: return (nil, location)
        }
    }

    /// GET /scenes/:home/:scene - Get detailed scene info (read-only: a trigger-owned set is readable without the flag)
    func getScene(_ request: HBRequest) throws -> String {
        let homeName = try getRequiredParam(param: "home", request: request)
        let sceneId = try getRequiredParam(param: "scene", request: request)
        
        guard let home = homeBase.homes.first(where: { $0.name == homeName.removingPercentEncoding }) else { throw PrefabJSONError.notFound("home") }
        let found = locateActionSet(UUID(uuidString: sceneId), in: home)
        guard ActionSetExecution.readable(found.location), let actionSet = found.set else { throw PrefabJSONError.notFound("scene") }
        let actions = actionSnapshots(of: actionSet)
        let sceneDetail = SceneDetail(home: home.name, uniqueIdentifier: actionSet.uniqueIdentifier, name: actionSet.name,
                                      isBuiltIn: actionSet.actionSetType != HMActionSetTypeUserDefined, actions: actions,
                                      totalActions: actionSet.actions.count, decodedActions: actions.count)
        
        let jsonEncoder = JSONEncoder()
        let jsonData = try jsonEncoder.encode(sceneDetail)
        let json = String(data: jsonData, encoding: .utf8)
        
        return json!
    }
    
    /// POST /scenes/:home/:scene/execute - Execute a scene. PRD-1-07 Track A: a set found only through a trigger (a
    /// trigger-owned set) executes only while the trigger write flag is valid, else 403 triggers_write_disabled with no
    /// HomeKit call. Every execute writes one line `[executeScene] <requestId> <uuid> → <status> <ok|error>`.
    func executeScene(_ request: HBRequest) throws -> String {
        let logger = Logger(subsystem: "app.prefab", category: "executeScene")
        let homeName = try getRequiredParam(param: "home", request: request)
        let sceneId = try getRequiredParam(param: "scene", request: request)
        let requestId = request.id
        func line(_ status: Int, _ outcome: String) {
            HomeBase.shared.logToFile(ActionSetExecution.logLine(requestId: requestId, uuid: sceneId, status: status, outcome: outcome))
        }
        
        guard let home = homeBase.homes.first(where: { $0.name == homeName.removingPercentEncoding }) else {
            logger.error("Home not found: \(homeName, privacy: .public)")
            line(404, "not_found")
            throw PrefabJSONError.notFound("home")
        }
        
        let found = locateActionSet(UUID(uuidString: sceneId), in: home)
        let flagEnabled = found.location == .triggerOnly
            && TriggerWriteFlag(path: TriggerWriteFlag.path(configPath: PrefabEnvironment.configPath)).check() == .valid
        switch ActionSetExecution.executeDecision(location: found.location, flagEnabled: flagEnabled) {
        case .notFound:
            logger.error("Scene not found: \(sceneId, privacy: .public)")
            line(404, "not_found")
            throw PrefabJSONError.notFound("scene")
        case .refuse:
            line(403, "triggers_write_disabled")
            throw ActionSetExecution.refusal
        case .execute:
            break
        }
        guard let actionSet = found.set else { line(404, "not_found"); throw PrefabJSONError.notFound("scene") }
        
        logger.debug("Executing scene: \(actionSet.name, privacy: .public)")
        
        var executeError: Error?
        let group = DispatchGroup()
        group.enter()
        home.executeActionSet(actionSet) { error in
            if let error = error {
                logger.error("Scene execution failed: \(error.localizedDescription, privacy: .public)")
                executeError = error
            } else {
                logger.debug("Scene executed successfully")
            }
            group.leave()
        }
        if group.wait(timeout: .now() + PrefabTimeouts.sceneSeconds) == .timedOut {
            line(504, "scene_timeout")
            throw PrefabJSONError(status: .gatewayTimeout, payload: ["error": "scene_timeout"])
        }
        
        if let error = executeError {
            line(500, "scene_failed")
            throw PrefabJSONError(status: .internalServerError, payload: ["error": "scene_failed", "message": error.localizedDescription])
        }
        
        line(200, "ok")
        let response = ["success": true, "scene": actionSet.name] as [String: Any]
        let jsonData = try JSONSerialization.data(withJSONObject: response)
        return String(data: jsonData, encoding: .utf8)!
    }
}
