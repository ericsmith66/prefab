//
//  PrefabConfig.swift
//  prefab
//
//  Configuration model for Prefab HomeKit monitoring
//

import Foundation

/// Configuration for Prefab HomeKit monitoring and callbacks
struct PrefabConfig: Codable {
    /// Webhook/callback server configuration
    var webhook: WebhookConfig
    
    /// Polling configuration
    var polling: PollingConfig
    
    /// Device registry - which devices to poll (empty = poll all)
    var deviceRegistry: DeviceRegistry
    
    /// Logging configuration
    var logging: LoggingConfig
    
    /// Default configuration
    static let `default` = PrefabConfig(
        webhook: WebhookConfig(
            url: "http://localhost:4567/event",
            authToken: nil,
            enabled: true
        ),
        polling: PollingConfig(
            intervalSeconds: 5.0,
            enabled: true,
            reportIntervalSeconds: 60.0
        ),
        deviceRegistry: DeviceRegistry(
            mode: .all,
            devices: []
        ),
        logging: LoggingConfig(
            enabled: false,
            logAllCallbacks: false,
            logOnlyChanges: true,
            maxCallbacksPerSecond: 10
        )
    )
    
    /// Webhook/callback server settings
    struct WebhookConfig: Codable {
        /// Full URL of the callback server
        var url: String
        
        /// Optional authentication token for webhook requests
        var authToken: String?
        
        /// Whether webhooks are enabled
        var enabled: Bool
        
        /// Computed URL from string
        var webhookURL: URL? {
            return URL(string: url)
        }
    }
    
    /// Polling settings
    struct PollingConfig: Codable {
        /// How often to poll accessories (in seconds)
        var intervalSeconds: TimeInterval
        
        /// Whether polling is enabled
        var enabled: Bool
        
        /// How often to generate accessory reports (in seconds)
        var reportIntervalSeconds: TimeInterval
        
        /// Computed ticks per report (for timer-based reporting)
        var ticksPerReport: Int {
            return Int(reportIntervalSeconds / intervalSeconds)
        }
    }
    
    /// Logging settings
    struct LoggingConfig: Codable {
        /// Whether file logging is enabled at all
        var enabled: Bool
        
        /// Whether to log every callback to file
        var logAllCallbacks: Bool
        
        /// Whether to log only value changes (not repeated values)
        var logOnlyChanges: Bool
        
        /// Maximum callbacks to log per second (0 = unlimited)
        var maxCallbacksPerSecond: Int
    }
    
    /// Device registry settings
    struct DeviceRegistry: Codable {
        /// Registry mode
        var mode: RegistryMode
        
        /// List of devices (UUIDs or names)
        var devices: [String]
        
        enum RegistryMode: String, Codable {
            /// Poll all accessories
            case all
            
            /// Only poll accessories in the registry
            case whitelist
            
            /// Poll all except accessories in the registry
            case blacklist
        }
    }
}

/// Configuration manager for loading/saving Prefab configuration
class PrefabConfigManager {
    /// Singleton instance
    static let shared = PrefabConfigManager()
    
    /// Current configuration
    private(set) var config: PrefabConfig
    
    /// Cached device set for fast lookup (updated when config changes)
    private var deviceSet: Set<String> = []
    
    /// Configuration file location in Application Support
    private let configFileURL: URL
    
    private init() {
        // Set up config file location (FR-A8: PREFAB_CONFIG_PATH, default ~/Library/Application Support/Prefab/config.json)
        self.configFileURL = URL(fileURLWithPath: PrefabEnvironment.configPath)
        try? FileManager.default.createDirectory(at: configFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        
        // Load or create default config
        if let loadedConfig = Self.loadConfig(from: configFileURL) {
            self.config = loadedConfig
        } else {
            self.config = .default
            // Save default config for user to edit
            self.saveConfig()
        }
        
        // Cache device set for fast lookup
        self.deviceSet = Set(config.deviceRegistry.devices)
    }
    
    /// Load configuration from file
    private static func loadConfig(from url: URL) -> PrefabConfig? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            let config = try decoder.decode(PrefabConfig.self, from: data)
            return config
        } catch {
            return nil
        }
    }
    
    /// Save current configuration to file
    @discardableResult
    func saveConfig() -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try data.write(to: configFileURL)
            return true
        } catch {
            return false
        }
    }
    
    /// Reload configuration from file
    func reloadConfig() {
        if let loadedConfig = Self.loadConfig(from: configFileURL) {
            self.config = loadedConfig
            self.deviceSet = Set(config.deviceRegistry.devices)
        }
    }
    
    /// Update configuration programmatically
    func updateConfig(_ update: (inout PrefabConfig) -> Void) {
        update(&config)
        self.deviceSet = Set(config.deviceRegistry.devices)
        saveConfig()
    }
    
    /// Check if an accessory should be polled based on registry settings
    func shouldPollAccessory(uuid: String, name: String) -> Bool {
        switch config.deviceRegistry.mode {
        case .all:
            return true
            
        case .whitelist:
            // Only poll if in the cached set (O(1) lookup)
            return deviceSet.contains(uuid) || deviceSet.contains(name)
            
        case .blacklist:
            // Poll unless in the cached set (O(1) lookup)
            return !deviceSet.contains(uuid) && !deviceSet.contains(name)
        }
    }
}

// MARK: - Process environment (FR-A8), build info (FR-A1/FR-A2), timeout ladder (O4/O31)

/// Honoured by EVERY build (release included) and reported in /version: PREFAB_PORT (1024–65535, default 8080),
/// PREFAB_CONFIG_PATH, PREFAB_LOG_PATH (absolute). A bad value exits 2 with the variable name on stderr.
/// PREFAB_FORCE_UNAUTHORIZED / PREFAB_FAULT compile to constants in release builds (FR-A2/FR-A3, AC-01-42).
enum PrefabEnvironment {
    static let defaultPort = 8080
    static let defaultConfigPath: String = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Prefab").appendingPathComponent("config.json").path
    static let defaultLogPath: String = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("homebase_debug.log").path

    static let port: Int = {
        guard let raw = ProcessInfo.processInfo.environment["PREFAB_PORT"], !raw.isEmpty else { return defaultPort }
        guard let p = Int(raw), (1024...65535).contains(p) else { die("PREFAB_PORT") }
        return p
    }()
    static let configPath: String = absolutePath("PREFAB_CONFIG_PATH", default: defaultConfigPath)
    static let logPath: String = absolutePath("PREFAB_LOG_PATH", default: defaultLogPath)

    #if DEBUG
    static let forceUnauthorized: Bool = ProcessInfo.processInfo.environment["PREFAB_FORCE_UNAUTHORIZED"] == "1"
    static let fault: String? = {
        let v = ProcessInfo.processInfo.environment["PREFAB_FAULT"]
        return (v == "write_failed" || v == "write_timeout") ? v : nil
    }()
    #else
    static let forceUnauthorized: Bool = false
    static let fault: String? = nil
    #endif

    private static func absolutePath(_ name: String, default def: String) -> String {
        guard let raw = ProcessInfo.processInfo.environment[name], !raw.isEmpty else { return def }
        guard raw.hasPrefix("/") else { die(name) }
        return raw
    }

    private static func die(_ name: String) -> Never {
        FileHandle.standardError.write("prefab: invalid \(name)\n".data(using: .utf8)!)
        exit(2)
    }
}

/// PrefabBuildInfo.plist, written by scripts/write-build-info.sh at build time (FR-A1).
struct PrefabBuildInfo {
    let gitSHA: String
    let gitDirty: Bool
    let builtAt: String

    static let current: PrefabBuildInfo = {
        guard let url = Bundle.main.url(forResource: "PrefabBuildInfo", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return PrefabBuildInfo(gitSHA: "unknown", gitDirty: true, builtAt: "unknown") }
        return PrefabBuildInfo(gitSHA: dict["GitSHA"] as? String ?? "unknown",
                               gitDirty: dict["GitDirty"] as? Bool ?? true,
                               builtAt: dict["BuiltAt"] as? String ?? "unknown")
    }()

    static var bundleVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }
}

/// One timeout ladder (O4/O31); every Rails limit sits strictly above these (AC-01-53).
enum PrefabTimeouts {
    static let writeSeconds: TimeInterval = 4
    static let sceneSeconds: TimeInterval = 25
    static let readAllSeconds: TimeInterval = 12
    static let readOneSeconds: TimeInterval = 5
}
