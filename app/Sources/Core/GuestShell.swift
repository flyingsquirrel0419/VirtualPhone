import Foundation

/// Talking to the jailbreak bootstrap's bash in the guest: quoting, the
/// checksum both sides can compute, and command framing on a console the
/// kernel also prints to.
public enum GuestShell {
    /// A bash word for any string: single quotes for printable ASCII, `$'…'`
    /// with octal escapes for anything else (a path with a newline or a
    /// non-ASCII name survives the console that way).
    public static func quote(_ s: String) -> String {
        let bytes = Array(s.utf8)
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
            return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        var out = "$'"
        for b in bytes {
            if b >= 0x20, b < 0x7F, b != UInt8(ascii: "'"), b != UInt8(ascii: "\\") {
                out.append(Character(Unicode.Scalar(b)))
            } else {
                out += String(format: "\\%03o", b)
            }
        }
        return out + "'"
    }
}

/// What POSIX `cksum` prints: CRC-32/CKSUM with the length folded in. The
/// guest bootstrap has neither md5 nor shasum, but it has cksum.
public struct PosixCksum: Sendable {
    static let table: [UInt32] = (0..<256).map { i in
        var c = UInt32(i) << 24
        for _ in 0..<8 { c = (c & 0x8000_0000) != 0 ? (c << 1) ^ 0x04C1_1DB7 : c << 1 }
        return c
    }

    private var crc: UInt32 = 0
    public private(set) var length: Int64 = 0

    public init() {}

    public mutating func update<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
        var v = crc
        var n: Int64 = 0
        for b in bytes {
            v = (v << 8) ^ Self.table[Int(((v >> 24) ^ UInt32(b)) & 0xFF)]
            n += 1
        }
        crc = v
        length += n
    }

    public var value: UInt32 {
        var v = crc
        var remaining = length
        while remaining > 0 {
            v = (v << 8) ^ Self.table[Int(((v >> 24) ^ UInt32(remaining & 0xFF)) & 0xFF)]
            remaining >>= 8
        }
        return ~v
    }

    /// Parses `cksum`'s output line: "<crc> <length> [name]".
    public static func parse(_ line: String) -> (crc: UInt32, length: Int64)? {
        let f = line.split(separator: " ", omittingEmptySubsequences: true)
        guard f.count >= 2, let c = UInt32(f[0]), let n = Int64(f[1]) else { return nil }
        return (c, n)
    }
}

/// Wraps a command so its output can be found on a shared console.
///
/// The console echoes what is typed, so the markers are written split
/// (`"@@VP""S…"`): the echoed command line never contains the joined marker,
/// only the output does. Everything outside the markers is ignored.
public struct ShellFrame: Sendable {
    public let id: String

    public init(id: String = String(UUID().uuidString.prefix(8)).lowercased()) { self.id = id }

    public var startMarker: String { "@@VPS:\(id)@@" }
    public var endMarkerPrefix: String { "@@VPE:\(id):" }

    /// One line to type. The status is the command's own, not a pipe's tail.
    public func wrap(_ command: String) -> String {
        "echo \"@@VP\"\"S:\(id)@@\"; \(command); echo \"@@VP\"\"E:\(id):$?@@\""
    }

    public struct Result: Equatable, Sendable {
        public let output: [String]
        public let status: Int32
    }

    /// Feed console lines as they come; returns the result once the end marker arrives.
    public struct Parser {
        let frame: ShellFrame
        public private(set) var started = false
        public private(set) var output: [String] = []
        /// Lines inside the window that look like kernel chatter are dropped.
        public var dropKernelLines = true

        public init(frame: ShellFrame) { self.frame = frame }

        public mutating func feed(_ line: String) -> Result? {
            if !started {
                if line.contains(frame.startMarker) { started = true }
                return nil
            }
            if let r = line.range(of: frame.endMarkerPrefix) {
                let rest = line[r.upperBound...]
                let digits = rest.prefix { $0.isNumber || $0 == "-" }
                // Output without a trailing newline shares the end marker's line.
                let before = String(line[..<r.lowerBound])
                if !before.isEmpty { output.append(before) }
                return Result(output: output, status: Int32(digits) ?? -1)
            }
            if dropKernelLines, Self.looksLikeKernel(line) { return nil }
            output.append(line)
            return nil
        }

        /// Kernel log lines on these guests start with a bracketed timestamp or
        /// a kext name followed by a colon — a guess, as upstream notes.
        static func looksLikeKernel(_ line: String) -> Bool {
            if line.hasPrefix("[") && line.contains("]") && line.first(where: \.isNumber) != nil
                && line.firstIndex(of: "]").map({ line.distance(from: line.startIndex, to: $0) < 24 }) == true {
                return true
            }
            let head = line.prefix(40)
            return head.hasPrefix("Apple") && head.contains("::")
        }
    }
}

/// The guest commands VirtualPhone uses, in one place.
public enum GuestCommand {
    /// slirp's address for the host side, as the guest sees it.
    public static let hostAddress = "10.0.2.2"

    /// What the stock Inferno guide tells you to type when the guest has no address.
    public static let reconnectNetwork = "ipconfig set en0 DHCP"

    /// Guest fetches `port` from the app into `path` and reports its cksum.
    public static func receiveFile(port: UInt16, to path: String) -> String {
        "cat < /dev/tcp/\(hostAddress)/\(port) > \(GuestShell.quote(path)) && cksum < \(GuestShell.quote(path))"
    }

    /// Guest sends `path` to the app listening on `port`, then its cksum.
    public static func sendFile(_ path: String, port: UInt16) -> String {
        "cat \(GuestShell.quote(path)) > /dev/tcp/\(hostAddress)/\(port) && cksum < \(GuestShell.quote(path))"
    }

    /// The guest's zone is one symlink on the data volume (no remount needed).
    /// Prints where the link points, or NOZONE when the guest lacks the zone.
    public static func setTimeZone(_ identifier: String) -> String? {
        // Zone names are ASCII paths like "Asia/Seoul"; anything else is refused.
        guard !identifier.isEmpty, identifier.allSatisfy({ $0.isLetter || $0.isNumber || "/_-+".contains($0) }),
              !identifier.contains("..") else { return nil }
        let target = "/var/db/timezone/zoneinfo/\(identifier)"
        let link = "/var/db/timezone/localtime"
        return "if [ -e \(GuestShell.quote(target)) ]; then ln -sfn \(GuestShell.quote(target)) \(link) && readlink \(link); else echo NOZONE; fi"
    }

    /// Succeeds when the guest can reach slirp's host side.
    public static let networkCheck = "ping -c 1 -t 3 \(hostAddress) > /dev/null 2>&1"

    public static func freeKilobytes(at path: String) -> String {
        "df -k \(GuestShell.quote(path)) | tail -1"
    }

    /// Installing an unpacked app from a tar: short commands, none ending in a
    /// pipe, so each status is the step's own (upstream's lesson).
    public struct Step: Equatable, Sendable {
        public let label: String
        public let command: String
        public let critical: Bool
    }

    public static func installSteps(tar: String, appName: String) -> [Step] {
        let target = "/Applications/" + appName
        return [
            Step(label: "Remounting the system volume read-write", command: "mount -uw /", critical: true),
            Step(label: "Removing a previous copy", command: "rm -rf \(GuestShell.quote(target))", critical: false),
            Step(label: "Unpacking", command: "tar xf \(GuestShell.quote(tar)) -C /Applications", critical: true),
            Step(label: "Setting ownership and permissions",
                 command: "chown -R root:wheel \(GuestShell.quote(target)) && chmod -R 755 \(GuestShell.quote(target))", critical: true),
            // uicache complains when the guest is older than MinimumOSVersion; the files are in place anyway.
            Step(label: "Registering with SpringBoard", command: "/usr/bin/uicache -p \(GuestShell.quote(target))", critical: false),
            Step(label: "Cleaning up", command: "rm -f \(GuestShell.quote(tar))", critical: false),
            Step(label: "Checking", command: "test -d \(GuestShell.quote(target))", critical: true),
        ]
    }

    /// Recognisable failures in a step's output.
    public static func diagnose(_ output: [String]) -> String? {
        let text = output.joined(separator: "\n")
        if text.contains("No space left on device") { return "The guest's disk is full." }
        if text.contains("Read-only file system") { return "The guest's system volume is read-only." }
        if text.contains("Connection refused") || text.contains("Network is unreachable") || text.contains("No route to host") {
            return "The guest could not reach the app over its network."
        }
        if text.contains("/dev/tcp"), text.contains("No such file") { return "The guest's bash has no /dev/tcp support." }
        if text.contains("command not found") { return "A command is missing in the guest (is the jailbreak bootstrap installed?)." }
        return nil
    }
}
