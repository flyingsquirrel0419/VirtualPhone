import Foundation
import XCTest
@testable import VirtualPhoneCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

final class ConsoleBufferTests: XCTestCase {
    func testSplitLinesAndLineEndings() {
        var c = ConsoleBuffer()
        XCTAssertEqual(c.feed(Array("iBoot for n104".utf8)), [])
        XCTAssertEqual(c.pending, "iBoot for n104")
        XCTAssertEqual(c.feed(Array("ap\r\nsecond\nthird\rfourth".utf8)), ["iBoot for n104ap", "second", "third"])
        XCTAssertEqual(c.pending, "fourth")
        // \r then \n in separate chunks is one line ending, not two.
        var d = ConsoleBuffer()
        d.feed(Array("a\r".utf8))
        d.feed(Array("\nb\n".utf8))
        XCTAssertEqual(d.lines, ["a", "b"])
    }

    func testUTF8SplitAcrossFeeds() {
        var c = ConsoleBuffer()
        let bytes = Array("héllo→x\n".utf8)
        let cut = bytes.firstIndex(of: 0xE2)! + 1 // inside the 3-byte arrow
        c.feed(Array(bytes[..<cut]))
        c.feed(Array(bytes[cut...]))
        XCTAssertEqual(c.lines, ["héllo→x"])
    }

    func testEscapesAndControlsStripped() {
        XCTAssertEqual(ConsoleBuffer.stripEscapes("\u{1B}[1;32mOK\u{1B}[0m\tdone\u{07}"), "OK\tdone")
        XCTAssertEqual(ConsoleBuffer.stripEscapes("\u{1B}]0;title\u{07}text"), "text")
        XCTAssertEqual(ConsoleBuffer.stripEscapes("a\u{1B}"), "a")
    }

    func testCapacity() {
        var c = ConsoleBuffer(capacity: 3)
        for i in 0..<10 { c.feed(Array("\(i)\n".utf8)) }
        XCTAssertEqual(c.lines, ["7", "8", "9"])
        XCTAssertEqual(c.totalBytes, 20)
        c.clear()
        XCTAssertEqual(c.text, "")
    }
}

final class BootPhaseTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1000)

    func testPhasesAdvanceWithTimes() {
        var d = BootPhaseDetector()
        d.start(at: t0)
        XCTAssertEqual(d.phase, .poweredOn)
        XCTAssertNil(d.observe("random noise", at: t0 + 1))
        XCTAssertEqual(d.observe("::\tiBoot for n104ap, Copyright", at: t0 + 2)?.phase, .iboot)
        XCTAssertEqual(d.observe("Darwin Kernel Version 20.0.0", at: t0 + 30)?.phase, .kernel)
        // An earlier marker later on does not move backwards.
        XCTAssertNil(d.observe("iBoot-6723", at: t0 + 31))
        XCTAssertEqual(d.observe("BSD root: disk0s1, major 1", at: t0 + 60)?.phase, .launchd)
        XCTAssertEqual(d.observe("bash-5.0# ", at: t0 + 200)?.phase, .shell)
        XCTAssertEqual(d.time(to: .kernel), 30)
        XCTAssertEqual(d.time(to: .shell), 200)
        XCTAssertNil(d.time(to: .panicked))
    }

    func testSkippingPhasesAndPanic() {
        var d = BootPhaseDetector()
        d.start(at: t0)
        XCTAssertEqual(d.observe("launchd[1]: starting", at: t0 + 5)?.phase, .launchd)
        d.observe("Still waiting for root device", at: t0 + 6)
        XCTAssertEqual(d.warnings, ["Still waiting for root device"])
        XCTAssertEqual(d.observe("panic(cpu 0 caller 0xfffffff0): SEP panic", at: t0 + 7)?.phase, .panicked)
        XCTAssertNil(d.observe("bash-5.0#", at: t0 + 8))
        d.reset(at: t0 + 9)
        XCTAssertEqual(d.phase, .poweredOn)
        XCTAssertEqual(d.warnings, [])
    }

    func testObserveWithoutStartStartsImplicitly() {
        var d = BootPhaseDetector()
        XCTAssertEqual(d.observe("Darwin Kernel Version", at: t0)?.phase, .kernel)
        XCTAssertEqual(d.transitions.map(\.phase), [.poweredOn, .kernel])
    }
}

final class QMPCodecTests: XCTestCase {
    func decode(_ s: String) throws -> QMPMessage { try QMPCodec.decode(Data(s.utf8)) }

    func testMessages() throws {
        XCTAssertEqual(try decode(#"{"QMP": {"version": {"qemu": {"micro": 2, "minor": 2, "major": 10}, "package": ""}, "capabilities": ["oob"]}}"#),
                       .greeting(version: "10.2.2"))
        let status = try decode(#"{"return": {"status": "paused", "running": false}}"#)
        XCTAssertEqual(QMPCodec.status(from: status), "paused")
        if case .success(let v) = status { XCTAssertEqual(v["running"]?.boolValue, false) } else { XCTFail() }
        XCTAssertEqual(try decode(#"{"return": {}}"#), .success(.object([:])))
        XCTAssertEqual(try decode(#"{"error": {"class": "CommandNotFound", "desc": "nope"}}"#),
                       .error(klass: "CommandNotFound", description: "nope"))
        if case .event(let name, _) = try decode(#"{"event": "STOP", "timestamp": {"seconds": 1}}"#) {
            XCTAssertEqual(name, "STOP")
        } else { XCTFail() }
        XCTAssertThrowsError(try decode("not json"))
        XCTAssertThrowsError(try decode(#"{"something": 1}"#))
    }

    func testCommandEncoding() throws {
        let line = QMPCodec.command("human-monitor-command", arguments: ["command-line": "info status"])
        XCTAssertEqual(line.last, 0x0A)
        let object = try JSONSerialization.jsonObject(with: line.dropLast()) as? [String: Any]
        XCTAssertEqual(object?["execute"] as? String, "human-monitor-command")
        XCTAssertEqual(String(decoding: QMPCodec.command("quit"), as: UTF8.self), "{\"execute\":\"quit\"}\n")
    }
}

/// A one-connection QMP server on 127.0.0.1, answering from a script.
final class FakeQMPServer {
    let port: UInt16
    private let fd: Int32
    private let thread: Thread

    init(replies: @escaping (String) -> [String]) throws {
        #if canImport(Glibc)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        self.fd = fd
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) } }
        listen(fd, 1)
        var bound = sockaddr_in()
        var len = size
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        port = UInt16(bigEndian: bound.sin_port)
        let listener = fd
        let thread = Thread {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            func send(_ s: String) { let b = Array((s + "\n").utf8); _ = b.withUnsafeBytes { SystemCall.send(client, $0.baseAddress, $0.count) } }
            send(#"{"QMP": {"version": {"qemu": {"micro": 0, "minor": 2, "major": 10}}, "capabilities": []}}"#)
            var pending = [UInt8]()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = chunk.withUnsafeMutableBytes { SystemCall.recv(client, $0.baseAddress, $0.count) }
                if n <= 0 { break }
                pending += chunk[0..<n]
                while let nl = pending.firstIndex(of: 0x0A) {
                    let line = String(decoding: pending[..<nl], as: UTF8.self)
                    pending.removeSubrange(...nl)
                    replies(line).forEach(send)
                }
            }
            _ = SystemCall.close(client)
        }
        self.thread = thread
        thread.start()
    }

    deinit { _ = SystemCall.close(fd) }
}

final class QMPClientTests: XCTestCase {
    func testHandshakeStatusEventsAndErrors() throws {
        let server = try FakeQMPServer { line in
            if line.contains("qmp_capabilities") { return [#"{"return": {}}"#] }
            if line.contains("query-status") {
                return [#"{"event": "STOP", "timestamp": {"seconds": 1}}"#, #"{"return": {"status": "paused", "running": false}}"#]
            }
            return [#"{"error": {"class": "CommandNotFound", "desc": "The command nope has not been found"}}"#]
        }
        let client = try QMPClient.connect(port: server.port)
        XCTAssertEqual(client.version, "10.2.0")
        XCTAssertEqual(try client.status(), "paused")
        XCTAssertEqual(client.events, ["STOP"])
        XCTAssertThrowsError(try client.execute("nope")) { error in
            guard case .command(let k, _) = error as? QMPClient.Failure else { return XCTFail("\(error)") }
            XCTAssertEqual(k, "CommandNotFound")
        }
    }

    func testConnectRefusedAndTimeout() throws {
        XCTAssertThrowsError(try TCPConnection.connect(port: 1, timeout: 0.5))
        let silent = try FakeQMPServer { $0.contains("qmp_capabilities") ? [#"{"return": {}}"#] : [] }
        let client = try QMPClient.connect(port: silent.port, timeout: 0.3)
        XCTAssertThrowsError(try client.status()) { error in
            XCTAssertEqual(error as? TCPConnection.Failure, .timeout)
        }
    }
}
