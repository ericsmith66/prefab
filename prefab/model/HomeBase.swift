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
    
    /// S″ failed-only polling (PRD-1-01 plan § 15.18 R7-7): the subscription ledger, the planner and the per-bridge
    /// scheduler live in prefab/core/PollingCore.swift (HomeKit-free, tested hostless). HomeBase registers each
    /// subscription, reports its completion and performs the reads the coordinator asks for. Poll-all no longer exists.
    private let pollingQueue = DispatchQueue(label: "app.prefab.polling")
    /// characteristic uuid → its accessory and characteristic, for the reads; touched on pollingQueue only.
    private var pollTargets: [String: (accessory: HMAccessory, characteristic: HMCharacteristic)] = [:]
    private lazy var polling: PollingCoordinator = makePollingCoordinator()
    
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
    private let logFilePath = URL(fileURLWithPath: PrefabEnvironment.logPath)
    
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
        _ = polling   // created here, before any HomeKit completion can reach it (lazy vars are not thread-safe)
        
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
                let bridges = bridgeKeys(of: home)
                for accessory in home.accessories {
                    accessory.delegate = self
                    accessoryDelegates.insert(accessory)
                    
                    // Track accessory name for reporting
                    accessoryNames[accessory.uniqueIdentifier.uuidString] = accessory.name
                    logToFile("Attached: '\(accessory.name)' (reachable: \(accessory.isReachable))")
                    
                    // Subscribe to notifications for relevant characteristics, each through the ledger (S″, R7-7 item 1)
                    subscribe(accessory, bridgeKey: bridges[accessory.uniqueIdentifier] ?? accessory.uniqueIdentifier.uuidString)
                }
            }
            
            let totalAccessories = manager.homes.flatMap { $0.accessories }.count
            logToFile("Finished setup: \(totalAccessories) accessories, \(accessoryDelegates.count) delegates")
            
            // O27 (R7-7 item 2): the polling startup line prints when every subscription completion is in, or 60 s
            // after setup, whichever is first; then only FAILED subscriptions are polled, and only if polling is on.
            polling.finishSetup()
            
            // Log initial accessory report 7 seconds after setup (as S′: 2 s + 5 s) to allow some callbacks to arrive
            DispatchQueue.main.asyncAfter(deadline: .now() + 7.0) { [weak self] in
                self?.logToFile("=== INITIAL ACCESSORY REPORT (after 5 seconds) ===")
                self?.logAccessoryReport()
            }
        }
        
        // Send webhook notification
        guard let webhookURL = HomeBase.eventWebhookURL else { return }
        
        let payload: [String: Any] = [
            "type": "homes_updated",
            "home_count": manager.homes.count,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        
        post(payload, to: webhookURL)
    }
    
    func getHomes() {
        
    }
    
    // MARK: - Failed-only polling (S″, plan R7-7) — the HomeKit side of PollingCoordinator

    /// Every readable, event-capable characteristic is registered in the ledger, THEN gets enableNotification(true);
    /// the completion reports ok or failed(code). Readable characteristics without event support are not subscribable
    /// and are never polled. Also used by home(_:didAdd:), so a later failure gives one change line and a new plan.
    private func subscribe(_ accessory: HMAccessory, bridgeKey: String) {
        for service in accessory.services {
            for characteristic in service.characteristics
            where characteristic.properties.contains(HMCharacteristicPropertyReadable) &&
                  characteristic.properties.contains(HMCharacteristicPropertySupportsEventNotification) {
                let id = characteristic.uniqueIdentifier.uuidString
                pollingQueue.async { self.pollTargets[id] = (accessory, characteristic) }
                polling.register(Subscription(characteristicId: id, accessoryId: accessory.uniqueIdentifier.uuidString,
                                              accessoryName: accessory.name, characteristicName: characteristic.localizedDescription,
                                              bridgeKey: bridgeKey, state: .pending))
                characteristic.enableNotification(true) { error in
                    if let error = error {
                        self.logToFile("Notification failed for \(accessory.name).\(characteristic.localizedDescription): \(error.localizedDescription)")
                    }
                    self.polling.complete(characteristicId: id, errorCode: error.map { ($0 as NSError).code })
                }
            }
        }
    }

    /// bridged accessory uuid → its bridge's uuid (the bridge key); an accessory that is not bridged is its own key.
    private func bridgeKeys(of home: HMHome) -> [UUID: String] {
        var keys: [UUID: String] = [:]
        for bridge in home.accessories {
            for id in bridge.uniqueIdentifiersForBridgedAccessories ?? [] { keys[id] = bridge.uniqueIdentifier.uuidString }
        }
        return keys
    }

    private func makePollingCoordinator() -> PollingCoordinator {
        let queue = pollingQueue
        return PollingCoordinator(
            queue: queue,
            settings: { [unowned self] in
                let p = self.configManager.config.polling
                return PollSettings(enabled: p.enabled, rawLimit: p.maxReadsPerMinutePerBridge,
                                    reportEvery: PollingReport.period(intervalSeconds: p.intervalSeconds, reportIntervalSeconds: p.reportIntervalSeconds))
            },
            include: { [unowned self] id, name in self.configManager.shouldPollAccessory(uuid: id, name: name) },
            log: { [unowned self] line in self.logToFile(line) },
            startRead: { [unowned self] sub, done in                       // on pollingQueue
                guard let target = self.pollTargets[sub.characteristicId] else { done(PollScheduler.abandonedCode); return }
                let oldValue = target.characteristic.value
                target.characteristic.readValue { error in
                    if let error = error { done((error as NSError).code); return }
                    // A changed value goes through the existing path, webhook included (as S′'s polling did).
                    if let old = oldValue as? NSObject, let new = target.characteristic.value as? NSObject, !old.isEqual(new) {
                        self.handleCharacteristicUpdate(target.accessory, characteristic: target.characteristic, source: "POLLING")
                    }
                    done(nil)
                }
            },
            clock: { ProcessInfo.processInfo.systemUptime },
            makeTimer: { interval, handler in DispatchPollTimer(queue: queue, interval: interval, handler: handler) },
            scheduleAfter: { delay, block in queue.asyncAfter(deadline: .now() + delay, execute: block) },
            onReport: { [unowned self] tick in
                DispatchQueue.main.async {
                    self.logToFile("Polling tick #\(tick): Native callbacks: \(self.nativeCallbackCount), Polling callbacks: \(self.pollingCallbackCount)")
                    self.logAccessoryReport()
                }
            })
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
    
    func logToFile(_ message: String) {
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
            "timestamp": dateFormatter.string(from: Date()),
            "accessoryUniqueIdentifier": accessory.uniqueIdentifier.uuidString,                                    // O9
            "room": accessory.room?.name ?? home(of: accessory)?.roomForEntireHome().name ?? "",                   // O9
            "characteristicUniqueIdentifier": characteristic.uniqueIdentifier.uuidString,                          // V5-8 / O38
        ]
        
        post(payload, to: webhookURL)
    }
    
    private func post(_ payload: [String: Any], to url: URL) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
            logToFile("⚠️ Failed to serialize webhook payload \(payload["type"] ?? "?")"); return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authToken = PrefabConfigManager.shared.config.webhook.authToken {          // D1: Bearer when webhook.authToken is set
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = jsonData
        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }

    private func home(of accessory: HMAccessory) -> HMHome? {
        homes.first { $0.accessories.contains(where: { $0.uniqueIdentifier == accessory.uniqueIdentifier }) }
    }
    
    // MARK: - HMHomeDelegate (for accessory management)
    
    func home(_ home: HMHome, didAdd accessory: HMAccessory) {
        accessory.delegate = self
        accessoryDelegates.insert(accessory)
        
        // Track accessory name for reporting
        accessoryNames[accessory.uniqueIdentifier.uuidString] = accessory.name
        
        // S″ (R7-7 item 6): a subscription made later goes through the ledger too; a failure → one change line, new plan
        subscribe(accessory, bridgeKey: bridgeKeys(of: home)[accessory.uniqueIdentifier] ?? accessory.uniqueIdentifier.uuidString)
        sendAccessoriesUpdated(home: home, accessory: accessory, change: "added")
    }
    
    func home(_ home: HMHome, didRemove accessory: HMAccessory) {
        accessoryDelegates.remove(accessory)
        sendAccessoriesUpdated(home: home, accessory: accessory, change: "removed")
    }

    /// FR-A11 / S3: PRD-1-03's sync trigger. Same URL and auth header as every other webhook.
    private func sendAccessoriesUpdated(home: HMHome, accessory: HMAccessory, change: String) {
        guard let webhookURL = HomeBase.eventWebhookURL else { return }
        post(["type": "accessories_updated", "home": home.name, "accessoryUniqueIdentifier": accessory.uniqueIdentifier.uuidString,
              "change": change, "timestamp": dateFormatter.string(from: Date())], to: webhookURL)
        logToFile("accessories_updated change=\(change) uuid=\(accessory.uniqueIdentifier.uuidString) name='\(accessory.name)'")
    }
}
