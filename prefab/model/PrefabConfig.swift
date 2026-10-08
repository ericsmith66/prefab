//
//  PrefabConfig.swift
//  prefab
//
//  Configuration model for Prefab HomeKit monitoring
//

import Foundation
import OSLog

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
    
    /// Default configuration — written only for a MISSING config file (loadOrCreate). S″ (plan R7-7): polling is off
    /// by default, so no default can ever poll; an existing file that fails to decode is never replaced by this.
    static let `default` = PrefabConfig(
        webhook: WebhookConfig(
            url: "http://localhost:4567/event",
            authToken: nil,
            enabled: true
        ),
        polling: PollingConfig(
            intervalSeconds: 5.0,
            enabled: false,
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

        /// S″ (plan R7-7 item 5): at most this many poll reads a minute per bridge. Optional, so an S′ config decodes
        /// unchanged; missing → 6. The scheduler clamps it to 1…30 (PollingLimit, one log line when clamped).
        var maxReadsPerMinutePerBridge: Int? = nil

        static let defaultMaxReadsPerMinutePerBridge = 6
        var maxReadsPerMinutePerBridgeOrDefault: Int { maxReadsPerMinutePerBridge ?? Self.defaultMaxReadsPerMinutePerBridge }

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

/// Why an EXISTING config file was refused (S″, plan R7-7 / R8-6). Never thrown for a missing file.
enum PrefabConfigLoadError: Error, CustomStringConvertible {
    case unreadable(path: String, reason: String)
    case undecodable(path: String, reason: String)

    var description: String {
        switch self {
        case .unreadable(let path, let reason): return "invalid PREFAB_CONFIG_PATH: \(path) cannot be read (\(reason))"
        case .undecodable(let path, let reason): return "invalid PREFAB_CONFIG_PATH: \(path) does not decode (\(reason))"
        }
    }
}

extension PrefabConfig {
    /// The ONE loader (S″, plan R8-6). Pure: no globals, no logging.
    /// - missing file → writes `.default` (polling off) for the user to edit and returns it; a failed write is ignored,
    ///   as S′'s `saveConfig()` ignored it;
    /// - existing file that decodes → returns it; the file is not touched;
    /// - existing file that cannot be read or decoded → throws `PrefabConfigLoadError` and writes NOTHING. (S′ replaced
    ///   such a file with `.default`, whose polling was on — one schema slip would have restarted poll-all.)
    static func loadOrCreate(at url: URL) throws -> PrefabConfig {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]          // as S′'s saveConfig()
            if let data = try? encoder.encode(PrefabConfig.default) { try? data.write(to: url) }
            return .default
        }
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw PrefabConfigLoadError.unreadable(path: url.path, reason: error.localizedDescription)
        }
        do { return try JSONDecoder().decode(PrefabConfig.self, from: data) } catch {
            throw PrefabConfigLoadError.undecodable(path: url.path, reason: String(describing: error))
        }
    }
}

/// Configuration manager for loading Prefab configuration (it never writes over an existing file — S″, R8-6)
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
        // S″ (R8-6): the same loader as validateAtLaunch() — missing → the default (polling off) is written; existing →
        // decoded; undecodable → the unified-log fault line and exit 2, never a save over the file.
        do { self.config = try PrefabConfig.loadOrCreate(at: configFileURL) } catch { PrefabEnvironment.invalidConfig(error) }

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
    
    // S″ (R8-6): saveConfig() and updateConfig() are removed — updateConfig had no caller (measured 2026-10-08), and the
    // only write left is loadOrCreate's missing-file branch.

    /// Reload configuration from file (never writes)
    func reloadConfig() {
        if let loadedConfig = Self.loadConfig(from: configFileURL) {
            self.config = loadedConfig
            self.deviceSet = Set(config.deviceRegistry.devices)
        }
    }

    /// Check if an accessory should be polled based on registry settings (the cached set gives O(1) lookups)
    func shouldPollAccessory(uuid: String, name: String) -> Bool {
        PrefabConfig.DeviceRegistry.includes(mode: config.deviceRegistry.mode, devices: deviceSet, uuid: uuid, name: name)
    }
}

extension PrefabConfig.DeviceRegistry {
    /// shouldPollAccessory's rule, unchanged, as a pure function (S″: the poll planner's hostless tests use it).
    static func includes(mode: RegistryMode, devices: Set<String>, uuid: String, name: String) -> Bool {
        switch mode {
        case .all: return true
        case .whitelist: return devices.contains(uuid) || devices.contains(name)        // only poll what is listed
        case .blacklist: return !devices.contains(uuid) && !devices.contains(name)      // poll all but what is listed
        }
    }

    func includes(uuid: String, name: String) -> Bool { Self.includes(mode: mode, devices: Set(devices), uuid: uuid, name: name) }
}

// MARK: - Process environment (FR-A8), build info (FR-A1/FR-A2), timeout ladder (O4/O31)

/// Honoured by EVERY build (release included) and reported in /version: PREFAB_PORT (1024–65535, default 8080),
/// PREFAB_CONFIG_PATH, PREFAB_LOG_PATH (absolute). A bad value exits 2 with the variable name on stderr.
/// The debug switches (S″, plan R7-9 item 1 — the text R6-7 aligned): Debug builds only: a set (even empty)
/// PREFAB_FORCE_UNAUTHORIZED other than 1 exits 2 at launch; an empty PREFAB_FAULT is off; Release builds ignore both
/// (they compile to constants and read no environment; FR-A2/FR-A3, AC-01-42). A Debug 403 caused by the switch names it
/// (AuthFailure); every other 403 keeps S′'s bytes. An existing PREFAB_CONFIG_PATH file that does not decode exits 2 too.
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

    /// RM-2 (QA M1): parse every override up front. Called as the FIRST line of Server.init — before HomeBase.shared
    /// reads the config, unlinks/recreates the debug log and creates HMHomeManager — so a bad value exits 2
    /// (`prefab: invalid <NAME>`) before any file or HomeKit is touched. RM-3: the debug switches are checked here
    /// too (in release builds they are constants and read no environment).
    static func validateAtLaunch() {
        _ = (port, configPath, logPath, forceUnauthorized, fault)
        // S″ (plan R7-7 / R8-6): an EXISTING config that cannot be decoded exits 2 here, before HomeKit or the debug log
        // is touched, and is never overwritten; a missing one gets the default (polling off), as before.
        do { _ = try PrefabConfig.loadOrCreate(at: URL(fileURLWithPath: configPath)) } catch { invalidConfig(error) }
    }

    /// R8-6: under the LaunchAgent (KeepAlive + `open -W`) Prefab's stderr is never seen and an exit 2 relaunches about
    /// every 10 s, so the reason goes to the unified log first:
    /// `log show --last 5m --style compact --predicate 'process == "Prefab"' | grep -m3 'prefab: invalid'`.
    static func invalidConfig(_ error: Error) -> Never {
        let reason = String(describing: error)
        Logger(subsystem: "app.prefab", category: "launch").fault("prefab: invalid PREFAB_CONFIG_PATH (\(reason, privacy: .public))")
        die("PREFAB_CONFIG_PATH")
    }

    #if DEBUG
    // RM-3 (QA m1): the debug switches fail closed. A set (even empty) PREFAB_FORCE_UNAUTHORIZED other than "1", or a
    // non-empty PREFAB_FAULT outside {write_failed, write_timeout}, exits 2 at launch (validateAtLaunch); an empty
    // PREFAB_FAULT is off. So a mistyped switch can never fall through to an authorized instance or a real HomeKit write.
    static let forceUnauthorized: Bool = {
        guard let raw = ProcessInfo.processInfo.environment["PREFAB_FORCE_UNAUTHORIZED"] else { return false }
        guard raw == "1" else { die("PREFAB_FORCE_UNAUTHORIZED") }
        return true
    }()
    static let fault: String? = {
        guard let raw = ProcessInfo.processInfo.environment["PREFAB_FAULT"], !raw.isEmpty else { return nil }
        guard raw == "write_failed" || raw == "write_timeout" else { die("PREFAB_FAULT") }
        return raw
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
