import Foundation

/// Creates an empty qcow2 (version 3) overlay on top of a backing image.
///
/// The guest then writes only to the overlay; QEMU opens the backing file
/// read-only, so the user's prepared image is never modified, and a device
/// can be reset or cloned by copying a small file. The layout is the minimal
/// one `qemu-img create -b` produces: header with the backing-format
/// extension, one refcount table cluster, one refcount block, an L1 table,
/// and no data.
public enum QCOW2Overlay {
    public enum Failure: Error, Equatable {
        case backingNameTooLong
        case tooLarge
        case exists(String)
    }

    static let clusterBits = 16
    static var clusterSize: Int { 1 << clusterBits }

    /// `backing` is written as given; a relative path is resolved by QEMU
    /// against the overlay's directory, which keeps working when iOS moves
    /// the app's container.
    public static func create(at url: URL, backing: String, backingFormat: String, virtualSize: UInt64) throws {
        if FileManager.default.fileExists(atPath: url.path) { throw Failure.exists(url.lastPathComponent) }
        let data = try image(backing: backing, backingFormat: backingFormat, virtualSize: virtualSize)
        try Data(data).write(to: url, options: .withoutOverwriting)
    }

    static func image(backing: String, backingFormat: String, virtualSize: UInt64) throws -> [UInt8] {
        let cs = clusterSize
        let entriesPerL2 = UInt64(cs / 8)
        let l1Size = Int((virtualSize + UInt64(cs) * entriesPerL2 - 1) / (UInt64(cs) * entriesPerL2))
        let l1Clusters = max(1, (l1Size * 8 + cs - 1) / cs)
        // Clusters: 0 header, 1 refcount table, 2 refcount block, 3… L1.
        let totalClusters = 3 + l1Clusters
        guard totalClusters <= cs / 2 else { throw Failure.tooLarge } // one 16-bit refcount block

        var out = [UInt8](repeating: 0, count: totalClusters * cs)
        func be32(_ v: UInt32, _ at: Int) { for i in 0..<4 { out[at + i] = UInt8(truncatingIfNeeded: v >> (24 - 8 * UInt32(i))) } }
        func be64(_ v: UInt64, _ at: Int) { be32(UInt32(v >> 32), at); be32(UInt32(truncatingIfNeeded: v), at + 4) }
        func be16(_ v: UInt16, _ at: Int) { out[at] = UInt8(v >> 8); out[at + 1] = UInt8(truncatingIfNeeded: v) }

        let headerLength = 104
        // Header extension: backing file format (0xE2792ACA), then end (0).
        let fmt = Array(backingFormat.utf8)
        let fmtPadded = (fmt.count + 7) / 8 * 8
        let extEnd = headerLength + 8 + fmtPadded + 8
        let name = Array(backing.utf8)
        guard name.count <= 1023, extEnd + name.count <= cs else { throw Failure.backingNameTooLong }

        be32(0x5146_49FB, 0)                  // "QFI\xfb"
        be32(3, 4)                            // version
        be64(UInt64(extEnd), 8)               // backing_file_offset
        be32(UInt32(name.count), 16)          // backing_file_size
        be32(UInt32(clusterBits), 20)
        be64(virtualSize, 24)
        be32(0, 32)                           // crypt_method
        be32(UInt32(l1Size), 36)
        be64(UInt64(3 * cs), 40)              // l1_table_offset
        be64(UInt64(1 * cs), 48)              // refcount_table_offset
        be32(1, 56)                           // refcount_table_clusters
        be32(0, 60)                           // nb_snapshots
        be64(0, 64)                           // snapshots_offset
        be64(0, 72)                           // incompatible_features
        be64(0, 80)                           // compatible_features
        be64(0, 88)                           // autoclear_features
        be32(4, 96)                           // refcount_order: 16-bit refcounts
        be32(UInt32(headerLength), 100)

        be32(0xE279_2ACA, headerLength)
        be32(UInt32(fmt.count), headerLength + 4)
        out.replaceSubrange((headerLength + 8)..<(headerLength + 8 + fmt.count), with: fmt)
        // End-of-extensions marker is already zero.
        out.replaceSubrange(extEnd..<(extEnd + name.count), with: name)

        be64(UInt64(2 * cs), cs)              // refcount_table[0] → refcount block
        for c in 0..<totalClusters { be16(1, 2 * cs + 2 * c) }
        return out
    }

    /// Reads the virtual size and backing file name of a qcow2 image.
    public static func inspect(_ url: URL) -> (virtualSize: UInt64, backing: String?)? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 1024), head.count >= 72 else { return nil }
        let b = [UInt8](head)
        func u32(_ i: Int) -> UInt32 { b[i..<(i + 4)].reduce(0) { $0 << 8 | UInt32($1) } }
        func u64(_ i: Int) -> UInt64 { UInt64(u32(i)) << 32 | UInt64(u32(i + 4)) }
        guard u32(0) == 0x5146_49FB else { return nil }
        let offset = Int(u64(8)), length = Int(u32(16))
        var backing: String?
        if offset > 0, length > 0 {
            try? h.seek(toOffset: UInt64(offset))
            backing = (try? h.read(upToCount: length)).map { String(decoding: $0, as: UTF8.self) }
        }
        return (u64(24), backing)
    }

    /// The size a guest sees for a base image: qcow2's virtual size, or a raw file's length.
    public static func virtualSize(of url: URL) -> UInt64? {
        if let q = inspect(url) { return q.virtualSize }
        return (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)??.uint64Value
    }
}

/// Relative path from `directory` to `target` (both absolute, standardized).
public func relativePath(from directory: URL, to target: URL) -> String {
    let from = directory.standardizedFileURL.pathComponents
    let to = target.standardizedFileURL.pathComponents
    var common = 0
    while common < min(from.count, to.count), from[common] == to[common] { common += 1 }
    let ups = Array(repeating: "..", count: from.count - common)
    return (ups + to[common...]).joined(separator: "/")
}
