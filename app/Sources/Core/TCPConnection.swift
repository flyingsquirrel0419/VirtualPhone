import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A blocking TCP client for loopback control channels (QMP, the serial
/// console). POSIX sockets, so the same code runs in the app and in Linux
/// tests; every read has a deadline, so a silent peer never hangs a caller.
public final class TCPConnection {
    public enum Failure: Error, Equatable {
        case connect(Int32)
        case timeout
        case closed
        case io(Int32)
    }

    private var fd: Int32
    private var buffer = [UInt8]()

    private init(fd: Int32) { self.fd = fd }

    deinit { close() }

    public static func connect(host: String = "127.0.0.1", port: UInt16, timeout: TimeInterval = 2) throws -> TCPConnection {
        #if canImport(Glibc)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw Failure.connect(errno) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
            _ = SystemCall.close(fd)
            throw Failure.connect(EINVAL)
        }
        setTimeouts(fd, timeout)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                SystemCall.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else {
            let code = errno
            _ = SystemCall.close(fd)
            throw Failure.connect(code)
        }
        return TCPConnection(fd: fd)
    }

    static func setTimeouts(_ fd: Int32, _ seconds: TimeInterval) {
        var tv = timeval()
        tv.tv_sec = Int(seconds)
        tv.tv_usec = .init(Int((seconds - Double(Int(seconds))) * 1_000_000))
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        #if canImport(Darwin)
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    public var isOpen: Bool { fd >= 0 }

    public func close() {
        if fd >= 0 { _ = SystemCall.close(fd); fd = -1 }
    }

    public func write(_ data: Data) throws {
        guard fd >= 0 else { throw Failure.closed }
        var sent = 0
        let bytes = [UInt8](data)
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBytes { SystemCall.send(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                throw errno == EAGAIN || errno == EWOULDBLOCK ? Failure.timeout : Failure.io(errno)
            }
            sent += n
        }
    }

    /// Whatever arrives next (at most `max` bytes), or `timeout`.
    public func readSome(max: Int = 65536) throws -> [UInt8] {
        if !buffer.isEmpty {
            defer { buffer.removeAll() }
            return buffer
        }
        guard fd >= 0 else { throw Failure.closed }
        var chunk = [UInt8](repeating: 0, count: max)
        while true {
            let n = chunk.withUnsafeMutableBytes { SystemCall.recv(fd, $0.baseAddress, $0.count) }
            if n > 0 { return Array(chunk[0..<n]) }
            if n == 0 { throw Failure.closed }
            if errno == EINTR { continue }
            throw errno == EAGAIN || errno == EWOULDBLOCK ? Failure.timeout : Failure.io(errno)
        }
    }

    /// One line without its newline; reads until one is complete.
    public func readLine() throws -> Data {
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<nl])
                buffer.removeSubrange(...nl)
                return line
            }
            guard fd >= 0 else { throw Failure.closed }
            var chunk = [UInt8](repeating: 0, count: 8192)
            let n = chunk.withUnsafeMutableBytes { SystemCall.recv(fd, $0.baseAddress, $0.count) }
            if n > 0 { buffer += chunk[0..<n]; continue }
            if n == 0 { throw Failure.closed }
            if errno == EINTR { continue }
            throw errno == EAGAIN || errno == EWOULDBLOCK ? Failure.timeout : Failure.io(errno)
        }
    }
}

/// The libc calls, reached without clashing with same-named methods.
enum SystemCall {
    #if canImport(Glibc)
    static func close(_ fd: Int32) -> Int32 { Glibc.close(fd) }
    static func connect(_ fd: Int32, _ a: UnsafePointer<sockaddr>, _ l: socklen_t) -> Int32 { Glibc.connect(fd, a, l) }
    static func send(_ fd: Int32, _ p: UnsafeRawPointer?, _ n: Int) -> Int { Glibc.send(fd, p, n, Int32(MSG_NOSIGNAL)) }
    static func recv(_ fd: Int32, _ p: UnsafeMutableRawPointer?, _ n: Int) -> Int { Glibc.recv(fd, p, n, 0) }
    #else
    static func close(_ fd: Int32) -> Int32 { Darwin.close(fd) }
    static func connect(_ fd: Int32, _ a: UnsafePointer<sockaddr>, _ l: socklen_t) -> Int32 { Darwin.connect(fd, a, l) }
    static func send(_ fd: Int32, _ p: UnsafeRawPointer?, _ n: Int) -> Int { Darwin.send(fd, p, n, 0) }
    static func recv(_ fd: Int32, _ p: UnsafeMutableRawPointer?, _ n: Int) -> Int { Darwin.recv(fd, p, n, 0) }
    #endif
}

/// A synchronous QMP session: greeting, capabilities negotiation, then
/// commands. Events that arrive between commands are collected, not lost.
public final class QMPClient {
    public enum Failure: Error, Equatable {
        case noGreeting
        case handshake(String)
        case command(klass: String, description: String)
    }

    public let connection: TCPConnection
    public private(set) var version = ""
    public private(set) var events: [String] = []

    public init(connection: TCPConnection) throws {
        self.connection = connection
        guard case .greeting(let v) = try QMPCodec.decode(connection.readLine()) else { throw Failure.noGreeting }
        version = v
        let reply = try exchange("qmp_capabilities")
        if case .error(let k, let d) = reply { throw Failure.handshake("\(k): \(d)") }
    }

    public static func connect(port: UInt16, timeout: TimeInterval = 2) throws -> QMPClient {
        try QMPClient(connection: TCPConnection.connect(port: port, timeout: timeout))
    }

    /// Sends a command and returns its reply, skipping (and recording) events.
    @discardableResult
    public func exchange(_ name: String, arguments: [String: String] = [:]) throws -> QMPMessage {
        try connection.write(QMPCodec.command(name, arguments: arguments))
        while true {
            let message = try QMPCodec.decode(connection.readLine())
            if case .event(let event, _) = message { events.append(event); continue }
            return message
        }
    }

    public func execute(_ name: String, arguments: [String: String] = [:]) throws -> QMPValue {
        switch try exchange(name, arguments: arguments) {
        case .success(let value): return value
        case .error(let k, let d): throw Failure.command(klass: k, description: d)
        default: throw Failure.handshake("unexpected reply to \(name)")
        }
    }

    public func status() throws -> String {
        try execute("query-status")["status"]?.stringValue ?? "unknown"
    }
}
