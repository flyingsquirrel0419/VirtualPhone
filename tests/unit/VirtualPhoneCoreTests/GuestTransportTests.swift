import Foundation
import XCTest
@testable import VirtualPhoneCore

/// The network shell against a real bash that calls back over /dev/tcp,
/// exactly as the guest's bash does through slirp.
final class GuestTransportTests: XCTestCase {
    func startBash(connectingTo port: UInt16) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        // The guest's command with the loopback in place of slirp's 10.0.2.2.
        p.arguments = ["-c", "exec 3<>/dev/tcp/127.0.0.1/\(port); exec bash --noprofile --norc <&3 >&3 2>&3"]
        try p.run()
        return p
    }

    func testNetworkShellRunsFramedCommands() throws {
        let shell = try NetworkShellTransport()
        XCTAssertTrue(shell.callbackCommand.contains("/dev/tcp/10.0.2.2/\(shell.port)"))
        XCTAssertFalse(shell.isConnected)
        XCTAssertNil(shell.run("true", timeout: 1))

        let bash = try startBash(connectingTo: shell.port)
        defer { bash.terminate() }
        try shell.accept(timeout: 5)
        XCTAssertTrue(shell.isConnected)

        let hello = shell.run("echo hello; echo world", timeout: 5)
        XCTAssertEqual(hello, ShellFrame.Result(output: ["hello", "world"], status: 0))
        let missing = try XCTUnwrap(shell.run("ls /definitely/not/here", timeout: 5))
        XCTAssertNotEqual(missing.status, 0)
        XCTAssertTrue(missing.output.joined().contains("No such file"))
        XCTAssertEqual(shell.run("printf 'no newline'", timeout: 5)?.output, ["no newline"])
        // A slow command times out; the next one is not confused by its late output.
        XCTAssertNil(shell.run("sleep 1; echo late", timeout: 0.3))
        XCTAssertEqual(shell.run("echo next", timeout: 5)?.output, ["next"])
    }

    func testFallbackSkipsDisconnected() throws {
        let dead = try NetworkShellTransport()
        let live = try NetworkShellTransport()
        let bash = try startBash(connectingTo: live.port)
        defer { bash.terminate() }
        try live.accept(timeout: 5)
        let both = FallbackTransport([dead, live])
        XCTAssertTrue(both.isConnected)
        XCTAssertEqual(both.run("echo via-live", timeout: 5)?.output, ["via-live"])
        XCTAssertEqual(both.lastUsed, "network")
        XCTAssertNil(FallbackTransport([dead]).run("true", timeout: 1))
    }

    /// A command that timed out may still be running: it must not be retyped elsewhere.
    func testTimeoutDoesNotFallBack() throws {
        let slow = try NetworkShellTransport(), spare = try NetworkShellTransport()
        let a = try startBash(connectingTo: slow.port), b = try startBash(connectingTo: spare.port)
        defer { a.terminate(); b.terminate() }
        try slow.accept(timeout: 5)
        try spare.accept(timeout: 5)
        let both = FallbackTransport([slow, spare])
        XCTAssertEqual(both.execute("sleep 2", timeout: 0.3), .timedOut)
        XCTAssertEqual(both.lastUsed, "network")
        XCTAssertEqual(spare.run("echo untouched", timeout: 5)?.output, ["untouched"])
        XCTAssertEqual(try NetworkShellTransport().execute("true", timeout: 1), .unavailable)
    }
}
