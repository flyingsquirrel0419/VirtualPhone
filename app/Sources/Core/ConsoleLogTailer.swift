import Foundation

/// Follows the emulator's console log file (`-chardev …,logfile=…,logappend=on`).
///
/// The log is the reliable source: the socket only carries what is printed
/// after a client attaches, while the guest talks from its first instruction.
/// The tailer remembers how far it has read; if the file shrinks (the app
/// empties it before a start) it starts again from the top.
public final class ConsoleLogTailer {
    public let url: URL
    public private(set) var offset: UInt64 = 0
    public private(set) var buffer: ConsoleBuffer
    public private(set) var detector = BootPhaseDetector()
    /// Reads at most this much per poll, so a burst does not stall the caller.
    public var maxReadBytes = 1 << 20

    public init(url: URL, capacity: Int = 4000) {
        self.url = url
        self.buffer = ConsoleBuffer(capacity: capacity)
    }

    /// Empties the file and the state: a new boot starts here.
    public func reset(at date: Date = Date()) {
        FileManager.default.createFile(atPath: url.path, contents: Data())
        offset = 0
        buffer.clear()
        detector.start(at: date)
    }

    public struct Update {
        public let lines: [String]
        public let transitions: [BootPhaseDetector.Transition]
    }

    /// Reads whatever was appended since the last call.
    @discardableResult
    public func poll(at date: Date = Date()) -> Update {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Update(lines: [], transitions: []) }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset { // truncated behind our back
            offset = 0
            buffer.clear()
        }
        guard size > offset else { return Update(lines: [], transitions: []) }
        try? handle.seek(toOffset: offset)
        let data = (try? handle.read(upToCount: min(Int(size - offset), maxReadBytes))) ?? Data()
        offset += UInt64(data.count)
        let lines = buffer.feed([UInt8](data))
        let transitions = lines.compactMap { detector.observe($0, at: date) }
        return Update(lines: lines, transitions: transitions)
    }
}

extension GuestFiles {
    /// One row per required file, for the readiness screen.
    public struct Entry: Equatable, Sendable {
        public let role: Role
        public let path: String
        public let size: Int64?
        public let usable: Bool
    }

    public static func report(_ links: FirmwareLinks, documents: URL) -> [Entry] {
        let resolved = resolve(links, documents: documents)
        let missing = Set(resolved.missing)
        return Role.allCases.map { role in
            let path = resolved.files.path(role)
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)??.int64Value
            return Entry(role: role, path: path, size: size, usable: !missing.contains(role))
        }
    }
}
