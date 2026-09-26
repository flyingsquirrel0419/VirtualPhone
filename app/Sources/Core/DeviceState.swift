import Foundation

/// A device's own copy of everything the guest writes, kept in its package.
///
/// With `protectBaseImage` on, the root disk is a qcow2 overlay in `disks/`
/// and the small mutable namespaces and SEP state live in `nvram/`. They are
/// created together from the base files and reset together: the guest's disk
/// and the SEP's replay counters must never come from different points in
/// time, or the guest's SEP panics on the next boot (an Inferno-iOS finding).
public enum DeviceState {
    /// Roles the guest writes, copied per device. The root disk is overlaid instead.
    public static let copiedRoles: [GuestFiles.Role] = [
        .nvram, .sepNVRAM, .sepSSC, .panicLog, .effaceable, .syscfg, .ctrlBits, .firmware,
    ]

    public static func overlayURL(in package: VMPackage) -> URL {
        package.url.appendingPathComponent("disks/root.qcow2")
    }

    static func copyURL(_ role: GuestFiles.Role, in package: VMPackage, files: GuestFiles) -> URL {
        package.url.appendingPathComponent("nvram").appendingPathComponent(files.paths[role]!.lastPathComponent)
    }

    public static func exists(in package: VMPackage) -> Bool {
        FileManager.default.fileExists(atPath: overlayURL(in: package).path)
    }

    /// Creates the overlay and the copies if they are not there yet.
    /// Returns true when it created them (a fresh device state).
    @discardableResult
    public static func prepare(_ package: VMPackage, files: GuestFiles) throws -> Bool {
        guard !exists(in: package) else { return false }
        let fm = FileManager.default
        let disks = package.url.appendingPathComponent("disks")
        let nvram = package.url.appendingPathComponent("nvram")
        try fm.createDirectory(at: disks, withIntermediateDirectories: true)
        try fm.createDirectory(at: nvram, withIntermediateDirectories: true)
        for role in copiedRoles {
            let target = copyURL(role, in: package, files: files)
            try? fm.removeItem(at: target)
            // On APFS this is a clone: instant and without using space until written.
            try fm.copyItem(at: files.paths[role]!, to: target)
        }
        let base = files.paths[.root]!
        guard let size = QCOW2Overlay.virtualSize(of: base) else { throw CocoaError(.fileReadUnknown) }
        // The overlay last, so an interrupted prepare is simply redone.
        try QCOW2Overlay.create(at: overlayURL(in: package), backing: relativePath(from: disks, to: base),
                                backingFormat: files.rootFormat, virtualSize: size)
        return true
    }

    /// Discards everything the guest wrote to this device; the next boot starts
    /// from the base files again.
    public static func reset(_ package: VMPackage) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: overlayURL(in: package))
        let nvram = package.url.appendingPathComponent("nvram")
        for item in (try? fm.contentsOfDirectory(atPath: nvram.path)) ?? [] {
            try fm.removeItem(at: nvram.appendingPathComponent(item))
        }
    }

    /// The files the machine should use for this device.
    public static func resolve(_ files: GuestFiles, for package: VMPackage) -> GuestFiles {
        guard package.configuration.protectBaseImage, exists(in: package) else { return files }
        var paths = files.paths
        paths[.root] = overlayURL(in: package)
        for role in copiedRoles { paths[role] = copyURL(role, in: package, files: files) }
        return GuestFiles(dataDirectory: files.dataDirectory, paths: paths, rootFormat: "qcow2")
    }
}
