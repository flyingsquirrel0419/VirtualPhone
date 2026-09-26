import Foundation
import XCTest
@testable import VirtualPhoneCore

final class ConfigurationTests: XCTestCase {
    func testDefaultsAreValid() {
        let config = MachineConfiguration()
        XCTAssertTrue(config.isValid)
        XCTAssertEqual(config.validate(), [])
        XCTAssertEqual(config.machine, "t8030")
        XCTAssertEqual(config.schema, MachineConfiguration.currentSchema)
    }

    func testRoundTrip() throws {
        let config = MachineConfiguration(name: "Test", cpuCores: 2, memoryMB: 1536,
                                          translatorCacheMB: 256, displayPreset: .iphoneSE,
                                          audio: true, network: false, bootArgs: "serial=3")
        let back = try MachineConfiguration.decode(config.encoded())
        XCTAssertEqual(back, config)
    }

    func testValidationRanges() {
        var c = MachineConfiguration()
        c.cpuCores = 0
        c.memoryMB = 512
        c.translatorCacheMB = 4096
        c.name = "  "
        let errors = c.validate().filter(\.isError)
        XCTAssertEqual(errors.count, 4)
        XCTAssertFalse(c.isValid)
    }

    func testHighMemoryWarnsButIsValid() {
        let c = MachineConfiguration(memoryMB: 3072)
        XCTAssertTrue(c.isValid)
        XCTAssertTrue(c.validate().contains { !$0.isError })
    }

    func testMultilineBootArgsRejected() {
        let c = MachineConfiguration(bootArgs: "serial=3\nrd=md0")
        XCTAssertFalse(c.isValid)
    }

    func testMigrationFromSchema0() throws {
        let legacy = #"{"name":"Old","cpuCores":2,"memoryMB":2048,"tbSizeMB":64}"#
        let c = try MachineConfiguration.decode(Data(legacy.utf8))
        XCTAssertEqual(c.schema, MachineConfiguration.currentSchema)
        XCTAssertEqual(c.name, "Old")
        XCTAssertFalse(c.protectBaseImage)
        XCTAssertEqual(c.translatorCacheMB, 64)
        XCTAssertEqual(c.displayPreset, .iphone11)
        XCTAssertFalse(c.audio)
    }

    func testFutureSchemaRefused() {
        let future = #"{"schema":99,"name":"x"}"#
        XCTAssertThrowsError(try MachineConfiguration.decode(Data(future.utf8))) { error in
            XCTAssertEqual(error as? MachineConfiguration.LoadError, .unsupportedSchema(99))
        }
    }

    func testMalformed() {
        XCTAssertThrowsError(try MachineConfiguration.decode(Data("nope".utf8)))
        XCTAssertThrowsError(try MachineConfiguration.decode(Data("[1]".utf8)))
        XCTAssertThrowsError(try MachineConfiguration.decode(Data(#"{"schema":1,"name":3}"#.utf8)))
    }

    func testPresetsHaveAlignedRows() {
        for preset in DisplayPreset.allCases {
            XCTAssertTrue(DisplayPreset.rowIsAligned(width: preset.width), preset.rawValue)
        }
        XCTAssertFalse(DisplayPreset.rowIsAligned(width: 750))
    }
}

final class CoordinateMapperTests: XCTestCase {
    func testExactFit() {
        let m = CoordinateMapper(view: Size2D(width: 414, height: 896), guestWidth: 828, guestHeight: 1792)
        XCTAssertEqual(m.scale, 0.5, accuracy: 1e-9)
        let p = m.guestPixel(for: Point2D(x: 207, y: 448))
        XCTAssertEqual(p?.x, 414)
        XCTAssertEqual(p?.y, 896)
        XCTAssertEqual(m.guestPixel(for: Point2D(x: 0, y: 0))?.x, 0)
    }

    func testLetterboxedTouchesOutsideAreNil() {
        // Wide view: bars left and right.
        let m = CoordinateMapper(view: Size2D(width: 1000, height: 896), guestWidth: 828, guestHeight: 1792)
        let rect = m.contentRect
        XCTAssertEqual(rect.size.width, 414, accuracy: 1e-9)
        XCTAssertEqual(rect.origin.x, 293, accuracy: 1e-9)
        XCTAssertNil(m.guestPixel(for: Point2D(x: 100, y: 400)))
        XCTAssertNil(m.guestPixel(for: Point2D(x: 900, y: 400)))
        XCTAssertEqual(m.guestPixel(for: Point2D(x: 293, y: 0))?.x, 0)
        let clamped = m.clampedGuestPixel(for: Point2D(x: 5000, y: -10))
        XCTAssertEqual(clamped?.x, 827)
        XCTAssertEqual(clamped?.y, 0)
    }

    func testBottomRightNeverOverflows() {
        let m = CoordinateMapper(view: Size2D(width: 320, height: 568), guestWidth: 640, guestHeight: 1136)
        let p = m.guestPixel(for: Point2D(x: 319.999, y: 567.999))
        XCTAssertEqual(p?.x, 639)
        XCTAssertEqual(p?.y, 1135)
        XCTAssertNil(m.guestPixel(for: Point2D(x: 320, y: 568)))
    }

    func testDegenerate() {
        let m = CoordinateMapper(view: Size2D(width: 0, height: 0), guestWidth: 828, guestHeight: 1792)
        XCTAssertNil(m.guestPixel(for: Point2D(x: 1, y: 1)))
        XCTAssertNil(m.clampedGuestPixel(for: Point2D(x: 1, y: 1)))
    }
}
