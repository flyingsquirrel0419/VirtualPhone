import Foundation

/// Writes a POSIX ustar archive, streaming to a file. Enough for an app
/// bundle: regular files and directories, paths up to 255 bytes (prefix +
/// name split), modes; symlinks are stored as links.
public final class TarWriter {
    public enum Failure: Error, Equatable {
        case pathTooLong(String)
        case io(String)
    }

    private let handle: FileHandle
    public private(set) var bytesWritten: Int64 = 0
    public private(set) var checksum = PosixCksum()

    public init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: url) else { throw Failure.io("cannot open \(url.path)") }
        handle = h
    }

    deinit { try? handle.close() }

    public func addDirectory(_ path: String, mode: Int = 0o755) throws {
        try header(path.hasSuffix("/") ? path : path + "/", size: 0, mode: mode, type: "5", link: "")
    }

    public func addFile(_ path: String, contents: [UInt8], mode: Int = 0o644) throws {
        try header(path, size: contents.count, mode: mode, type: "0", link: "")
        try emit(contents)
        try pad(contents.count)
    }

    public func addSymlink(_ path: String, target: String) throws {
        try header(path, size: 0, mode: 0o777, type: "2", link: target)
    }

    /// Two zero blocks end the archive.
    public func finish() throws {
        try emit([UInt8](repeating: 0, count: 1024))
        try handle.synchronize()
    }

    private func emit(_ bytes: [UInt8]) throws {
        handle.write(Data(bytes))
        bytesWritten += Int64(bytes.count)
        checksum.update(bytes)
    }

    private func pad(_ size: Int) throws {
        let rest = size % 512
        if rest != 0 { try emit([UInt8](repeating: 0, count: 512 - rest)) }
    }

    static func split(_ path: String) -> (prefix: String, name: String)? {
        let bytes = Array(path.utf8)
        if bytes.count <= 100 { return ("", path) }
        guard bytes.count <= 255 else { return nil }
        // Split at a slash so that name <= 100 and prefix <= 155.
        for i in stride(from: min(bytes.count - 1, 155), through: 1, by: -1) where bytes[i] == UInt8(ascii: "/") {
            let prefix = bytes[..<i], name = bytes[(i + 1)...]
            if name.count <= 100, !name.isEmpty {
                return (String(decoding: prefix, as: UTF8.self), String(decoding: name, as: UTF8.self))
            }
        }
        return nil
    }

    private func header(_ path: String, size: Int, mode: Int, type: Character, link: String) throws {
        guard let (prefix, name) = Self.split(path), link.utf8.count <= 100 else { throw Failure.pathTooLong(path) }
        var h = [UInt8](repeating: 0, count: 512)
        func put(_ s: String, _ offset: Int, _ length: Int) {
            for (i, b) in s.utf8.prefix(length).enumerated() { h[offset + i] = b }
        }
        func octal(_ v: Int, _ offset: Int, _ length: Int) {
            put(String(repeating: "0", count: max(0, length - 1 - String(v, radix: 8).count)) + String(v, radix: 8), offset, length - 1)
        }
        put(name, 0, 100)
        octal(mode, 100, 8)
        octal(0, 108, 8)       // uid (root)
        octal(0, 116, 8)       // gid (wheel)
        octal(size, 124, 12)
        octal(0, 136, 12)      // mtime: fixed, so the same app makes the same tar
        put("        ", 148, 8)
        h[156] = type.asciiValue ?? UInt8(ascii: "0")
        put(link, 157, 100)
        put("ustar", 257, 6)
        put("00", 263, 2)
        put("root", 265, 32)
        put("wheel", 297, 32)
        put(prefix, 345, 155)
        let sum = h.reduce(0) { $0 + Int($1) }
        put(String(format: "%06o", sum), 148, 6)
        h[154] = 0
        h[155] = UInt8(ascii: " ")
        try emit(h)
    }
}

extension IPAInspector {
    /// Unpacks `report.appDirectory` from the IPA into a tar rooted at the
    /// `.app` folder, ready for `tar xf … -C /Applications`. Returns its cksum.
    public static func makeGuestTar(from ipa: URL, report: IPAReport, to tar: URL) throws -> (crc: UInt32, length: Int64) {
        let zip = try ZipArchive(url: ipa)
        let writer = try TarWriter(url: tar)
        let root = report.appDirectory + "/"
        let appName = String(report.appDirectory.dropFirst("Payload/".count))
        try writer.addDirectory(appName)
        for entry in zip.entries where entry.path.hasPrefix(root) && entry.path != root {
            let relative = appName + "/" + entry.path.dropFirst(root.count)
            if entry.isDirectory {
                try writer.addDirectory(String(relative))
            } else {
                let bytes = try zip.extract(entry, limit: 2 << 30)
                // Executables keep an executable mode; everything is 755 after install anyway.
                try writer.addFile(String(relative), contents: bytes, mode: 0o755)
            }
        }
        try writer.finish()
        return (writer.checksum.value, writer.checksum.length)
    }
}
