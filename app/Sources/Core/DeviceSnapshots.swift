import Foundation

/// Point-in-time copies of a protected device: its overlay and its state
/// copies together, so a restore never pairs a disk with SEP counters from
/// another moment. Taken and restored only while the machine is stopped.
///
///     snapshots/<id>/meta.json, root.qcow2, nvram/…
public enum DeviceSnapshots {
    public struct Snapshot: Codable, Equatable, Sendable {
        public let id: String
        public var name: String
        public let created: Date
        public let bytes: Int64
    }

    public enum Failure: Error, Equatable {
        case noDeviceState
        case notFound(String)
    }

    static func root(_ package: VMPackage) -> URL { package.url.appendingPathComponent("snapshots") }

    public static func list(_ package: VMPackage) -> [Snapshot] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root(package), includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return dirs.compactMap { dir in
            (try? Data(contentsOf: dir.appendingPathComponent("meta.json"))).flatMap { try? decoder.decode(Snapshot.self, from: $0) }
        }.sorted { $0.created < $1.created }
    }

    @discardableResult
    public static func take(_ package: VMPackage, name: String, at date: Date = Date()) throws -> Snapshot {
        guard DeviceState.exists(in: package) else { throw Failure.noDeviceState }
        let fm = FileManager.default
        let id = String(Int(date.timeIntervalSince1970 * 1000)) + "-" + String(UUID().uuidString.prefix(4)).lowercased()
        let dir = root(package).appendingPathComponent(id)
        let staging = root(package).appendingPathComponent(".\(id).partial")
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try fm.copyItem(at: DeviceState.overlayURL(in: package), to: staging.appendingPathComponent("root.qcow2"))
        try fm.copyItem(at: package.url.appendingPathComponent("nvram"), to: staging.appendingPathComponent("nvram"))
        let snap = Snapshot(id: id, name: name, created: date, bytes: directorySize(staging))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snap).write(to: staging.appendingPathComponent("meta.json"))
        // Visible only once complete: a crash mid-copy leaves a .partial, never a broken snapshot.
        try fm.moveItem(at: staging, to: dir)
        return snap
    }

    /// Puts the device back to `id`. The current state is replaced.
    public static func restore(_ package: VMPackage, id: String) throws {
        let fm = FileManager.default
        let dir = root(package).appendingPathComponent(id)
        guard fm.fileExists(atPath: dir.appendingPathComponent("meta.json").path) else { throw Failure.notFound(id) }
        let disks = package.url.appendingPathComponent("disks")
        let nvram = package.url.appendingPathComponent("nvram")
        try fm.createDirectory(at: disks, withIntermediateDirectories: true)
        // Copy beside the targets first, then swap, so a failed copy changes nothing.
        let newRoot = disks.appendingPathComponent(".root.qcow2.restore")
        let newNVRAM = package.url.appendingPathComponent(".nvram.restore")
        try? fm.removeItem(at: newRoot)
        try? fm.removeItem(at: newNVRAM)
        try fm.copyItem(at: dir.appendingPathComponent("root.qcow2"), to: newRoot)
        try fm.copyItem(at: dir.appendingPathComponent("nvram"), to: newNVRAM)
        // Move the current state aside, swap the copies in, and only then drop
        // the old one; a failed move puts the old state back.
        let overlay = DeviceState.overlayURL(in: package)
        let oldRoot = disks.appendingPathComponent(".root.qcow2.old")
        let oldNVRAM = package.url.appendingPathComponent(".nvram.old")
        try? fm.removeItem(at: oldRoot)
        try? fm.removeItem(at: oldNVRAM)
        if fm.fileExists(atPath: overlay.path) { try fm.moveItem(at: overlay, to: oldRoot) }
        if fm.fileExists(atPath: nvram.path) { try fm.moveItem(at: nvram, to: oldNVRAM) }
        do {
            try fm.moveItem(at: newNVRAM, to: nvram)
            try fm.moveItem(at: newRoot, to: overlay) // last: DeviceState.exists() keys on it
        } catch {
            try? fm.removeItem(at: nvram)
            try? fm.moveItem(at: oldNVRAM, to: nvram)
            try? fm.moveItem(at: oldRoot, to: overlay)
            throw error
        }
        try? fm.removeItem(at: oldRoot)
        try? fm.removeItem(at: oldNVRAM)
    }

    public static func delete(_ package: VMPackage, id: String) throws {
        try FileManager.default.removeItem(at: root(package).appendingPathComponent(id))
    }

    static func directorySize(_ url: URL) -> Int64 {
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let f = e?.nextObject() as? URL {
            total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
