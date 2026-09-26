import Foundation

/// One virtual device's settings, stored as `config.json` in its package.
///
/// `schema` is written on every save. Loading an older schema migrates it in
/// memory; loading a newer one is refused rather than guessed at, so an older
/// build never silently drops settings a newer one wrote.
public struct MachineConfiguration: Codable, Equatable, Sendable {
    public static let currentSchema = 1

    public static let coreRange = 1...6          // T8030: 2 performance + 4 efficiency
    public static let memoryRangeMB = 1024...3072
    /// iOS kills an app at about 3 GiB whatever its entitlements, and the app,
    /// the translation cache and the guest all share that.
    public static let recommendedMaxMemoryMB = 2048
    public static let translatorCacheRangeMB = 32...1024

    public var schema: Int
    public var id: UUID
    public var name: String
    public var machine: String
    public var device: String
    public var cpuCores: Int
    public var memoryMB: Int
    public var translatorCacheMB: Int
    public var displayPreset: DisplayPreset
    public var audio: Bool
    public var network: Bool
    /// Kernel command line; nil means the built-in default.
    public var bootArgs: String?

    public init(
        id: UUID = UUID(),
        name: String = "My iPhone 11",
        cpuCores: Int = 4,
        memoryMB: Int = 2048,
        translatorCacheMB: Int = 128,
        displayPreset: DisplayPreset = .iphone11,
        audio: Bool = false,
        network: Bool = true,
        bootArgs: String? = nil
    ) {
        self.schema = Self.currentSchema
        self.id = id
        self.name = name
        self.machine = "t8030"
        self.device = "iPhone11"
        self.cpuCores = cpuCores
        self.memoryMB = memoryMB
        self.translatorCacheMB = translatorCacheMB
        self.displayPreset = displayPreset
        self.audio = audio
        self.network = network
        self.bootArgs = bootArgs
    }

    public static let defaultBootArgs =
        "tlto_us=-1 agm-genuine=1 agm-authentic=1 agm-trusted=1 serial=3 wdt=-1 launchd_unsecure_cache=1 -vm_compressor_wk_sw"

    public var effectiveBootArgs: String { bootArgs ?? Self.defaultBootArgs }

    // MARK: - Validation

    public enum Issue: Equatable, Sendable {
        case error(String)
        case warning(String)

        public var isError: Bool {
            if case .error = self { return true }
            return false
        }
    }

    public func validate() -> [Issue] {
        var issues: [Issue] = []
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.error("name must not be empty"))
        }
        if machine != "t8030" || device != "iPhone11" {
            issues.append(.error("only the iPhone 11 (t8030) machine is supported"))
        }
        if !Self.coreRange.contains(cpuCores) {
            issues.append(.error("cpuCores must be in \(Self.coreRange)"))
        }
        if !Self.memoryRangeMB.contains(memoryMB) {
            issues.append(.error("memoryMB must be in \(Self.memoryRangeMB)"))
        } else if memoryMB > Self.recommendedMaxMemoryMB {
            issues.append(.warning("more than \(Self.recommendedMaxMemoryMB) MB risks iOS killing the app"))
        }
        if !Self.translatorCacheRangeMB.contains(translatorCacheMB) {
            issues.append(.error("translatorCacheMB must be in \(Self.translatorCacheRangeMB)"))
        }
        if memoryMB + translatorCacheMB > Self.memoryRangeMB.upperBound {
            issues.append(.warning("guest memory plus translator cache exceeds 3 GB"))
        }
        if let args = bootArgs, args.contains(where: { $0 == "\n" || $0 == "\0" }) {
            issues.append(.error("bootArgs must be a single line"))
        }
        return issues
    }

    public var isValid: Bool { !validate().contains(where: \.isError) }

    // MARK: - Persistence

    public enum LoadError: Error, Equatable {
        case malformed(String)
        case unsupportedSchema(Int)
    }

    public static func decode(_ data: Data) throws -> MachineConfiguration {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw LoadError.malformed("not JSON")
        }
        guard var dict = object as? [String: Any] else { throw LoadError.malformed("not an object") }
        let schema = dict["schema"] as? Int ?? 0
        if schema > currentSchema { throw LoadError.unsupportedSchema(schema) }
        if schema < currentSchema { dict = migrate(dict, from: schema) }

        let migrated = try JSONSerialization.data(withJSONObject: dict)
        do {
            return try JSONDecoder().decode(MachineConfiguration.self, from: migrated)
        } catch {
            throw LoadError.malformed(String(describing: error))
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var copy = self
        copy.schema = Self.currentSchema
        return try encoder.encode(copy)
    }

    /// Schema 0 is the unversioned draft format: no `schema`, no `id`, and
    /// the translator cache called `tbSizeMB`.
    static func migrate(_ old: [String: Any], from schema: Int) -> [String: Any] {
        var dict = old
        if schema < 1 {
            if dict["translatorCacheMB"] == nil, let tb = dict["tbSizeMB"] { dict["translatorCacheMB"] = tb }
            dict.removeValue(forKey: "tbSizeMB")
            let defaults = MachineConfiguration()
            dict["id"] = dict["id"] ?? UUID().uuidString
            dict["name"] = dict["name"] ?? defaults.name
            dict["machine"] = dict["machine"] ?? defaults.machine
            dict["device"] = dict["device"] ?? defaults.device
            dict["cpuCores"] = dict["cpuCores"] ?? defaults.cpuCores
            dict["memoryMB"] = dict["memoryMB"] ?? defaults.memoryMB
            dict["translatorCacheMB"] = dict["translatorCacheMB"] ?? defaults.translatorCacheMB
            dict["displayPreset"] = dict["displayPreset"] ?? defaults.displayPreset.rawValue
            dict["audio"] = dict["audio"] ?? defaults.audio
            dict["network"] = dict["network"] ?? defaults.network
        }
        dict["schema"] = currentSchema
        return dict
    }
}
