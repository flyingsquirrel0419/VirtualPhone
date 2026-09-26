import Foundation
import XCTest
@testable import VirtualPhoneCore

final class DeviceStateTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vp-ds-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    static let qemuImg = ["/usr/bin/qemu-img", "/opt/homebrew/bin/qemu-img", "/usr/local/bin/qemu-img"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    @discardableResult
    func run(_ tool: String, _ args: [String]) throws -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return (p.terminationStatus, text)
    }

    func testOverlayHeaderRoundTrip() throws {
        let url = dir.appendingPathComponent("o.qcow2")
        try QCOW2Overlay.create(at: url, backing: "../base.img", backingFormat: "raw", virtualSize: 34 << 30)
        let info = try XCTUnwrap(QCOW2Overlay.inspect(url))
        XCTAssertEqual(info.virtualSize, 34 << 30)
        XCTAssertEqual(info.backing, "../base.img")
        XCTAssertThrowsError(try QCOW2Overlay.create(at: url, backing: "x", backingFormat: "raw", virtualSize: 1 << 20))
        XCTAssertEqual(relativePath(from: URL(fileURLWithPath: "/a/b/Devices/X.vphone/disks"),
                                    to: URL(fileURLWithPath: "/a/b/InfernoData/root.qcow2")), "../../../InfernoData/root.qcow2")
    }

    /// qemu-img accepts the overlay, and writing through it leaves the base untouched.
    func testOverlayWithRealQEMU() throws {
        guard let qemuImg = Self.qemuImg else { throw XCTSkip("qemu-img not installed") }
        let qemuIO = qemuImg.replacingOccurrences(of: "qemu-img", with: "qemu-io")
        let base = dir.appendingPathComponent("base.img")
        try Data(repeating: 0xAB, count: 4 << 20).write(to: base)
        let disks = dir.appendingPathComponent("disks")
        try FileManager.default.createDirectory(at: disks, withIntermediateDirectories: true)
        let overlay = disks.appendingPathComponent("root.qcow2")
        try QCOW2Overlay.create(at: overlay, backing: relativePath(from: disks, to: base), backingFormat: "raw",
                                virtualSize: 4 << 20)

        let (checkStatus, check) = try run(qemuImg, ["check", overlay.path])
        XCTAssertEqual(checkStatus, 0, check)
        let (_, info) = try run(qemuImg, ["info", "--output=json", overlay.path])
        XCTAssertTrue(info.contains("\"virtual-size\": 4194304"), info)
        XCTAssertTrue(info.contains("\"backing-filename-format\": \"raw\""), info)

        let (w, wout) = try run(qemuIO, ["-c", "write -P 0x5a 1M 64k", overlay.path])
        XCTAssertEqual(w, 0, wout)
        let (r, rout) = try run(qemuIO, ["-c", "read -P 0x5a 1M 64k", "-c", "read -P 0xab 0 64k", overlay.path])
        XCTAssertEqual(r, 0, rout)
        XCTAssertFalse(rout.contains("Pattern verification failed"), rout)
        XCTAssertEqual(try Data(contentsOf: base), Data(repeating: 0xAB, count: 4 << 20), "base image must be unchanged")
        XCTAssertEqual(try run(qemuImg, ["check", overlay.path]).0, 0)
    }

    func testPrepareResolveResetAndClone() throws {
        let docs = dir!
        let data = docs.appendingPathComponent("InfernoData")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let links = FirmwareLinks()
        var resolved = GuestFiles.resolve(links, documents: docs, isUsableFile: { _ in true }).files
        for role in GuestFiles.Role.allCases where role != .root {
            let url = resolved.paths[role]!
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("\(role.rawValue)".utf8).write(to: url)
        }
        try Data(repeating: 1, count: 1 << 20).write(to: data.appendingPathComponent("root"))
        resolved = GuestFiles.resolve(links, documents: docs).files
        XCTAssertEqual(resolved.rootFormat, "raw")

        let devices = docs.appendingPathComponent("Devices")
        let pkg = try VMPackage.create(in: devices, configuration: MachineConfiguration(name: "P"))
        XCTAssertTrue(pkg.configuration.protectBaseImage)
        XCTAssertEqual(DeviceState.resolve(resolved, for: pkg), resolved, "nothing to use before prepare")
        XCTAssertTrue(try DeviceState.prepare(pkg, files: resolved))
        XCTAssertFalse(try DeviceState.prepare(pkg, files: resolved), "idempotent")

        let used = DeviceState.resolve(resolved, for: pkg)
        XCTAssertEqual(used.path(.root), DeviceState.overlayURL(in: pkg).path)
        XCTAssertEqual(used.rootFormat, "qcow2")
        XCTAssertTrue(used.path(.sepNVRAM).hasPrefix(pkg.url.path))
        XCTAssertEqual(used.path(.kernel), resolved.path(.kernel), "read-only inputs stay shared")
        XCTAssertEqual(try String(contentsOfFile: used.path(.sepNVRAM)), "sepNVRAM")
        XCTAssertEqual(QCOW2Overlay.inspect(DeviceState.overlayURL(in: pkg))?.backing, "../../../InfernoData/root")

        // A clone carries the device state; its relative backing path still resolves.
        let copy = try pkg.clone(named: "P2")
        XCTAssertTrue(DeviceState.exists(in: copy))

        // Protection off: the shared files are used even though a state exists.
        var off = pkg
        off.configuration.protectBaseImage = false
        XCTAssertEqual(DeviceState.resolve(resolved, for: off), resolved)

        try DeviceState.reset(pkg)
        XCTAssertFalse(DeviceState.exists(in: pkg))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: pkg.url.appendingPathComponent("nvram").path), [])
    }

    func testSchema1MigratesWithProtectionOff() throws {
        let v1 = #"{"schema":1,"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Old","machine":"t8030","device":"iPhone11","cpuCores":4,"memoryMB":2048,"translatorCacheMB":128,"displayPreset":"iphone11","audio":false,"network":true}"#
        let c = try MachineConfiguration.decode(Data(v1.utf8))
        XCTAssertEqual(c.schema, 2)
        XCTAssertFalse(c.protectBaseImage)
        XCTAssertTrue(MachineConfiguration().protectBaseImage, "new devices protect the base image")
    }
}
