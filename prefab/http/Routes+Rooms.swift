//
//  Routes+Rooms.swift
//  Prefab
//
//  Created by kelly on 2/25/24.
//

import Foundation
import Hummingbird

extension Server {
    func getRooms(_ request: HBRequest) throws -> String {
        let homeName = try getRequiredParam(param: "home", request: request)
        let home = homeBase.homes.first(where: {$0.name == homeName.removingPercentEncoding})
        if (home == nil) {
            throw HBHTTPError(.notFound)
        }
        var rooms = home!.rooms.map{Room(home: home!.name, name: $0.name)}
        // P17 (FR-A5): HomeKit's Default Room is not in home.rooms; list it under its own (localized) name.
        rooms.append(Room(home: home!.name, name: home!.roomForEntireHome().name, isDefaultRoom: true))
        let jsonEncoder = JSONEncoder()
        let jsonData = try jsonEncoder.encode(rooms)
        let json = String(data: jsonData, encoding: String.Encoding.utf8)
        
        return json!
    }
    
    func getRoom(_ request: HBRequest) throws -> String {
        let homeName = try getRequiredParam(param: "home", request: request)
        let roomName = try getRequiredParam(param: "room", request: request)
        let home = homeBase.homes.first(where: {$0.name == homeName.removingPercentEncoding})
        if (home == nil) {
            throw HBHTTPError(.notFound)
        }
        let room = home?.rooms.first(where: {$0.name == roomName.removingPercentEncoding})
        let defaultRoom = home!.roomForEntireHome()
        // P17 (FR-A5): a user room wins its name; otherwise the Default Room resolves by its name, never the literal "Default Room".
        if (room == nil && defaultRoom.name != roomName.removingPercentEncoding) {
            throw HBHTTPError(.notFound)
        }
        let jsonEncoder = JSONEncoder()
        let jsonData = try jsonEncoder.encode(room != nil ? Room(home: home!.name, name: room!.name)
                                                          : Room(home: home!.name, name: defaultRoom.name, isDefaultRoom: true))
        let json = String(data: jsonData, encoding: String.Encoding.utf8)
        
        return json!
    }
}
