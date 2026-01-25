//
//  HomeStore.swift
//  rikerd
//
//  Created by Kelly Plummer on 2/14/24.
//

import Foundation
import HomeKit
import OSLog

private let _homeBaseFileLoaded: () = {
    print("HOMEBASE FILE LOADED: HomeBase.swift is compiled and loaded!")
}()

/// A container for the home manager that's accessible throughout the app.
class HomeBase: NSObject, ObservableObject, HMHomeManagerDelegate, HMAccessoryDelegate {
    /// A singleton that can be used anywhere in the app to access the home manager.
    static var shared = HomeBase()
    
    /// Webhook URL for posting HomeKit events
    static var eventWebhookURL: URL? = URL(string: "http://localhost:4567/event")

    @Published var homes: [HMHome] = []
    
    /// Flag to track if initial observation has been performed
    private var didInitialObserve = false
    
    override init(){
        super.init()
        print("HOMEBASE: HomeBase singleton initialized! Setting up delegate...")
        Logger().log("HomeBase singleton initialized! Setting up delegate...")
        homeManager.delegate = self
        
        print("HOMEBASE: Number of homes at init: \(self.homeManager.homes.count)")
        Logger().log("Number of homes at init: \(self.homeManager.homes.count)")
        print("HOMEBASE: Init complete - waiting for homeManagerDidUpdateHomes callback")
    }
    
    /// The one and only home manager that belongs to the home store singleton.
    @Published var homeManager = HMHomeManager()

    /// A set of objects that want to receive accessory delegate callbacks.
    @Published var accessoryDelegates = Set<NSObject>()
    
    func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        print("HOMEBASE: homeManagerDidUpdateHomes called")
        Logger().log("Manager: \(manager)")
        Logger().log("Homes: \(manager.homes)")
        homes = manager.homes
        
        print("HOMEBASE: Number of homes after update: \(manager.homes.count)")
        Logger().log("Number of homes after update: \(manager.homes.count)")
        
        // Perform initial observation only once
        if !didInitialObserve {
            didInitialObserve = true
            print("HOMEBASE: Starting initial accessory observation...")
            
            // Observe all current accessories
            for home in manager.homes {
                print("HOMEBASE: Observing home: \(home.name)")
                for accessory in home.accessories {
                    let roomName = accessory.room?.name ?? "No Room"
                    let targetRoomName = "Master Bath"  // target room for subscription
                    
                    if roomName != targetRoomName {
                       // print("HOMEBASE: Skipping accessory '\(accessory.name)' in room '\(roomName)' - only targeting room 'Master Bath'")
                        continue
                    }
                    
                    // Filter for sensors only
                    let accessoryNameLower = accessory.name.lowercased()
                    if !accessoryNameLower.contains("sensor") && !accessoryNameLower.contains("motion") && !accessoryNameLower.contains("light sensor") && !accessoryNameLower.contains("temp") {
                        print("HOMEBASE: Skipping accessory '\(accessory.name)' in room '\(roomName)' - not a sensor")
                        continue
                    }
                    
                    print("HOMEBASE: TARGET SENSOR FOUND - '\(accessory.name)' in room '\(roomName)' - subscribing...")
                    
                    accessory.delegate = self
                    print("HOMEBASE: DELEGATE ATTACHED to accessory '\(accessory.name)' in room '\(accessory.room?.name ?? "No Room")'")
                    accessoryDelegates.insert(accessory)
                    
                    // Subscribe to notifications for relevant characteristics
                    for service in accessory.services {
                        for characteristic in service.characteristics {
                            print("HOMEBASE: Checking characteristic '\(characteristic.localizedDescription)' on accessory '\(accessory.name)' in room '\(roomName)' - readable: \(characteristic.properties.contains(HMCharacteristicPropertyReadable)), supports notification: \(characteristic.properties.contains(HMCharacteristicPropertySupportsEventNotification))")
                            Logger().log("Checking characteristic '\(characteristic.localizedDescription)' on accessory '\(accessory.name)' in room '\(roomName)' - readable: \(characteristic.properties.contains(HMCharacteristicPropertyReadable)), supports notification: \(characteristic.properties.contains(HMCharacteristicPropertySupportsEventNotification))")
                            
                            if characteristic.properties.contains(HMCharacteristicPropertyReadable) &&
                               characteristic.properties.contains(HMCharacteristicPropertySupportsEventNotification) {
                                characteristic.enableNotification(true) { error in
                                    if let error = error {
                                        print("HOMEBASE: Failed to enable notification for \(characteristic.localizedDescription) on \(accessory.name) in room '\(roomName)': \(error.localizedDescription)")
                                        Logger().log("Failed to enable notification for \(characteristic.localizedDescription) on \(accessory.name) in room '\(roomName)': \(error.localizedDescription)")
                                    } else {
                                        print("HOMEBASE: SUCCESS: Subscribed to \(characteristic.localizedDescription) on \(accessory.name) in room '\(roomName)'")
                                        Logger().log("SUCCESS: Subscribed to \(characteristic.localizedDescription) on \(accessory.name) in room '\(roomName)'")
                                    }
                                }
                            }
                        }
                    }
                }
            }
            
            print("HOMEBASE: Finished initial accessory observation and subscription for \(manager.homes.flatMap { $0.accessories }.count) accessories.")
            Logger().log("Finished initial accessory observation and subscription for \(manager.homes.flatMap { $0.accessories }.count) accessories.")
            print("HOMEBASE: Delegate test complete - attached to \(accessoryDelegates.count) accessories")
        }
        
        // Send webhook notification
        guard let webhookURL = HomeBase.eventWebhookURL else { return }
        
        let payload: [String: Any] = [
            "type": "homes_updated",
            "home_count": manager.homes.count,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
            print("Failed to serialize JSON payload")
            return
        }
        
        var request = URLRequest(url: webhookURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("Webhook POST error: \(error.localizedDescription)")
            }
        }.resume()
    }
    
    func getHomes() {
        
    }
    
    // MARK: - HMAccessoryDelegate
    
    func accessory(_ accessory: HMAccessory, didUpdateValueFor characteristic: HMCharacteristic) {
        let roomName = accessory.room?.name ?? "No Room"
        print("🔥🔥🔥 DELEGATE FIRED 🔥🔥🔥 accessory='\(accessory.name ?? "unknown")' room='\(roomName)' characteristic='\(characteristic.localizedDescription)' value=\(String(describing: characteristic.value)) timestamp=\(Date())")
        print("HOMEBASE: didUpdateValueFor called for accessory \(accessory.name)")
        Logger().log("didUpdateValueFor called for accessory \(accessory.name)")
        
        // Keep logging for console output
        print("HOMEBASE: UPDATE: Accessory '\(accessory.name)' in room '\(roomName)' | Service '\(characteristic.service?.localizedDescription ?? "unknown")' | Char '\(characteristic.localizedDescription)' updated to '\(String(describing: characteristic.value))' at \(Date())")
        Logger().log("UPDATE: Accessory '\(accessory.name)' in room '\(roomName)' | Service '\(characteristic.service?.localizedDescription ?? "unknown")' | Char '\(characteristic.localizedDescription)' updated to '\(String(describing: characteristic.value))' at \(Date())")
        
        // Send webhook notification
        guard let webhookURL = HomeBase.eventWebhookURL else { return }
        
        let payload: [String: Any] = [
            "type": "characteristic_updated",
            "accessory": accessory.name,
            "characteristic": characteristic.localizedDescription,
            "value": characteristic.value ?? "nil",
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
            print("Failed to serialize JSON payload")
            return
        }
        
        var request = URLRequest(url: webhookURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("Webhook POST error: \(error.localizedDescription)")
            }
        }.resume()
    }
    
    // MARK: - HMHomeDelegate (for accessory management)
    
    func home(_ home: HMHome, didAddAccessory accessory: HMAccessory) {
        accessory.delegate = self
        accessoryDelegates.insert(accessory)
        
        // Subscribe to notifications for relevant characteristics
        for service in accessory.services {
            for characteristic in service.characteristics {
                print("HOMEBASE: Checking characteristic '\(characteristic.localizedDescription)' on accessory '\(accessory.name)' - readable: \(characteristic.properties.contains(HMCharacteristicPropertyReadable)), supports notification: \(characteristic.properties.contains(HMCharacteristicPropertySupportsEventNotification))")
                Logger().log("Checking characteristic '\(characteristic.localizedDescription)' on accessory '\(accessory.name)' - readable: \(characteristic.properties.contains(HMCharacteristicPropertyReadable)), supports notification: \(characteristic.properties.contains(HMCharacteristicPropertySupportsEventNotification))")
                
                if characteristic.properties.contains(HMCharacteristicPropertyReadable) &&
                   characteristic.properties.contains(HMCharacteristicPropertySupportsEventNotification) {
                    characteristic.enableNotification(true) { error in
                        if let error = error {
                            print("HOMEBASE: Failed to enable notification for \(characteristic.localizedDescription): \(error.localizedDescription)")
                            Logger().log("Failed to enable notification for \(characteristic.localizedDescription): \(error.localizedDescription)")
                        } else {
                            print("HOMEBASE: SUCCESS: Subscribed to \(characteristic.localizedDescription) on \(accessory.name)")
                            Logger().log("SUCCESS: Subscribed to \(characteristic.localizedDescription) on \(accessory.name)")
                        }
                    }
                }
            }
        }
    }
    
    func home(_ home: HMHome, didRemoveAccessory accessory: HMAccessory) {
        accessoryDelegates.remove(accessory)
    }
}
