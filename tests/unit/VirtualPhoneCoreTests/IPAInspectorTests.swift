import Foundation
import XCTest
@testable import VirtualPhoneCore

final class IPAInspectorTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("fixtures/ipa")

    func fixture(_ name: String) -> URL { Self.fixtures.appendingPathComponent(name) }

    func testInflateVectors() throws {
        let fixed = try Inflate.decompress([UInt8](Data(contentsOf: fixture("deflate-fixed.bin"))))
        XCTAssertEqual(String(decoding: fixed, as: UTF8.self), "abcabcabc hello")
        let stored = try Inflate.decompress([UInt8](Data(contentsOf: fixture("deflate-stored.bin"))))
        XCTAssertEqual(stored, Array(String(repeating: "VirtualPhone inflate vector. ", count: 40).utf8))
        XCTAssertThrowsError(try Inflate.decompress([0x07])) // reserved block type
        XCTAssertThrowsError(try Inflate.decompress([UInt8](Data(contentsOf: fixture("deflate-fixed.bin")).prefix(3))))
        XCTAssertEqual(CRC32.checksum(Array("123456789".utf8)), 0xCBF4_3926)
    }

    func testZipReadsDeflatedAndStoredEntriesWithCRC() throws {
        let zip = try ZipArchive(url: fixture("ok.ipa.zip"))
        XCTAssertEqual(Set(zip.entries.map(\.path)), ["Payload/Demo.app/Info.plist", "Payload/Demo.app/Demo", "Payload/Demo.app/README"])
        let readme = try XCTUnwrap(zip.entry("Payload/Demo.app/README"))
        XCTAssertEqual(readme.method, 0)
        XCTAssertEqual(try zip.extract(readme), Array("hello\n".utf8))
        let exe = try XCTUnwrap(zip.entry("Payload/Demo.app/Demo"))
        XCTAssertEqual(exe.method, 8)
        XCTAssertEqual(try zip.extract(exe).count, exe.uncompressedSize) // dynamic Huffman + CRC
        XCTAssertEqual(try zip.extract(exe, prefix: 4), [0xCF, 0xFA, 0xED, 0xFE])
        XCTAssertThrowsError(try ZipArchive(url: fixture("not-a-zip.bin")))
        XCTAssertThrowsError(try ZipArchive(url: fixture("absent.zip")))
    }

    func testInstallableApp() {
        let r = IPAInspector.inspect(fixture("ok.ipa.zip"))
        XCTAssertEqual(r.problems, [])
        XCTAssertTrue(r.isInstallable)
        XCTAssertEqual(r.bundleID, "dev.virtualphone.fixture")
        XCTAssertEqual(r.version, "1.2.3")
        XCTAssertEqual(r.architectures, ["arm64"])
        XCTAssertFalse(r.encrypted)
        XCTAssertEqual(r.appDirectory, "Payload/Demo.app")
    }

    func testEachProblemIsNamed() {
        XCTAssertEqual(IPAInspector.inspect(fixture("encrypted.ipa.zip")).problems, [.encryptedBinary])
        XCTAssertEqual(IPAInspector.inspect(fixture("x86.ipa.zip")).problems, [.unsupportedArchitecture(["x86_64"])])
        XCTAssertEqual(IPAInspector.inspect(fixture("newer.ipa.zip")).problems,
                       [.requiresNewerIOS(minimum: "15.0", guest: "14.8")])
        XCTAssertEqual(IPAInspector.inspect(fixture("newer.ipa.zip"), guestOS: "15.1").problems, [])
        for name in ["twoapps.ipa.zip", "noplist.ipa.zip", "badexe.ipa.zip", "not-a-zip.bin"] {
            let problems = IPAInspector.inspect(fixture(name)).problems
            XCTAssertEqual(problems.count, 1, name)
            guard case .invalidIPA = problems.first else { return XCTFail("\(name): \(problems)") }
        }
        XCTAssertTrue(IPAProblem.encryptedBinary.message.contains("FairPlay"))
    }

    func testFatBinaryUsesSliceBeyondThePeek() {
        let r = IPAInspector.inspect(fixture("fat.ipa.zip"), guestOS: "14.8")
        XCTAssertEqual(r.architectures, ["x86_64", "arm64"])
        XCTAssertEqual(r.problems, [])
        // Minimum OS comes from the arm64 slice's LC_BUILD_VERSION when the plist has none.
        XCTAssertEqual(IPAInspector.inspect(fixture("fat.ipa.zip"), guestOS: "11.0").problems.count, 1)
    }

    func testVersionCompare() {
        XCTAssertEqual(IPAInspector.compareVersions("14.10", "14.8"), .orderedDescending)
        XCTAssertEqual(IPAInspector.compareVersions("14", "14.0.0"), .orderedSame)
        XCTAssertEqual(IPAInspector.compareVersions("13.4.1", "14"), .orderedAscending)
    }
}
