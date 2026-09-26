import Foundation
import XCTest
@testable import VirtualPhoneCore

final class ConsoleLogTailerTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vp-tail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func append(_ url: URL, _ text: String) throws {
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        h.write(Data(text.utf8))
        try h.close()
    }

    func testTailsAppendsDetectsPhasesAndHandlesTruncation() throws {
        let url = dir.appendingPathComponent("guest-console.log")
        let t = ConsoleLogTailer(url: url)
        let t0 = Date(timeIntervalSince1970: 0)
        t.reset(at: t0)
        XCTAssertEqual(t.poll().lines, [])

        try append(url, "::\tiBoot for n104ap\nDarwin Kern")
        var u = t.poll(at: t0 + 3)
        XCTAssertEqual(u.lines, ["::\tiBoot for n104ap"])
        XCTAssertEqual(u.transitions.map(\.phase), [.iboot])

        try append(url, "el Version 20.0.0\n")
        u = t.poll(at: t0 + 40)
        XCTAssertEqual(u.lines, ["Darwin Kernel Version 20.0.0"])
        XCTAssertEqual(t.detector.time(to: .kernel), 40)

        // Someone empties the file (a new start): read again from the top.
        try Data("fresh\n".utf8).write(to: url)
        XCTAssertEqual(t.poll().lines, ["fresh"])
        XCTAssertEqual(t.offset, 6)
    }

    func testMissingFileAndChunking() throws {
        let t = ConsoleLogTailer(url: dir.appendingPathComponent("absent.log"))
        XCTAssertEqual(t.poll().lines, [])
        let url = dir.appendingPathComponent("big.log")
        try Data(String(repeating: "x\n", count: 100).utf8).write(to: url)
        let c = ConsoleLogTailer(url: url)
        c.maxReadBytes = 50
        XCTAssertEqual(c.poll().lines.count, 25)
        XCTAssertEqual(c.poll().lines.count, 25)
        XCTAssertEqual(c.buffer.lines.count, 50)
    }

    func testGuestFileReport() throws {
        let data = dir.appendingPathComponent("InfernoData")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: data.appendingPathComponent("nvram"))
        try Data().write(to: data.appendingPathComponent("syscfg"))
        let rows = GuestFiles.report(FirmwareLinks(), documents: dir)
        XCTAssertEqual(rows.count, GuestFiles.Role.allCases.count)
        let nvram = rows.first { $0.role == .nvram }!
        XCTAssertTrue(nvram.usable)
        XCTAssertEqual(nvram.size, 3)
        let syscfg = rows.first { $0.role == .syscfg }!
        XCTAssertFalse(syscfg.usable)
        XCTAssertEqual(syscfg.size, 0)
        XCTAssertNil(rows.first { $0.role == .kernel }!.size)
    }
}
