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
    
    /// GET /scenes/:home/:scene - Get detailed scene info
    func getScene(_ request: HBRequest) throws -> String {
        let homeName = try getRequiredParam(param: "home", request: request)
        let sceneId = try getRequiredParam(param: "scene", request: request)
        
        guard let home = homeBase.homes.first(where: { $0.name == homeName.removingPercentEncoding }) else { throw PrefabJSONError.notFound("home") }
        guard let sceneUUID = UUID(uuidString: sceneId), let actionSet = home.actionSets.first(where: { $0.uniqueIdentifier == sceneUUID }) else {
            throw PrefabJSONError.notFound("scene")
        }
        let writeActions = actionSet.actions.compactMap { $0 as? HMCharacteristicWriteAction<NSCopying> }
        let actions = writeActions.map { a in
            SceneAction(accessoryName: a.characteristic.service?.accessory?.name ?? "", serviceName: a.characteristic.service?.name ?? "",
                        characteristicType: a.characteristic.characteristicType, targetValue: "\(a.targetValue)",
                        accessoryUniqueIdentifier: a.characteristic.service?.accessory?.uniqueIdentifier.uuidString,
                        serviceUniqueIdentifier: a.characteristic.service?.uniqueIdentifier.uuidString,
                        serviceType: a.characteristic.service?.serviceType,
                        characteristicUniqueIdentifier: a.characteristic.uniqueIdentifier.uuidString)
        }
        let sceneDetail = SceneDetail(home: home.name, uniqueIdentifier: actionSet.uniqueIdentifier, name: actionSet.name,
                                      isBuiltIn: actionSet.actionSetType != HMActionSetTypeUserDefined, actions: actions,
                                      totalActions: actionSet.actions.count, decodedActions: writeActions.count)
        
        let jsonEncoder = JSONEncoder()
        let jsonData = try jsonEncoder.encode(sceneDetail)
        let json = String(data: jsonData, encoding: .utf8)
        
        return json!
    }
    
    /// POST /scenes/:home/:scene/execute - Execute a scene
    func executeScene(_ request: HBRequest) throws -> String {
        let logger = Logger(subsystem: "app.prefab", category: "executeScene")
        let homeName = try getRequiredParam(param: "home", request: request)
        let sceneId = try getRequiredParam(param: "scene", request: request)
        
        guard let home = homeBase.homes.first(where: { $0.name == homeName.removingPercentEncoding }) else {
            logger.error("Home not found: \(homeName, privacy: .public)")
            throw PrefabJSONError.notFound("home")
        }
        
        guard let sceneUUID = UUID(uuidString: sceneId),
              let actionSet = home.actionSets.first(where: { $0.uniqueIdentifier == sceneUUID }) else {
            logger.error("Scene not found: \(sceneId, privacy: .public)")
            throw PrefabJSONError.notFound("scene")
        }
        
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
        if group.wait(timeout: .now() + PrefabTimeouts.sceneSeconds) == .timedOut { throw PrefabJSONError(status: .gatewayTimeout, payload: ["error": "scene_timeout"]) }
        
        if let error = executeError {
            throw PrefabJSONError(status: .internalServerError, payload: ["error": "scene_failed", "message": error.localizedDescription])
        }
        
        let response = ["success": true, "scene": actionSet.name] as [String: Any]
        let jsonData = try JSONSerialization.data(withJSONObject: response)
        return String(data: jsonData, encoding: .utf8)!
    }
}
