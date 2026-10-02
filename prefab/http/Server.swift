//
//  Server.swift
//  rikerd
//
//  Created by Kelly Plummer on 2/14/24.
//

import Foundation
import OSLog
import Hummingbird

struct HomeKitAuthLogger: HBMiddleware {
    func apply(to request: HBRequest, next: HBResponder) -> EventLoopFuture<HBResponse> {
        if request.uri.path == "/version" { return next.respond(to: request) }          // O12: registration order cannot exempt a route
        let homebase = HomeBase.shared                                                   // shared, long-lived (7cbcd7b)
        let authorized = homebase.homeManager.authorizationStatus.contains(.authorized) && !PrefabEnvironment.forceUnauthorized
        Logger().log("HomeKit Authorization status is \(homebase.homeManager.authorizationStatus.rawValue)")
        if !authorized {
            return request.failure(.forbidden, message: "{\"error\": \"Prefab is not authorized to access your HomeKit data.\"}")
        }
        return next.respond(to: request)
    }
}

class Server  {
    var homeBase: HomeBase
    
    init() {
        self.homeBase = HomeBase.shared
        // Start the server on a background thread with a run loop (P12: no mDNS advertising)
        let serverThread = Thread(target: self, selector: #selector(startServer), object: nil)
        serverThread.start()
    }
    
    func getRequiredParam(param: String, request: HBRequest) throws -> String {
        guard let value = request.parameters[param] else {
            throw HBHTTPError(
                .badRequest,
                message: "Invalid \(param) parameter."
            )
        }
        return value
    }
    
    @objc
    func startServer() {
        Task{
            // P12: loopback only, no Bonjour. FR-A8: port from the environment.
            let app = HBApplication(configuration: .init(address: .hostname("127.0.0.1", port: PrefabEnvironment.port)))
            app.logger.logLevel = .debug
            app.middleware.add(HBLogRequestsMiddleware(.debug))
            app.middleware.add(HomeKitAuthLogger())
            app.router.get("version", use: self.getVersion)
            app.router.get("homes", use: self.getHomes)
            app.router.get("homes/:home", use: self.getHome)
            app.router.get("rooms/:home", use: self.getRooms)
            app.router.get("rooms/:home/:room", use: self.getRoom)
            app.router.get("accessories/:home/summary", use: self.getAccessorySummary)
            app.router.get("accessories/:home", use: self.getAllAccessories)
            app.router.get("accessories/:home/id/:uuid", use: self.getAccessoryById)       // FR-A4; the trie matches the literal "id" before :room
            app.router.get("accessories/:home/:room", use: self.getAccessories)
            app.router.get("accessories/:home/:room/:accessory", use: self.getAccessory)
            app.router.put("accessories/:home/:room/:accessory", use: self.updateAccessory)
            app.router.get("scenes/:home", use: self.getScenes)
            app.router.get("scenes/:home/:scene", use: self.getScene)
            app.router.post("scenes/:home/:scene/execute", use: self.executeScene)
            app.router.get("groups/:home", use: self.getGroups)
            app.router.get("groups/:home/:group", use: self.getGroup)
            app.router.put("groups/:home/:group", use: self.updateGroup)
            try app.start()
            RunLoop.current.add(Port(), forMode: .default)
            while true { RunLoop.current.run(mode: .default, before: Date.distantFuture) }
            await app.asyncWait()
        }
    }
}
