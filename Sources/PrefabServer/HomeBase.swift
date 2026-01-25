//
//  HomeBase.swift
//  PrefabServer
//
//  HomeKit manager wrapper
//

import Foundation
import Combine
import HomeKit
import OSLog

let _ = {
    print("HOMEBASE FILE LOADED: HomeBase.swift is compiled and loaded!")
}()

/// A container for the home manager that's accessible throughout the app.
@available(macCatalyst 14.0, *)
public class HomeBase: NSObject, ObservableObject, HMHomeManagerDelegate, HMAccessoryDelegate {
    /// A singleton that can be used anywhere in the app to access the home manager.
    public static var shared = HomeBase()
    
    /// Webhook URL for posting HomeKit events
    public static var eventWebhookURL: URL? = URL(string: "http://localhost:4567/event")

    @Published public var homes: [HMHome] = []
    
    public override init(){
        super.init()
        print("HOMEBASE: HomeBase singleton initialized! Starting accessory observation...")
        Logger().log("HomeBase singleton initialized! Starting accessory observation...")
        homeManager.delegate = self
        
        print("HOMEBASE: Number of homes at init: \(homeManager.homes.count)")
        Logger().log("Number of homes at init: \(homeManager.homes.count)")
        
        // Observe all current accessories
        for home in homeManager.homes {
            for accessory in home.accessories {
                accessory.delegate = self
                accessoryDelegates.insert(accessory)
                
                // Subscribe to notifications for relevant characteristics
                for service in accessory.services {
                    for characteristic in service.characteristics {
                        print("HOMEBASE: Checking characteristic '\(characteristic.localizedDescription)' on accessory '\(accessory.name ?? "unknown")' - readable: \(characteristic.properties.contains(.readable)), supports notification: \(characteristic.properties.contains(.supportsEventNotification))")
                        Logger().log("Checking characteristic '\(characteristic.localizedDescription)' on accessory '\(accessory.name ?? "unknown")' - readable: \(characteristic.properties.contains(.readable)), supports notification: \(characteristic.properties.contains(.supportsEventNotification))")
                        
                        if characteristic.properties.contains(.readable) &&
                           characteristic.properties.contains(.supportsEventNotification) {
                            characteristic.enableNotification(true) { error in
                                if let error = error {
                                    print("HOMEBASE: Failed to enable notification for \(characteristic.localizedDescription): \(error.localizedDescription)")
                                    Logger().log("Failed to enable notification for \(characteristic.localizedDescription): \(error.localizedDescription)")
                                } else {
                                    print("HOMEBASE: SUCCESS: Subscribed to \(characteristic.localizedDescription) on \(accessory.name ?? "unknown")")
                                    Logger().log("SUCCESS: Subscribed to \(characteristic.localizedDescription) on \(accessory.name ?? "unknown")")
                                }
                            }
                        }
                    }
                }
            }
        }
        
        // Force refresh on launch
        homeManager.homes.forEach { home in
            home.accessories.forEach { accessory in
                accessory.updateReachability()
            }
        }
        
        print("HOMEBASE: Finished initial accessory observation and subscription for \(homeManager.homes.flatMap { $0.accessories }.count) accessories.")
        Logger().log("Finished initial accessory observation and subscription for \(homeManager.homes.flatMap { $0.accessories }.count) accessories.")
        print("HOMEBASE: Init complete - \(homeManager.homes.flatMap { $0.accessories }.count) accessories observed")
    }
    
    /// The one and only home manager that belongs to the home store singleton.
    @Published public var homeManager = HMHomeManager()

    /// A set of objects that want to receive accessory delegate callbacks.
    @Published public var accessoryDelegates = Set<NSObject>()
    
    public func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        Logger().log("Manager: \(manager)")
        Logger().log("Homes: \(manager.homes)")
        homes = manager.homes
        
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
    
    public func getHomes() {
        
    }
    
    // MARK: - HMAccessoryDelegate
    
    public func accessory(_ accessory: HMAccessory, didUpdateValueFor characteristic: HMCharacteristic) {
        print("HOMEBASE: didUpdateValueFor called for accessory \(accessory.name ?? "unknown")")
        Logger().log("didUpdateValueFor called for accessory \(accessory.name ?? "unknown")")
        
        // Keep logging for console output
        print("HOMEBASE: UPDATE: Accessory '\(accessory.name ?? accessory.uniqueIdentifier.uuidString)' | Service '\(characteristic.service?.localizedDescription ?? "unknown")' | Char '\(characteristic.localizedDescription)' updated to '\(String(describing: characteristic.value))' at \(Date())")
        Logger().log("UPDATE: Accessory '\(accessory.name ?? accessory.uniqueIdentifier.uuidString)' | Service '\(characteristic.service?.localizedDescription ?? "unknown")' | Char '\(characteristic.localizedDescription)' updated to '\(String(describing: characteristic.value))' at \(Date())")
        
        // Send webhook notification
        guard let webhookURL = HomeBase.eventWebhookURL else { return }
        
        let payload: [String: Any] = [
            "type": "characteristic_updated",
            "accessory": accessory.name ?? accessory.uniqueIdentifier.uuidString,
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
    
    public func home(_ home: HMHome, didAddAccessory accessory: HMAccessory) {
        accessory.delegate = self
        accessoryDelegates.insert(accessory)
        
        // Subscribe to notifications for relevant characteristics
        for service in accessory.services {
            for characteristic in service.characteristics {
                print("HOMEBASE: Checking characteristic '\(characteristic.localizedDescription)' on accessory '\(accessory.name ?? "unknown")' - readable: \(characteristic.properties.contains(.readable)), supports notification: \(characteristic.properties.contains(.supportsEventNotification))")
                Logger().log("Checking characteristic '\(characteristic.localizedDescription)' on accessory '\(accessory.name ?? "unknown")' - readable: \(characteristic.properties.contains(.readable)), supports notification: \(characteristic.properties.contains(.supportsEventNotification))")
                
                if characteristic.properties.contains(.readable) &&
                   characteristic.properties.contains(.supportsEventNotification) {
                    characteristic.enableNotification(true) { error in
                        if let error = error {
                            print("HOMEBASE: Failed to enable notification for \(characteristic.localizedDescription): \(error.localizedDescription)")
                            Logger().log("Failed to enable notification for \(characteristic.localizedDescription): \(error.localizedDescription)")
                        } else {
                            print("HOMEBASE: SUCCESS: Subscribed to \(characteristic.localizedDescription) on \(accessory.name ?? "unknown")")
                            Logger().log("SUCCESS: Subscribed to \(characteristic.localizedDescription) on \(accessory.name ?? "unknown")")
                        }
                    }
                }
            }
        }
    }
    
    public func home(_ home: HMHome, didRemoveAccessory accessory: HMAccessory) {
        accessoryDelegates.remove(accessory)
    }
}

