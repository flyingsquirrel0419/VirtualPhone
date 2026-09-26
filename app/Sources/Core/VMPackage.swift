import Foundation

/// A virtual device on disk: a `<name>.vphone` directory.
///
///     MyPhone.vphone/
///     ├── config.json            MachineConfiguration
///     ├── firmware-links.json    FirmwareLinks (references, not copies)
///     ├── disks/                 per-device overlays (v0.8+)
///     ├── nvram/  state/  logs/  snapshots/
///
/// Writes go through a temporary file and an atomic replace, so a crash in
/// the middle of a save leaves the previous config.json intact.
public struct VMPackage: Equatable, Sendable {
    public static let pathExtension = "vphone"
    public static let subdirectories = ["disks", "nvram", "state", "logs", "snapshots"]

    public enum PackageError: Error, Equatable {
        case alreadyExists(String)
        case notAPackage(String)
        case invalidName
    }

    public let url: URL
    public var configuration: MachineConfiguration
    public var links: FirmwareLinks

    var configURL: URL { url.appendingPathComponent("config.json") }
    var linksURL: URL { url.appendingPathComponent("firmware-links.json") }
    public var logsURL: URL { url.appendingPathComponent("logs") }

    /// A file-system-safe directory name for a display name.
    public static func directoryName(for name: String) -> String? {
        let bad = CharacterSet(charactersIn: "/\\:\0").union(.controlCharacters)
        let cleaned = name.components(separatedBy: bad).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != ".", cleaned != "..", !cleaned.hasPrefix(".") else { return nil }
        return String(cleaned.prefix(80)) + "." + pathExtension
    }

    public static func create(in directory: URL, configuration: MachineConfiguration,
                              links: FirmwareLinks = FirmwareLinks()) throws -> VMPackage {
        guard let dirName = directoryName(for: configuration.name) else { throw PackageError.invalidName }
        let url = directory.appendingPathComponent(dirName, isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { throw PackageError.alreadyExists(dirName) }
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        for sub in subdirectories {
            try fm.createDirectory(at: url.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        let package = VMPackage(url: url, configuration: configuration, links: links)
        try package.save()
        return package
    }

    public static func open(_ url: URL) throws -> VMPackage {
        let configURL = url.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL) else { throw PackageError.notAPackage(url.lastPathComponent) }
        let config = try MachineConfiguration.decode(data)
        let linksURL = url.appendingPathComponent("firmware-links.json")
        let links = (try? Data(contentsOf: linksURL)).flatMap { try? JSONDecoder().decode(FirmwareLinks.self, from: $0) }
            ?? FirmwareLinks()
        return VMPackage(url: url, configuration: config, links: links)
    }

    /// Every readable package in `directory`, sorted by name. Unreadable ones
    /// are reported rather than hidden, so a damaged device is not lost silently.
    public static func list(in directory: URL) -> (packages: [VMPackage], broken: [URL]) {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        var packages: [VMPackage] = []
        var broken: [URL] = []
        for entry in entries where entry.pathExtension == pathExtension {
            if let package = try? open(entry) { packages.append(package) } else { broken.append(entry) }
        }
        packages.sort { $0.configuration.name.localizedStandardCompare($1.configuration.name) == .orderedAscending }
        return (packages, broken)
    }

    public func save() throws {
        try Self.atomicWrite(configuration.encoded(), to: configURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try Self.atomicWrite(encoder.encode(links), to: linksURL)
    }

    /// A new device with the same settings and a new identity. Logs and run
    /// state are not carried over; disks and NVRAM are.
    public func clone(named name: String) throws -> VMPackage {
        var config = configuration
        config.id = UUID()
        config.name = name
        let copy = try Self.create(in: url.deletingLastPathComponent(), configuration: config, links: links)
        let fm = FileManager.default
        for sub in ["disks", "nvram"] {
            let from = url.appendingPathComponent(sub)
            let to = copy.url.appendingPathComponent(sub)
            for item in (try? fm.contentsOfDirectory(atPath: from.path)) ?? [] {
                try fm.copyItem(at: from.appendingPathComponent(item), to: to.appendingPathComponent(item))
            }
        }
        return copy
    }

    public func renamed(to name: String) throws -> VMPackage {
        guard let dirName = Self.directoryName(for: name) else { throw PackageError.invalidName }
        var package = self
        package.configuration.name = name
        let target = url.deletingLastPathComponent().appendingPathComponent(dirName, isDirectory: true)
        if target.standardizedFileURL != url.standardizedFileURL {
            if FileManager.default.fileExists(atPath: target.path) { throw PackageError.alreadyExists(dirName) }
            try FileManager.default.moveItem(at: url, to: target)
            package = VMPackage(url: target, configuration: package.configuration, links: links)
        }
        try package.save()
        return package
    }

    // MARK: - Clean shutdown tracking

    var runningMarker: URL { url.appendingPathComponent("state/running") }

    /// Written when the machine starts, removed when it stops cleanly. Still
    /// there at the next launch means the app died with the guest running:
    /// its disks may hold a half-finished write, and the user should know.
    public func markRunning(at date: Date = Date()) {
        try? FileManager.default.createDirectory(at: runningMarker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(ISO8601DateFormatter().string(from: date).utf8).write(to: runningMarker)
    }

    public func markStopped() {
        try? FileManager.default.removeItem(at: runningMarker)
    }

    /// When the previous run started, if it did not end cleanly.
    public var uncleanShutdown: Date? {
        guard let data = try? Data(contentsOf: runningMarker) else { return nil }
        return ISO8601DateFormatter().date(from: String(decoding: data, as: UTF8.self)) ?? Date.distantPast
    }

    public func delete() throws {
        try FileManager.default.removeItem(at: url)
    }

    /// rename(2) replaces the target atomically on the same volume, on
    /// Darwin and Linux alike (Foundation's replaceItemAt is not portable).
    static func atomicWrite(_ data: Data, to url: URL) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp")
        try data.write(to: temp)
        if rename(temp.path, url.path) != 0 {
            let code = errno
            try? FileManager.default.removeItem(at: temp)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path,
                                                           NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)])
        }
    }
}
