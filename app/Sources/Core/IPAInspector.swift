import Foundation

/// Why an .ipa cannot go into the guest, in terms the UI can explain.
public enum IPAProblem: Equatable, Sendable {
    case invalidIPA(String)
    /// FairPlay-encrypted: only the device that bought it can decrypt it, and
    /// VirtualPhone never tries to work around that.
    case encryptedBinary
    case unsupportedArchitecture([String])
    case requiresNewerIOS(minimum: String, guest: String)

    public var message: String {
        switch self {
        case .invalidIPA(let why): return "Not a valid IPA: \(why)"
        case .encryptedBinary: return "The app is FairPlay-encrypted (App Store download) and will not run in the guest."
        case .unsupportedArchitecture(let arches):
            return "The app has no arm64 code (found: \(arches.isEmpty ? "none" : arches.joined(separator: ", ")))."
        case .requiresNewerIOS(let min, let guest): return "The app needs iOS \(min); the guest runs iOS \(guest)."
        }
    }
}

public struct IPAReport: Equatable, Sendable {
    public var appDirectory = ""
    public var bundleID = ""
    public var name = ""
    public var version = ""
    public var minimumOS = ""
    public var executable = ""
    public var architectures: [String] = []
    public var encrypted = false
    public var problems: [IPAProblem] = []
    public var isInstallable: Bool { problems.isEmpty }
}

public enum IPAInspector {
    /// Inspects `url` for a guest running `guestOS`.
    public static func inspect(_ url: URL, guestOS: String = "14.8") -> IPAReport {
        var report = IPAReport()
        let zip: ZipArchive
        do { zip = try ZipArchive(url: url) } catch {
            report.problems = [.invalidIPA("not a readable ZIP archive (\(error))")]
            return report
        }
        for e in zip.entries {
            if e.path.hasPrefix("/") || e.path.split(separator: "/").contains("..") {
                report.problems = [.invalidIPA("unsafe path \(e.path)")]
                return report
            }
        }
        let apps = Set(zip.entries.compactMap { e -> String? in
            let parts = e.path.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count > 2, parts[0] == "Payload", parts[1].hasSuffix(".app") else { return nil }
            return String(parts[1])
        })
        guard apps.count == 1, let app = apps.first else {
            report.problems = [.invalidIPA(apps.isEmpty ? "no Payload/*.app" : "more than one app in Payload")]
            return report
        }
        report.appDirectory = "Payload/\(app)"

        guard let plistEntry = zip.entry("Payload/\(app)/Info.plist"),
              let plistBytes = try? zip.extract(plistEntry, limit: 4 << 20),
              let info = (try? PropertyListSerialization.propertyList(from: Data(plistBytes), format: nil)) as? [String: Any]
        else {
            report.problems = [.invalidIPA("Info.plist missing or unreadable")]
            return report
        }
        report.bundleID = info["CFBundleIdentifier"] as? String ?? ""
        report.name = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? app
        report.version = info["CFBundleShortVersionString"] as? String ?? ""
        report.minimumOS = info["MinimumOSVersion"] as? String ?? ""
        report.executable = info["CFBundleExecutable"] as? String ?? ""
        if report.bundleID.isEmpty || report.executable.isEmpty {
            report.problems.append(.invalidIPA("Info.plist lacks CFBundleIdentifier or CFBundleExecutable"))
            return report
        }

        guard let exe = zip.entry("Payload/\(app)/\(report.executable)") else {
            report.problems.append(.invalidIPA("executable \(report.executable) missing"))
            return report
        }
        do {
            let macho = try MachOInfo.read { length in try zip.extract(exe, prefix: length) }
            report.architectures = macho.slices.map(\.architecture)
            report.encrypted = macho.slices.contains { $0.encrypted }
            if !macho.slices.contains(where: { $0.architecture.hasPrefix("arm64") }) {
                report.problems.append(.unsupportedArchitecture(report.architectures))
            }
            if report.encrypted { report.problems.append(.encryptedBinary) }
            let minOS = report.minimumOS.isEmpty ? (macho.slices.first?.minimumOS ?? "") : report.minimumOS
            if !minOS.isEmpty, compareVersions(minOS, guestOS) == .orderedDescending {
                report.problems.append(.requiresNewerIOS(minimum: minOS, guest: guestOS))
            }
        } catch {
            report.problems.append(.invalidIPA("executable is not a Mach-O file (\(error))"))
        }
        return report
    }

    /// Dotted numeric comparison: "14.10" > "14.8".
    public static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}

/// Just enough Mach-O to answer: which architectures, encrypted or not,
/// which minimum OS.
public struct MachOInfo: Equatable {
    public struct Slice: Equatable {
        public let architecture: String
        public let encrypted: Bool
        public let minimumOS: String?
    }

    public let slices: [Slice]

    static let headerPeek = 64 * 1024

    /// `bytes(n)` returns the first n bytes of the file.
    public static func read(_ bytes: (Int) throws -> [UInt8]) throws -> MachOInfo {
        let head = try bytes(headerPeek)
        guard head.count >= 8 else { throw ZipArchive.Failure.corrupt("too short") }
        let magicBE = head.u32be(0)
        if magicBE == 0xCAFE_BABE || magicBE == 0xCAFE_BABF {
            let is64 = magicBE == 0xCAFE_BABF
            let count = Int(head.u32be(4))
            guard count > 0, count < 16 else { throw ZipArchive.Failure.corrupt("bad fat header") }
            var slices: [Slice] = []
            for i in 0..<count {
                let base = 8 + i * (is64 ? 32 : 20)
                guard base + 16 <= head.count else { break }
                let cpu = head.u32be(base), sub = head.u32be(base + 4)
                let offset = is64 ? Int(UInt64(head.u32be(base + 8)) << 32 | UInt64(head.u32be(base + 12))) : Int(head.u32be(base + 8))
                let slice = try bytes(offset + headerPeek)
                guard slice.count > offset else { throw ZipArchive.Failure.corrupt("slice out of range") }
                slices.append(try thin(Array(slice[offset...]), fallbackCPU: cpu, fallbackSub: sub))
            }
            return MachOInfo(slices: slices)
        }
        return MachOInfo(slices: [try thin(head, fallbackCPU: nil, fallbackSub: nil)])
    }

    static func archName(_ cpu: UInt32, _ sub: UInt32) -> String {
        switch cpu {
        case 0x0100_000C: return (sub & 0xFF) == 2 ? "arm64e" : "arm64"
        case 0x0200_000C: return "arm64_32"
        case 12: return "armv7"
        case 0x0100_0007: return "x86_64"
        case 7: return "i386"
        default: return String(format: "cpu-0x%x", cpu)
        }
    }

    static func thin(_ b: [UInt8], fallbackCPU: UInt32?, fallbackSub: UInt32?) throws -> Slice {
        guard b.count >= 32 else { throw ZipArchive.Failure.corrupt("truncated Mach-O header") }
        let magic = b.u32(0)
        guard magic == 0xFEED_FACF || magic == 0xFEED_FACE else { throw ZipArchive.Failure.corrupt(String(format: "magic 0x%08x", magic)) }
        let is64 = magic == 0xFEED_FACF
        let arch = archName(b.u32(4), b.u32(8))
        let ncmds = Int(b.u32(16))
        var p = is64 ? 32 : 28
        var encrypted = false
        var minOS: String?
        func version(_ v: UInt32) -> String { "\(v >> 16).\((v >> 8) & 0xFF)" + ((v & 0xFF) != 0 ? ".\(v & 0xFF)" : "") }
        for _ in 0..<min(ncmds, 4096) {
            guard p + 8 <= b.count else { break }
            let cmd = b.u32(p), size = Int(b.u32(p + 4))
            guard size >= 8 else { break }
            switch cmd {
            case 0x21, 0x2C: // LC_ENCRYPTION_INFO(_64): cryptoff, cryptsize, cryptid
                if p + 20 <= b.count, b.u32(p + 16) != 0 { encrypted = true }
            case 0x32: // LC_BUILD_VERSION: platform, minos
                if p + 16 <= b.count { minOS = version(b.u32(p + 12)) }
            case 0x25: // LC_VERSION_MIN_IPHONEOS: version
                if p + 12 <= b.count, minOS == nil { minOS = version(b.u32(p + 8)) }
            default: break
            }
            p += size
        }
        return Slice(architecture: arch, encrypted: encrypted, minimumOS: minOS)
    }
}
