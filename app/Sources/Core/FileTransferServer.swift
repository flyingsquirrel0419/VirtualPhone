import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A one-connection TCP server on the loopback, for files moving to and from
/// the guest. Slirp runs in this process and maps the guest's 10.0.2.2 to our
/// 127.0.0.1, so the guest's `cat < /dev/tcp/10.0.2.2/PORT` lands here.
///
/// It serves exactly one peer, computes the same cksum the guest will, and
/// gives up after `timeout` so an unanswered request does not linger.
public final class FileTransferServer {
    public enum Failure: Error, Equatable {
        case socket(Int32)
        case timeout
        case io(Int32)
    }

    public let port: UInt16
    private let fd: Int32
    private let stateLock = NSLock()
    private var cancelled = false

    /// Listens on 127.0.0.1; `port` 0 picks a free one.
    public init(port: UInt16 = 0) throws {
        #if canImport(Glibc)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw Failure.socket(errno) }
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) } }
        guard bound == 0, listen(fd, 1) == 0 else {
            let code = errno
            _ = SystemCall.close(fd)
            throw Failure.socket(code)
        }
        var actual = sockaddr_in()
        var len = size
        _ = withUnsafeMutablePointer(to: &actual) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        self.fd = fd
        self.port = UInt16(bigEndian: actual.sin_port)
    }

    deinit { _ = SystemCall.close(fd) }

    /// Stops waiting for a peer: a pending accept returns `.timeout` within
    /// 0.2 s. Safe from any thread; the socket itself is closed on deinit, never
    /// under a poll running on another thread.
    public func close() {
        stateLock.lock()
        cancelled = true
        stateLock.unlock()
    }

    private var isCancelled: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cancelled
    }

    private func acceptOne(timeout: TimeInterval) throws -> Int32 {
        let deadline = Date() + timeout
        while true {
            if isCancelled || Date() >= deadline { throw Failure.timeout }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&p, 1, 200) > 0 { break }
        }
        let conn = accept(fd, nil, nil)
        guard conn >= 0 else { throw Failure.io(errno) }
        TCPConnection.setTimeouts(conn, 120)
        return conn
    }

    /// Sends the file at `url` to the first peer, then closes (EOF ends the guest's cat).
    public func send(_ url: URL, timeout: TimeInterval = 60, progress: ((Int64) -> Void)? = nil) throws -> (crc: UInt32, length: Int64) {
        let conn = try acceptOne(timeout: timeout)
        defer { _ = SystemCall.close(conn) }
        guard let file = try? FileHandle(forReadingFrom: url) else { throw Failure.io(ENOENT) }
        defer { try? file.close() }
        var sum = PosixCksum()
        // A read error propagates: treating it as EOF would send a short file
        // whose checksum both ends would then agree on.
        while let chunk = try file.read(upToCount: 256 * 1024), !chunk.isEmpty {
            let bytes = [UInt8](chunk)
            var sent = 0
            while sent < bytes.count {
                let n = bytes[sent...].withUnsafeBytes { SystemCall.send(conn, $0.baseAddress, $0.count) }
                if n < 0 { if errno == EINTR { continue }; throw Failure.io(errno) }
                sent += n
            }
            sum.update(bytes)
            progress?(sum.length)
        }
        return (sum.value, sum.length)
    }

    /// Receives everything the first peer sends into `url`.
    public func receive(to url: URL, timeout: TimeInterval = 60, progress: ((Int64) -> Void)? = nil) throws -> (crc: UInt32, length: Int64) {
        let conn = try acceptOne(timeout: timeout)
        defer { _ = SystemCall.close(conn) }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let file = try? FileHandle(forWritingTo: url) else { throw Failure.io(EACCES) }
        defer { try? file.close() }
        var sum = PosixCksum()
        var buf = [UInt8](repeating: 0, count: 256 * 1024)
        while true {
            let n = buf.withUnsafeMutableBytes { SystemCall.recv(conn, $0.baseAddress, $0.count) }
            if n == 0 { break }
            if n < 0 { if errno == EINTR { continue }; throw Failure.io(errno) }
            let chunk = Array(buf[0..<n])
            // The throwing write: the old one raises an uncatchable exception on a full disk.
            try file.write(contentsOf: Data(chunk))
            sum.update(chunk)
            progress?(sum.length)
        }
        return (sum.value, sum.length)
    }
}
