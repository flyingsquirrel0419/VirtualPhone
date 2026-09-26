import Foundation

/// Reads a ZIP archive's directory and individual entries without loading the
/// whole file: an .ipa can be hundreds of megabytes on a phone with little RAM.
public final class ZipArchive {
    public enum Failure: Error, Equatable {
        case unreadable
        case notAZip
        case zip64Unsupported
        case corrupt(String)
        case unsupportedMethod(UInt16)
        case checksumMismatch(String)
    }

    public struct Entry: Equatable {
        public let path: String
        public let method: UInt16
        public let crc32: UInt32
        public let compressedSize: Int
        public let uncompressedSize: Int
        let localHeaderOffset: Int
        public var isDirectory: Bool { path.hasSuffix("/") }
    }

    public let entries: [Entry]
    private let handle: FileHandle
    private let size: UInt64

    public init(url: URL) throws {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw Failure.unreadable }
        self.handle = handle
        size = (try? handle.seekToEnd()) ?? 0
        guard size >= 22 else { throw Failure.notAZip }

        // End of central directory: the last 22 bytes plus up to 64 KiB of comment.
        let tailLength = min(size, 22 + 65535)
        let tail = try Self.read(handle, at: size - tailLength, count: Int(tailLength))
        guard let eocd = (0...(tail.count - 22)).reversed().first(where: { tail.u32($0) == 0x0605_4B50 }) else {
            throw Failure.notAZip
        }
        let count = Int(tail.u16(eocd + 10))
        let dirSize = Int(tail.u32(eocd + 12))
        let dirOffset = Int(tail.u32(eocd + 16))
        if count == 0xFFFF || dirOffset == 0xFFFF_FFFF { throw Failure.zip64Unsupported }
        guard UInt64(dirOffset + dirSize) <= size else { throw Failure.corrupt("central directory out of range") }

        let dir = try Self.read(handle, at: UInt64(dirOffset), count: dirSize)
        var entries: [Entry] = []
        var p = 0
        for _ in 0..<count {
            guard p + 46 <= dir.count, dir.u32(p) == 0x0201_4B50 else { throw Failure.corrupt("bad central directory entry") }
            let nameLength = Int(dir.u16(p + 28)), extra = Int(dir.u16(p + 30)), comment = Int(dir.u16(p + 32))
            guard p + 46 + nameLength <= dir.count else { throw Failure.corrupt("truncated name") }
            let name = String(decoding: dir[(p + 46)..<(p + 46 + nameLength)], as: UTF8.self)
            entries.append(Entry(path: name, method: dir.u16(p + 10), crc32: dir.u32(p + 16),
                                 compressedSize: Int(dir.u32(p + 20)), uncompressedSize: Int(dir.u32(p + 24)),
                                 localHeaderOffset: Int(dir.u32(p + 42))))
            p += 46 + nameLength + extra + comment
        }
        self.entries = entries
    }

    deinit { try? handle.close() }

    public func entry(_ path: String) -> Entry? { entries.first { $0.path == path } }

    /// The entry's contents; with `prefix`, only that many leading bytes (no CRC check).
    public func extract(_ entry: Entry, prefix: Int? = nil, limit: Int = 64 << 20) throws -> [UInt8] {
        guard entry.uncompressedSize <= limit || prefix != nil else { throw Inflate.Failure.outputLimit }
        let local = try Self.read(handle, at: UInt64(entry.localHeaderOffset), count: 30)
        guard local.u32(0) == 0x0403_4B50 else { throw Failure.corrupt("bad local header for \(entry.path)") }
        let start = entry.localHeaderOffset + 30 + Int(local.u16(26)) + Int(local.u16(28))
        guard UInt64(start + entry.compressedSize) <= size else { throw Failure.corrupt("\(entry.path) out of range") }

        let bytes: [UInt8]
        switch entry.method {
        case 0:
            let n = prefix.map { min($0, entry.compressedSize) } ?? entry.compressedSize
            bytes = try Self.read(handle, at: UInt64(start), count: n)
        case 8:
            let compressed = try Self.read(handle, at: UInt64(start), count: entry.compressedSize)
            bytes = try Inflate.decompress(compressed, limit: max(limit, prefix ?? 0), stopAfter: prefix)
        default:
            throw Failure.unsupportedMethod(entry.method)
        }
        if prefix == nil {
            guard bytes.count == entry.uncompressedSize, CRC32.checksum(bytes) == entry.crc32 else {
                throw Failure.checksumMismatch(entry.path)
            }
        }
        return bytes
    }

    static func read(_ handle: FileHandle, at offset: UInt64, count: Int) throws -> [UInt8] {
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: count) ?? Data()
        guard data.count == count else { throw Failure.corrupt("short read") }
        return [UInt8](data)
    }
}

public enum CRC32 {
    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}

extension Array where Element == UInt8 {
    func u16(_ i: Int) -> UInt16 { UInt16(self[i]) | UInt16(self[i + 1]) << 8 }
    func u32(_ i: Int) -> UInt32 { UInt32(u16(i)) | UInt32(u16(i + 2)) << 16 }
    func u32be(_ i: Int) -> UInt32 { UInt32(self[i]) << 24 | UInt32(self[i + 1]) << 16 | UInt32(self[i + 2]) << 8 | UInt32(self[i + 3]) }
}
