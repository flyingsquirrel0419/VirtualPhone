import Foundation
import XCTest
@testable import VirtualPhoneCore

final class GuestShellTests: XCTestCase {
    func testQuoting() {
        XCTAssertEqual(GuestShell.quote("/Applications/My App.app"), "'/Applications/My App.app'")
        XCTAssertEqual(GuestShell.quote("it's"), "'it'\\''s'")
        XCTAssertEqual(GuestShell.quote("a\nb"), "$'a\\012b'")
        XCTAssertEqual(GuestShell.quote("é"), "$'\\303\\251'")
        XCTAssertEqual(GuestShell.quote("x'\\"), "'x'\\''\\'")
    }

    func testCksumMatchesPOSIX() throws {
        var c = PosixCksum()
        c.update(Array("123456789".utf8))
        XCTAssertEqual(c.value, 930_766_865) // `printf 123456789 | cksum`
        XCTAssertEqual(c.length, 9)
        XCTAssertEqual(PosixCksum().value, 4_294_967_295) // empty input
        let parsed = try XCTUnwrap(PosixCksum.parse("930766865 9"))
        XCTAssertEqual(parsed.crc, 930_766_865)
        XCTAssertNil(PosixCksum.parse("garbage"))
    }

    func testFramingIgnoresEchoAndKernelNoise() {
        let frame = ShellFrame(id: "abc")
        let typed = frame.wrap("ls /Applications")
        XCTAssertFalse(typed.contains(frame.startMarker), "the echoed line must not contain the joined marker")
        var parser = ShellFrame.Parser(frame: frame)
        let console = [
            "bash-5.0# " + typed,                     // console echo
            "@@VPS:abc@@",
            "Cydia.app",
            "[  123.456] AppleSEPManager: something", // kernel chatter inside the window
            "Filza.app",
            "@@VPE:abc:0@@",
        ]
        var result: ShellFrame.Result?
        for line in console { if let r = parser.feed(line) { result = r } }
        XCTAssertEqual(result, ShellFrame.Result(output: ["Cydia.app", "Filza.app"], status: 0))
    }

    func testFramingStatusAndTrailingOutput() {
        let frame = ShellFrame(id: "z9")
        var parser = ShellFrame.Parser(frame: frame)
        XCTAssertNil(parser.feed("noise before"))
        XCTAssertNil(parser.feed("@@VPS:z9@@"))
        XCTAssertEqual(parser.feed("partial@@VPE:z9:127@@"), ShellFrame.Result(output: ["partial"], status: 127))
    }

    func testCommandsAndDiagnosis() {
        XCTAssertEqual(GuestCommand.receiveFile(port: 5000, to: "/tmp/a b"),
                       "cat < /dev/tcp/10.0.2.2/5000 > '/tmp/a b' && cksum < '/tmp/a b'")
        let steps = GuestCommand.installSteps(tar: "/tmp/vp.tar", appName: "Demo.app")
        XCTAssertEqual(steps.first?.command, "mount -uw /")
        XCTAssertTrue(steps.contains { $0.command == "tar xf '/tmp/vp.tar' -C /Applications" && $0.critical })
        XCTAssertFalse(steps.contains { $0.command.hasSuffix("| head") })
        XCTAssertEqual(GuestCommand.diagnose(["tar: write error: No space left on device"]), "The guest's disk is full.")
        XCTAssertNil(GuestCommand.diagnose(["fine"]))
    }
}

final class TarAndTransferTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vp-tar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func run(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    func testTarIsReadableBySystemTarAndCksumAgrees() throws {
        let url = dir.appendingPathComponent("t.tar")
        let w = try TarWriter(url: url)
        try w.addDirectory("Demo.app")
        try w.addFile("Demo.app/Info.plist", contents: Array("<plist/>".utf8))
        let long = "Demo.app/" + String(repeating: "d/", count: 60) + "file.txt"
        try w.addFile(long, contents: Array(repeating: 65, count: 1000), mode: 0o755)
        try w.addSymlink("Demo.app/link", target: "Info.plist")
        try w.finish()
        XCTAssertEqual(w.bytesWritten % 512, 0)
        let listing = try run(["tar", "-tf", url.path]).split(separator: "\n").map(String.init)
        XCTAssertEqual(listing, ["Demo.app/", "Demo.app/Info.plist", long, "Demo.app/link"])
        let sys = try XCTUnwrap(PosixCksum.parse(try run(["cksum", url.path])))
        XCTAssertEqual(sys.crc, w.checksum.value)
        XCTAssertEqual(sys.length, w.checksum.length)
        XCTAssertThrowsError(try w.addFile(String(repeating: "x", count: 300), contents: []))
    }

    func testGuestTarFromIPA() throws {
        let ipa = IPAInspectorTests.fixtures.appendingPathComponent("ok.ipa.zip")
        let report = IPAInspector.inspect(ipa)
        let tar = dir.appendingPathComponent("app.tar")
        let sum = try IPAInspector.makeGuestTar(from: ipa, report: report, to: tar)
        let listing = Set(try run(["tar", "-tf", tar.path]).split(separator: "\n").map(String.init))
        XCTAssertEqual(listing, ["Demo.app/", "Demo.app/Info.plist", "Demo.app/Demo", "Demo.app/README"])
        XCTAssertEqual(PosixCksum.parse(try run(["cksum", tar.path]))?.crc, sum.crc)
    }

    func testTransferServerBothWays() throws {
        let payload = (0..<300_000).map { UInt8($0 % 251) }
        let source = dir.appendingPathComponent("src.bin")
        try Data(payload).write(to: source)
        var expected = PosixCksum()
        expected.update(payload)

        // App → guest: the "guest" is a client that reads to EOF.
        let out = try FileTransferServer()
        let got = UnsafeMutablePointer<[UInt8]>.allocate(capacity: 1)
        got.initialize(to: [])
        defer { got.deallocate() }
        let reader = Thread {
            guard let c = try? TCPConnection.connect(port: out.port) else { return }
            while let chunk = try? c.readSome() { got.pointee += chunk }
        }
        reader.start()
        let sent = try out.send(source, timeout: 5)
        XCTAssertEqual(sent.crc, expected.value)
        let deadline = Date() + 5
        while got.pointee.count < payload.count, Date() < deadline { usleep(10_000) }
        XCTAssertEqual(got.pointee, payload)

        // Guest → app.
        let inbound = try FileTransferServer()
        let writer = Thread {
            guard let c = try? TCPConnection.connect(port: inbound.port) else { return }
            try? c.write(Data(payload))
            c.close()
        }
        writer.start()
        let dest = dir.appendingPathComponent("dest.bin")
        let received = try inbound.receive(to: dest, timeout: 5)
        XCTAssertEqual(received.crc, expected.value)
        XCTAssertEqual(try Data(contentsOf: dest), Data(payload))

        XCTAssertThrowsError(try FileTransferServer().receive(to: dest, timeout: 0.2)) { error in
            XCTAssertEqual(error as? FileTransferServer.Failure, .timeout)
        }
    }
}
