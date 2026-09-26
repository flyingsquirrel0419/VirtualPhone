import Foundation

/// A way to run shell commands in the guest.
public protocol GuestTransport: AnyObject {
    var name: String { get }
    var isConnected: Bool { get }
    /// Blocking: runs one command and returns its framed result, or nil on
    /// timeout or a broken channel.
    func run(_ command: String, timeout: TimeInterval) -> ShellFrame.Result?
}

/// A shell on a socket of its own: the guest's bash connects back to the app
/// through slirp (`/dev/tcp/10.0.2.2/PORT`) and reads commands from it. No
/// console echo, no kernel chatter, no per-line cost — the better channel
/// whenever the guest has a network (upstream Inferno-iOS's finding).
public final class NetworkShellTransport: GuestTransport {
    public let name = "network"
    private let listener: TCPListener
    private var connection: TCPConnection?
    private let lock = NSLock()

    public init(port: UInt16 = 0) throws {
        listener = try TCPListener(port: port)
    }

    public var port: UInt16 { listener.port }

    /// Typed on the console once; a non-interactive bash then serves the socket.
    public var callbackCommand: String {
        "(exec 3<>/dev/tcp/\(GuestCommand.hostAddress)/\(port); exec bash --noprofile --norc <&3 >&3 2>&3) &"
    }

    public var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return connection?.isOpen ?? false
    }

    /// Waits for the guest to call back after `callbackCommand` was typed.
    public func accept(timeout: TimeInterval) throws {
        let c = try listener.accept(timeout: timeout)
        lock.lock()
        connection?.close()
        connection = c
        lock.unlock()
    }

    public func run(_ command: String, timeout: TimeInterval) -> ShellFrame.Result? {
        lock.lock()
        defer { lock.unlock() }
        guard let c = connection, c.isOpen else { return nil }
        let frame = ShellFrame()
        var parser = ShellFrame.Parser(frame: frame)
        parser.dropKernelLines = false // nothing else writes to this socket
        do {
            try c.write(Data((frame.wrap(command) + "\n").utf8))
            let deadline = Date() + timeout
            while true {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { return nil }
                c.setTimeout(remaining)
                let line = String(decoding: try c.readLine(), as: UTF8.self)
                if let result = parser.feed(line.hasSuffix("\r") ? String(line.dropLast()) : line) { return result }
            }
        } catch TCPConnection.Failure.timeout {
            // Late output of this command carries its own frame id and is ignored later.
            return nil
        } catch {
            c.close()
            return nil
        }
    }

    public func close() {
        lock.lock()
        connection?.close()
        connection = nil
        lock.unlock()
        listener.close()
    }
}

/// Tries each transport in order, so a dead network falls back to the console.
public final class FallbackTransport: GuestTransport {
    public let transports: [GuestTransport]
    public private(set) var lastUsed: String?

    public init(_ transports: [GuestTransport]) { self.transports = transports }

    public var name: String { transports.map(\.name).joined(separator: "→") }
    public var isConnected: Bool { transports.contains { $0.isConnected } }

    public func run(_ command: String, timeout: TimeInterval) -> ShellFrame.Result? {
        for t in transports where t.isConnected {
            if let r = t.run(command, timeout: timeout) {
                lastUsed = t.name
                return r
            }
        }
        return nil
    }
}
