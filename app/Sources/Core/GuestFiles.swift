import Foundation

/// Where a virtual device's guest files live.
///
/// VirtualPhone ships none of these: they come from the user's own IPSW and
/// restore, following ChefKiss's Inferno guide (docs/GUEST_IMAGE.md). A package
/// records *references* in `firmware-links.json` instead of copying gigabytes
/// of Apple files into itself.
public struct FirmwareLinks: Codable, Equatable, Sendable {
    public static let currentSchema = 1

    public var schema: Int
    /// Folder holding the guest's files (the guide's `InfernoData`). Absolute,
    /// or relative to the app's Documents directory.
    public var dataDirectory: String
    /// The SEP boot ROM, which the guide keeps outside `InfernoData`.
    public var sepROM: String
    public var kernel: String
    public var deviceTree: String
    /// Named after the iOS build's root filesystem DMG, so it differs per build.
    public var trustCache: String

    public init(
        dataDirectory: String = "InfernoData",
        sepROM: String = "AppleSEPROM-Cebu-B1",
        kernel: String = "Restore/kernelcache.release.iphone12b",
        deviceTree: String = "Restore/Firmware/all_flash/DeviceTree.n104ap.im4p",
        trustCache: String = "Restore/Firmware/038-44135-124.dmg.trustcache"
    ) {
        self.schema = Self.currentSchema
        self.dataDirectory = dataDirectory
        self.sepROM = sepROM
        self.kernel = kernel
        self.deviceTree = deviceTree
        self.trustCache = trustCache
    }
}

/// The files the machine needs, resolved to absolute paths.
public struct GuestFiles: Equatable, Sendable {
    public enum Role: String, CaseIterable, Sendable {
        case root, sepROM, kernel, deviceTree, trustCache, ticket, sepFirmware
        case firmware, syscfg, ctrlBits, nvram, effaceable, panicLog, sepNVRAM, sepSSC
    }

    public let dataDirectory: URL
    public let paths: [Role: URL]
    /// `qcow2` or `raw`, from the root image actually found.
    public let rootFormat: String

    public func path(_ role: Role) -> String { paths[role]!.path }

    /// Resolves `links` against `documents`. `exists` is injected so the
    /// check can be tested without touching the disk.
    public static func resolve(
        _ links: FirmwareLinks,
        documents: URL,
        isUsableFile: (URL) -> Bool = GuestFiles.isUsableFile
    ) -> (files: GuestFiles, missing: [Role]) {
        func anchored(_ path: String, to base: URL) -> URL {
            path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)
        }
        let data = anchored(links.dataDirectory, to: documents)
        let qcow = data.appendingPathComponent("root.qcow2")
        let raw = data.appendingPathComponent("root")
        let (root, format) = isUsableFile(qcow) ? (qcow, "qcow2") : (raw, "raw")

        var paths: [Role: URL] = [
            .root: root,
            .sepROM: anchored(links.sepROM, to: documents),
            .kernel: anchored(links.kernel, to: data),
            .deviceTree: anchored(links.deviceTree, to: data),
            .trustCache: anchored(links.trustCache, to: data),
        ]
        let fixed: [(Role, String)] = [
            (.ticket, "root_ticket.der"), (.sepFirmware, "sep-firmware.n104.RELEASE.new.img4"),
            (.firmware, "firmware"), (.syscfg, "syscfg"), (.ctrlBits, "ctrl_bits"),
            (.nvram, "nvram"), (.effaceable, "effaceable"), (.panicLog, "panic_log"),
            (.sepNVRAM, "sep_nvram"), (.sepSSC, "sep_ssc"),
        ]
        for (role, name) in fixed { paths[role] = data.appendingPathComponent(name) }

        let missing = Role.allCases.filter { !isUsableFile(paths[$0]!) }
        return (GuestFiles(dataDirectory: data, paths: paths, rootFormat: format), missing)
    }

    /// A regular, non-empty file. A folder or an empty file with the right
    /// name passes `fileExists` and then makes QEMU call exit() from inside
    /// our process, so both are refused up front.
    public static func isUsableFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber
        else { return false }
        return size.int64Value > 0
    }
}
