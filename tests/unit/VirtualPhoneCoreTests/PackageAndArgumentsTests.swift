import Foundation
import XCTest
@testable import VirtualPhoneCore

final class VMPackageTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testCreateOpenList() throws {
        let pkg = try VMPackage.create(in: root, configuration: MachineConfiguration(name: "Phone A"))
        XCTAssertEqual(pkg.url.lastPathComponent, "Phone A.vphone")
        for sub in VMPackage.subdirectories {
            XCTAssertTrue(FileManager.default.fileExists(atPath: pkg.url.appendingPathComponent(sub).path))
        }
        let reopened = try VMPackage.open(pkg.url)
        XCTAssertEqual(reopened.configuration, pkg.configuration)
        XCTAssertEqual(reopened.links, FirmwareLinks())
        XCTAssertThrowsError(try VMPackage.create(in: root, configuration: MachineConfiguration(name: "Phone A")))

        // A broken package is listed as broken, not dropped.
        let broken = root.appendingPathComponent("Broken.vphone")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: broken.appendingPathComponent("config.json"))
        _ = try VMPackage.create(in: root, configuration: MachineConfiguration(name: "Another"))
        let listing = VMPackage.list(in: root)
        XCTAssertEqual(listing.packages.map(\.configuration.name), ["Another", "Phone A"])
        XCTAssertEqual(listing.broken.map(\.lastPathComponent), ["Broken.vphone"])
    }

    func testCloneRenameDelete() throws {
        let pkg = try VMPackage.create(in: root, configuration: MachineConfiguration(name: "Orig"))
        try Data("disk".utf8).write(to: pkg.url.appendingPathComponent("disks/overlay.qcow2"))
        try Data("log".utf8).write(to: pkg.url.appendingPathComponent("logs/emulator.log"))

        let copy = try pkg.clone(named: "Copy")
        XCTAssertNotEqual(copy.configuration.id, pkg.configuration.id)
        XCTAssertEqual(copy.configuration.memoryMB, pkg.configuration.memoryMB)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.url.appendingPathComponent("disks/overlay.qcow2").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.url.appendingPathComponent("logs/emulator.log").path))

        let renamed = try copy.renamed(to: "Renamed")
        XCTAssertEqual(renamed.url.lastPathComponent, "Renamed.vphone")
        XCTAssertEqual(try VMPackage.open(renamed.url).configuration.name, "Renamed")
        XCTAssertThrowsError(try renamed.renamed(to: "Orig"))

        try renamed.delete()
        XCTAssertEqual(VMPackage.list(in: root).packages.count, 1)
    }

    func testUncleanShutdownMarker() throws {
        let pkg = try VMPackage.create(in: root, configuration: MachineConfiguration(name: "M"))
        XCTAssertNil(pkg.uncleanShutdown)
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        pkg.markRunning(at: when)
        XCTAssertEqual(try VMPackage.open(pkg.url).uncleanShutdown, when)
        // A clone never inherits a run in progress.
        XCTAssertNil(try pkg.clone(named: "M2").uncleanShutdown)
        pkg.markStopped()
        XCTAssertNil(pkg.uncleanShutdown)
    }

    func testDirectoryNames() {
        XCTAssertEqual(VMPackage.directoryName(for: "a/b:c"), "a-b-c.vphone")
        XCTAssertNil(VMPackage.directoryName(for: ""))
        XCTAssertNil(VMPackage.directoryName(for: ".."))
        XCTAssertNil(VMPackage.directoryName(for: ".hidden"))
    }

    func testSaveReplacesAtomically() throws {
        var pkg = try VMPackage.create(in: root, configuration: MachineConfiguration(name: "S"))
        pkg.configuration.cpuCores = 2
        try pkg.save()
        XCTAssertEqual(try VMPackage.open(pkg.url).configuration.cpuCores, 2)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: pkg.url.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertEqual(leftovers, [])
    }
}

final class EmulatorArgumentsTests: XCTestCase {
    let docs = URL(fileURLWithPath: "/docs")
    let options = EmulatorArguments.Options(splitWX: true, qemuDataDirectory: "/app/qemu-data",
                                            consoleLogPath: "/docs/logs/console.log")

    func resolved(_ present: (URL) -> Bool = { _ in true }) -> (GuestFiles, [GuestFiles.Role]) {
        let r = GuestFiles.resolve(FirmwareLinks(), documents: docs, isUsableFile: present)
        return (r.files, r.missing)
    }

    func testArgvShape() throws {
        let (files, missing) = resolved()
        XCTAssertEqual(missing, [])
        let argv = try EmulatorArguments.build(config: MachineConfiguration(), files: files, options: options)
        XCTAssertEqual(argv.first, "qemu-system-aarch64")
        func value(after flag: String) -> String? {
            argv.firstIndex(of: flag).map { argv[$0 + 1] }
        }
        XCTAssertEqual(value(after: "-accel"), "tcg,thread=multi,tb-size=128,split-wx=on")
        XCTAssertEqual(value(after: "-smp"), "4")
        XCTAssertEqual(value(after: "-m"), "2048M")
        XCTAssertEqual(value(after: "-kernel"), "/docs/InfernoData/Restore/kernelcache.release.iphone12b")
        XCTAssertEqual(value(after: "-display"), "none")
        let machine = try XCTUnwrap(value(after: "-M"))
        XCTAssertTrue(machine.hasPrefix("t8030,"))
        XCTAssertTrue(machine.contains("sep-rom=/docs/AppleSEPROM-Cebu-B1"))
        XCTAssertTrue(machine.contains("disp-width=828,disp-height=1792,disp-scale=2"))
        XCTAssertTrue(machine.contains("boot-mode=exit_recovery"))
        XCTAssertTrue(argv.contains("file=/docs/InfernoData/root.qcow2,format=qcow2,if=none,id=root"))
        XCTAssertTrue(argv.contains("driver=apple.mca,property=audiodev,value=quiet"))
        XCTAssertTrue(argv.contains { $0.hasPrefix("apple-ncm-host,") })
        XCTAssertEqual(argv.filter { $0.hasPrefix("nvme-ns,") }.count, 6)
        XCTAssertTrue(argv.contains { $0.hasPrefix("apple-nvram,") })
    }

    func testOptionsChangeArgv() throws {
        let (files, _) = resolved()
        var config = MachineConfiguration(displayPreset: .iphone8, audio: true, network: false)
        config.translatorCacheMB = 256
        var opts = options
        opts.splitWX = false
        let argv = try EmulatorArguments.build(config: config, files: files, options: opts)
        XCTAssertTrue(argv.contains("tcg,thread=multi,tb-size=256"))
        XCTAssertFalse(argv.contains("-audiodev"))
        XCTAssertFalse(argv.contains("-netdev"))
        XCTAssertTrue(argv.contains { $0.contains("disp-width=752") })
    }

    func testRawRootWhenNoQcow() throws {
        let (files, missing) = resolved { $0.lastPathComponent != "root.qcow2" }
        XCTAssertEqual(missing, [])
        XCTAssertEqual(files.rootFormat, "raw")
        XCTAssertEqual(files.path(.root), "/docs/InfernoData/root")
    }

    func testMissingFilesAndInvalidConfigRefused() {
        let (files, missing) = resolved { !$0.path.contains("sep_ssc") && !$0.path.hasSuffix("/root") && !$0.path.hasSuffix("root.qcow2") }
        XCTAssertEqual(Set(missing), [.sepSSC, .root])
        XCTAssertThrowsError(try EmulatorArguments.build(config: MachineConfiguration(), files: files,
                                                        missing: missing, options: options)) { error in
            guard case .missingFiles = error as? EmulatorArguments.BuildError else { return XCTFail("\(error)") }
        }
        var bad = MachineConfiguration()
        bad.cpuCores = 99
        XCTAssertThrowsError(try EmulatorArguments.build(config: bad, files: files, options: options))
    }

    func testAbsoluteLinks() {
        let links = FirmwareLinks(dataDirectory: "/var/guest", sepROM: "/var/rom")
        let r = GuestFiles.resolve(links, documents: docs, isUsableFile: { _ in true })
        XCTAssertEqual(r.files.path(.sepROM), "/var/rom")
        XCTAssertEqual(r.files.path(.nvram), "/var/guest/nvram")
    }

    func testRealFileCheckRejectsEmptyAndDirectories() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vp-f-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let empty = dir.appendingPathComponent("empty")
        try Data().write(to: empty)
        let full = dir.appendingPathComponent("full")
        try Data("x".utf8).write(to: full)
        XCTAssertFalse(GuestFiles.isUsableFile(empty))
        XCTAssertFalse(GuestFiles.isUsableFile(dir))
        XCTAssertFalse(GuestFiles.isUsableFile(dir.appendingPathComponent("absent")))
        XCTAssertTrue(GuestFiles.isUsableFile(full))
    }
}

final class MiscCoreTests: XCTestCase {
    func testLogFormat() {
        let date = Date(timeIntervalSince1970: 45296.123) // 12:34:56.123 UTC
        let line = LogLine(date: date, category: .vm, level: .info, message: "Machine started")
        XCTAssertEqual(line.formatted(timeZone: TimeZone(identifier: "UTC")!), "[12:34:56.123][VM][INFO] Machine started")
        let forged = LogLine(date: date, category: .guest, level: .error, message: "a\n[00:00:00.000][APP][INFO] b")
        XCTAssertFalse(forged.formatted(timeZone: TimeZone(identifier: "UTC")!).contains("\n"))
        XCTAssertEqual(LogLine.redact("/var/mobile/Containers/X/Documents/a", homeDirectory: "/var/mobile/Containers/X"), "~/Documents/a")
        XCTAssertTrue(LogLevel.debug < LogLevel.error)
    }

    func testBuildMetadata() {
        let meta = BuildMetadata(infoDictionary: [
            "CFBundleDisplayName": "VirtualPhone", "CFBundleShortVersionString": "0.3.0",
            "CFBundleVersion": "12", "VPGitCommit": "abc1234def", "VPReleaseChannel": "stable",
        ])
        XCTAssertEqual(meta.title, "VirtualPhone 0.3.0")
        XCTAssertEqual(meta.subtitle, "Build abc1234")
        XCTAssertEqual(BuildMetadata(infoDictionary: [:]).subtitle, "Build unknown · dev")
    }

    func testSemanticVersion() {
        XCTAssertEqual(SemanticVersion("v0.1.0")?.description, "0.1.0")
        XCTAssertEqual(SemanticVersion("1.2.3-beta.1")?.prerelease, "beta.1")
        XCTAssertNil(SemanticVersion("1.2"))
        XCTAssertNil(SemanticVersion("1.2.x"))
        XCTAssertNil(SemanticVersion("1.2.3-"))
        XCTAssertTrue(SemanticVersion("1.0.0-alpha")! < SemanticVersion("1.0.0")!)
        XCTAssertTrue(SemanticVersion("0.9.9")! < SemanticVersion("0.10.0")!)
    }

    func testJITDecision() {
        let none = JITProbe(debuggerAttached: false, mapJITAllowed: false, mirrorMapAllowed: false)
        XCTAssertEqual(none.status(provider: "x").label, "JIT unavailable")
        let dbg = JITProbe(debuggerAttached: true, mapJITAllowed: false, mirrorMapAllowed: true)
        XCTAssertEqual(dbg.status(provider: "StikDebug"), .enabled(method: .splitWX, provider: "StikDebug"))
        XCTAssertTrue(JITMethod.splitWX.needsSplitWX)
        let ent = JITProbe(debuggerAttached: false, mapJITAllowed: true, mirrorMapAllowed: true)
        XCTAssertEqual(ent.status(provider: "entitlement"), .enabled(method: .mapJIT, provider: "entitlement"))
        let broken = JITProbe(debuggerAttached: true, mapJITAllowed: false, mirrorMapAllowed: false)
        XCTAssertEqual(broken.status(provider: "x").label, "JIT verification failed")
        let lying = JITProbe(debuggerAttached: true, mapJITAllowed: true, mirrorMapAllowed: true, executionVerified: false)
        XCTAssertEqual(lying.status(provider: "x").label, "JIT verification failed")
    }
}
