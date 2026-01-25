//
//  HomeStore.swift
//  rikerd
//
//  Created by Kelly Plummer on 2/14/24.
//

import Foundation
import HomeKit
import OSLog



/// A container for the home manager that's accessible throughout the app.
class HomeBase: NSObject, ObservableObject, HMHomeManagerDelegate, HMAccessoryDelegate, HMHomeDelegate {
    /// A singleton that can be used anywhere in the app to access the home manager.
    static var shared = HomeBase()
    
    /// Configuration manager
    private let configManager = PrefabConfigManager.shared
    
    /// Webhook URL for posting HomeKit events (computed from config)
    static var eventWebhookURL: URL? {
        return PrefabConfigManager.shared.config.webhook.enabled ? 
               PrefabConfigManager.shared.config.webhook.webhookURL : nil
    }

    @Published var homes: [HMHome] = []
    
    /// Flag to track if initial observation has been performed
    private var didInitialObserve = false
    
    /// Polling timer for accessories that don't support notifications
    private var pollingTimer: Timer?
    private var pollingAccessories: [(accessory: HMAccessory, characteristics: [HMCharacteristic])] = []
    
    /// Track native vs polling callbacks
    private var nativeCallbackCount = 0
    private var pollingCallbackCount = 0
    
    /// Track which accessories use native vs polling
    private var nativeAccessories = Set<String>()  // accessory UUIDs that sent native callbacks
    private var pollingOnlyAccessories = Set<String>()  // accessory UUIDs that only respond to polling
    
    /// Map accessory UUIDs to names for better reporting
    private var accessoryNames: [String: String] = [:]  // UUID -> accessory name
    
    /// File logger
    private var logFileHandle: FileHandle?
    private let logFilePath: URL = {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsPath.appendingPathComponent("homebase_debug.log")
    }()
    
    /// Cached date formatter for efficient logging
    private let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        return formatter
    }()
    
    /// Rate limiting for logging
    private var logTimestamps: [Date] = []
    private var lastLoggedValues: [String: Any?] = [:]  // accessoryId+characteristic -> last value
    
    override init(){
        super.init()
        
        // Only setup file logging if enabled in config
        if configManager.config.logging.enabled {
            setupFileLogging()
            logToFile("=== HOMEBASE INITIALIZED ===")
            logToFile("Log file: \(logFilePath.path)")
            logToFile("Homes at init: \(self.homeManager.homes.count)")
        }
        
        homeManager.delegate = self
    }
    
    /// The one and only home manager that belongs to the home store singleton.
    @Published var homeManager = HMHomeManager()

    /// A set of objects that want to receive accessory delegate callbacks.
    @Published var accessoryDelegates = Set<NSObject>()
    
    func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        logToFile("=== homeManagerDidUpdateHomes: \(manager.homes.count) homes ===")
        homes = manager.homes
        
        // Perform initial observation only once
        if !didInitialObserve {
            didInitialObserve = true
            logToFile("Starting initial accessory observation...")
            
            // Observe all current accessories
            for home in manager.homes {
                home.delegate = self
                logToFile("Observing home: \(home.name)")
                for accessory in home.accessories {
                    accessory.delegate = self
                    accessoryDelegates.insert(accessory)
                    
                    // Track accessory name for reporting
                    accessoryNames[accessory.uniqueIdentifier.uuidString] = accessory.name
                    logToFile("Attached: '\(accessory.name)' (reachable: \(accessory.isReachable))")
                    
                    // Subscribe to notifications for relevant characteristics
                    for service in accessory.services {
                        for characteristic in service.characteristics {
                            if characteristic.properties.contains(HMCharacteristicPropertyReadable) &&
                               characteristic.properties.contains(HMCharacteristicPropertySupportsEventNotification) {
                                characteristic.enableNotification(true) { error in
                                    if let error = error {
                                        self.logToFile("Notification failed for \(accessory.name).\(characteristic.localizedDescription): \(error.localizedDescription)")
                                        // Add to polling list as fallback ONLY on error
                                        if let existingIndex = self.pollingAccessories.firstIndex(where: { $0.accessory === accessory }) {
                                            self.pollingAccessories[existingIndex].characteristics.append(characteristic)
                                        } else {
                                            self.pollingAccessories.append((accessory: accessory, characteristics: [characteristic]))
                                        }
                                    }
                                    // Successfully enabled - native callbacks will handle updates
                                }
                            }
                        }
                    }
                }
            }
            
            let totalAccessories = manager.homes.flatMap { $0.accessories }.count
            logToFile("Finished setup: \(totalAccessories) accessories, \(accessoryDelegates.count) delegates")
            
            // Start polling after a delay to let async subscriptions complete
            logToFile("Scheduling polling to start in 2 seconds...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self = self else { return }
                self.logToFile("Polling: \(self.pollingAccessories.count) accessories, enabled: \(self.configManager.config.polling.enabled)")
                
                if !self.pollingAccessories.isEmpty && self.configManager.config.polling.enabled {
                    self.startPolling()
                } else if self.configManager.config.polling.enabled {
                    // Fallback: poll all delegate accessories
                    self.startPollingAllDelegateAccessories()
                }
                
                // Log initial accessory report after 5 seconds to allow some callbacks to arrive
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                    self?.logToFile("=== INITIAL ACCESSORY REPORT (after 5 seconds) ===")
                    self?.logAccessoryReport()
                }
            }
        }
        
        // Send webhook notification
        guard let webhookURL = HomeBase.eventWebhookURL else { return }
        
        let payload: [String: Any] = [
            "type": "homes_updated",
            "home_count": manager.homes.count,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
            return
        }
        
        var request = URLRequest(url: webhookURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Add auth token if configured
        if let authToken = PrefabConfigManager.shared.config.webhook.authToken {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }
        
        request.httpBody = jsonData
        
        URLSession.shared.dataTask(with: request) { _, _, _ in
            // Silently send webhooks, errors logged elsewhere if needed
        }.resume()
    }
    
    func getHomes() {
        
    }
    
    private func startPollingAllDelegateAccessories() {
        logToFile("Starting polling for \(accessoryDelegates.count) delegate accessories")
        
        pollingTimer?.invalidate()
        
        var tickCount = 0
        let pollInterval = configManager.config.polling.intervalSeconds
        let ticksPerReport = configManager.config.polling.ticksPerReport
        
        pollingTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            tickCount += 1
            
            // Log stats based on config (default: every 60 seconds)
            if tickCount % ticksPerReport == 0 {
                self.logToFile("Polling tick #\(tickCount): Native callbacks: \(self.nativeCallbackCount), Polling callbacks: \(self.pollingCallbackCount)")
                self.logAccessoryReport()
            }
            
            for accessory in self.accessoryDelegates {
                guard let hmAccessory = accessory as? HMAccessory else { continue }
                
                // Check if this accessory should be polled based on config
                let uuid = hmAccessory.uniqueIdentifier.uuidString
                let name = hmAccessory.name
                if !self.configManager.shouldPollAccessory(uuid: uuid, name: name) {
                    continue
                }
                
                for service in hmAccessory.services {
                    for characteristic in service.characteristics {
                        if characteristic.properties.contains(HMCharacteristicPropertyReadable) {
                            let oldValue = characteristic.value
                            
                            characteristic.readValue { error in
                                if error == nil {
                                    let newValue = characteristic.value
                                    
                                    // Check if value changed
                                    if let old = oldValue as? NSObject, let new = newValue as? NSObject {
                                        if !old.isEqual(new) {
                                            // Manually call the handler with POLLING source
                                            self.handleCharacteristicUpdate(hmAccessory, characteristic: characteristic, source: "POLLING")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    
    private func startPolling() {
        pollingTimer?.invalidate()
        
        let pollInterval = configManager.config.polling.intervalSeconds
        logToFile("Starting polling: \(pollingAccessories.count) accessories @ \(pollInterval)s interval")
        pollingTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            for item in self.pollingAccessories {
                // Check if this accessory should be polled based on config
                let uuid = item.accessory.uniqueIdentifier.uuidString
                let name = item.accessory.name
                if !self.configManager.shouldPollAccessory(uuid: uuid, name: name) {
                    continue
                }
                
                for characteristic in item.characteristics {
                    let oldValue = characteristic.value
                    
                    characteristic.readValue { error in
                        if error == nil {
                            let newValue = characteristic.value
                            
                            // Check if value changed
                            if let old = oldValue as? NSObject, let new = newValue as? NSObject {
                                if !old.isEqual(new) {
                                    // Find the service that contains this characteristic
                                    if let service = characteristic.service {
                                        self.accessory(item.accessory, service: service, didUpdateValueFor: characteristic)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Accessory Tracking Report
    
    /// Generates and logs a detailed report of which accessories use native callbacks vs polling
    public func logAccessoryReport() {
        let totalAccessories = accessoryNames.count
        let nativeCount = nativeAccessories.count
        let pollingOnlyCount = pollingOnlyAccessories.count
        let bothCount = nativeAccessories.intersection(Set(pollingOnlyAccessories)).count
        let neitherCount = totalAccessories - nativeCount - pollingOnlyCount + bothCount
        
        var report = """
        
        ╔════════════════════════════════════════════════════════════════════
        ║ 📊 ACCESSORY CALLBACK REPORT
        ╠════════════════════════════════════════════════════════════════════
        ║ Total Accessories: \(totalAccessories)
        ║ Native Callback Count: \(nativeCallbackCount)
        ║ Polling Callback Count: \(pollingCallbackCount)
        ╠════════════════════════════════════════════════════════════════════
        ║ Accessories with Native Callbacks: \(nativeCount) (\(totalAccessories > 0 ? String(format: "%.1f", Double(nativeCount) * 100.0 / Double(totalAccessories)) : "0")%)
        ║ Accessories with Polling Only: \(pollingOnlyCount) (\(totalAccessories > 0 ? String(format: "%.1f", Double(pollingOnlyCount) * 100.0 / Double(totalAccessories)) : "0")%)
        ║ Accessories with Both: \(bothCount)
        ║ Accessories with Neither: \(neitherCount)
        ╠════════════════════════════════════════════════════════════════════
        """
        
        // List accessories using native callbacks
        if !nativeAccessories.isEmpty {
            report += "\n║ 🔥 NATIVE CALLBACK ACCESSORIES:\n"
            for uuid in nativeAccessories.sorted() {
                let name = accessoryNames[uuid] ?? "Unknown"
                let isAlsoPolling = pollingOnlyAccessories.contains(uuid) ? " (also polling)" : ""
                report += "║   • \(name)\(isAlsoPolling)\n"
            }
            report += "╠════════════════════════════════════════════════════════════════════\n"
        }
        
        // List accessories using polling only
        if !pollingOnlyAccessories.isEmpty {
            report += "\n║ 🔄 POLLING-ONLY ACCESSORIES:\n"
            for uuid in pollingOnlyAccessories.sorted() {
                if !nativeAccessories.contains(uuid) {
                    let name = accessoryNames[uuid] ?? "Unknown"
                    report += "║   • \(name)\n"
                }
            }
            report += "╠════════════════════════════════════════════════════════════════════\n"
        }
        
        // List accessories with no updates yet
        let accessoriesWithNoUpdates = Set(accessoryNames.keys)
            .subtracting(nativeAccessories)
            .subtracting(pollingOnlyAccessories)
        
        if !accessoriesWithNoUpdates.isEmpty {
            report += "\n║ ⏳ ACCESSORIES WITH NO UPDATES YET:\n"
            for uuid in accessoriesWithNoUpdates.sorted() {
                let name = accessoryNames[uuid] ?? "Unknown"
                report += "║   • \(name)\n"
            }
            report += "╠════════════════════════════════════════════════════════════════════\n"
        }
        
        report += "╚════════════════════════════════════════════════════════════════════\n"
        
        logToFile(report)
    }
    
    deinit {
        pollingTimer?.invalidate()
        logFileHandle?.closeFile()
    }
    
    // MARK: - File Logging
    
    private func setupFileLogging() {
        // Remove old log file
        try? FileManager.default.removeItem(at: logFilePath)
        
        // Create new log file
        FileManager.default.createFile(atPath: logFilePath.path, contents: nil, attributes: nil)
        logFileHandle = try? FileHandle(forWritingTo: logFilePath)
        
        let header = """
        ==========================================
        HOMEBASE DEBUG LOG
        Started: \(Date())
        ==========================================
        
        """
        logToFile(header)
    }
    
    private func logToFile(_ message: String) {
        // Early exit if logging disabled - don't even format the string
        guard configManager.config.logging.enabled else { return }
        guard let handle = logFileHandle else { return }
        
        let timestamp = dateFormatter.string(from: Date())
        let logMessage = "[\(timestamp)] \(message)\n"
        
        if let data = logMessage.data(using: .utf8) {
            handle.write(data)
        }
    }
    
    // MARK: - HMAccessoryDelegate
    
    func accessory(_ accessory: HMAccessory, service: HMService, didUpdateValueFor characteristic: HMCharacteristic) {
        // This is a NATIVE callback from HomeKit!
        nativeCallbackCount += 1
        handleCharacteristicUpdate(accessory, characteristic: characteristic, source: "NATIVE")
    }
    
    private func handleCharacteristicUpdate(_ accessory: HMAccessory, characteristic: HMCharacteristic, source: String) {
        let accessoryId = accessory.uniqueIdentifier.uuidString
        let config = configManager.config.logging
        
        if source == "NATIVE" {
            nativeAccessories.insert(accessoryId)
        } else {
            pollingCallbackCount += 1
            // Only mark as polling-only if it hasn't sent native callbacks
            if !nativeAccessories.contains(accessoryId) {
                pollingOnlyAccessories.insert(accessoryId)
            }
        }
        
        // Early exit if logging is disabled
        guard config.enabled else {
            // Still send webhook even if logging is disabled
            sendWebhook(accessory: accessory, characteristic: characteristic)
            return
        }
        
        // Determine if we should log this callback
        var shouldLog = config.logAllCallbacks
        
        if !shouldLog && config.logOnlyChanges {
            // Only log if value changed
            let key = "\(accessoryId):\(characteristic.uniqueIdentifier.uuidString)"
            let currentValue = characteristic.value as? NSObject
            let lastValue = lastLoggedValues[key] as? NSObject
            
            if lastValue == nil || !(lastValue?.isEqual(currentValue) ?? false) {
                shouldLog = true
                lastLoggedValues[key] = characteristic.value
            }
        }
        
        // Apply rate limiting
        if shouldLog && config.maxCallbacksPerSecond > 0 {
            let now = Date()
            // Remove timestamps older than 1 second
            logTimestamps = logTimestamps.filter { now.timeIntervalSince($0) < 1.0 }
            
            if logTimestamps.count < config.maxCallbacksPerSecond {
                logTimestamps.append(now)
            } else {
                shouldLog = false  // Rate limit exceeded
            }
        }
        
        if shouldLog {
            let count = source == "NATIVE" ? nativeCallbackCount : pollingCallbackCount
            logToFile("[\(source)] \(accessory.name) - \(characteristic.localizedDescription): \(String(describing: characteristic.value))")
        }
        
        // Send webhook notification
        sendWebhook(accessory: accessory, characteristic: characteristic)
    }
    
    private func sendWebhook(accessory: HMAccessory, characteristic: HMCharacteristic) {
        guard let webhookURL = HomeBase.eventWebhookURL else { return }
        
        // Convert characteristic value to JSON-safe format
        let safeValue: Any
        if let value = characteristic.value {
            if let data = value as? Data {
                // Convert Data to base64 string
                safeValue = data.base64EncodedString()
            } else if JSONSerialization.isValidJSONObject([value]) {
                // Value is already JSON-safe
                safeValue = value
            } else {
                // Fallback to string description
                safeValue = String(describing: value)
            }
        } else {
            safeValue = NSNull()
        }
        
        let payload: [String: Any] = [
            "type": "characteristic_updated",
            "accessory": accessory.name,
            "characteristic": characteristic.localizedDescription,
            "value": safeValue,
            "timestamp": dateFormatter.string(from: Date())
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
            logToFile("⚠️ Failed to serialize webhook payload for \(accessory.name) - \(characteristic.localizedDescription)")
            return
        }
        
        var request = URLRequest(url: webhookURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Add auth token if configured
        if let authToken = PrefabConfigManager.shared.config.webhook.authToken {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }
        
        request.httpBody = jsonData
        
        URLSession.shared.dataTask(with: request) { _, _, _ in
            // Silently send webhooks
        }.resume()
    }
    
    // MARK: - HMHomeDelegate (for accessory management)
    
    func home(_ home: HMHome, didAdd accessory: HMAccessory) {
        accessory.delegate = self
        accessoryDelegates.insert(accessory)
        
        // Track accessory name for reporting
        accessoryNames[accessory.uniqueIdentifier.uuidString] = accessory.name
        
        // Subscribe to notifications for relevant characteristics
        for service in accessory.services {
            for characteristic in service.characteristics {
                if characteristic.properties.contains(HMCharacteristicPropertyReadable) &&
                   characteristic.properties.contains(HMCharacteristicPropertySupportsEventNotification) {
                    characteristic.enableNotification(true) { _ in
                        // Silently subscribe to notifications
                    }
                }
            }
        }
    }
    
    func home(_ home: HMHome, didRemove accessory: HMAccessory) {
        accessoryDelegates.remove(accessory)
    }
}
