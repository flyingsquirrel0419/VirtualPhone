import Foundation
import SwiftUI

/// The app's model: the devices on disk, the host's JIT state, build info.
final class AppModel: ObservableObject {
    @Published private(set) var packages: [VMPackage] = []
    @Published private(set) var brokenPackages: [URL] = []
    @Published private(set) var jit: JITStatus = .unavailable(reason: "not checked yet")
    @Published var errorMessage: String?

    let build = BuildMetadata(infoDictionary: Bundle.main.infoDictionary ?? [:])

    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var devicesDirectory: URL { documents.appendingPathComponent("Devices", isDirectory: true) }

    init() {
        try? FileManager.default.createDirectory(at: Self.devicesDirectory, withIntermediateDirectories: true)
        // The folder the guest guide's files are copied into (Files → On My iPhone).
        try? FileManager.default.createDirectory(at: Self.documents.appendingPathComponent("InfernoData/Restore/Firmware/all_flash"),
                                                 withIntermediateDirectories: true)
        AppLogger.shared.log(.app, "\(build.title) (\(build.subtitle)) launched")
        reload()
        refreshJIT()
    }

    func reload() {
        let listing = VMPackage.list(in: Self.devicesDirectory)
        packages = listing.packages
        brokenPackages = listing.broken
        for url in listing.broken {
            AppLogger.shared.log(.storage, "Unreadable device package: \(url.lastPathComponent)", level: .warning)
        }
    }

    func refreshJIT() {
        let status = JITProbeRunner.currentStatus()
        if status != jit { AppLogger.shared.log(.jit, "\(status.label): \(status.detail)") }
        jit = status
    }

    private func attempt(_ what: String, _ body: () throws -> Void) {
        do {
            try body()
        } catch {
            errorMessage = "\(what) failed: \(error.localizedDescription)"
            AppLogger.shared.log(.storage, errorMessage!, level: .error)
        }
        reload()
    }

    func create(name: String, preset: DisplayPreset) {
        attempt("Create") {
            _ = try VMPackage.create(in: Self.devicesDirectory,
                                     configuration: MachineConfiguration(name: name, displayPreset: preset))
            AppLogger.shared.log(.storage, "Created \(name)")
        }
    }

    func clone(_ package: VMPackage) {
        attempt("Clone") { _ = try package.clone(named: uniqueName(package.configuration.name + " copy")) }
    }

    func rename(_ package: VMPackage, to name: String) {
        attempt("Rename") { _ = try package.renamed(to: name) }
    }

    func delete(_ package: VMPackage) {
        attempt("Delete") { try package.delete() }
    }

    func resetState(_ package: VMPackage) {
        attempt("Reset") {
            try DeviceState.reset(package)
            AppLogger.shared.log(.storage, "\(package.configuration.name): device state reset to the base image")
        }
    }

    func takeSnapshot(_ package: VMPackage, name: String) {
        attempt("Snapshot") {
            let snap = try DeviceSnapshots.take(package, name: name)
            AppLogger.shared.log(.storage, "\(package.configuration.name): snapshot \(snap.name) (\(snap.bytes) bytes)")
        }
    }

    func restoreSnapshot(_ package: VMPackage, id: String) {
        attempt("Restore") {
            try DeviceSnapshots.restore(package, id: id)
            AppLogger.shared.log(.storage, "\(package.configuration.name): restored snapshot \(id)")
        }
    }

    func deleteSnapshot(_ package: VMPackage, id: String) {
        attempt("Delete snapshot") { try DeviceSnapshots.delete(package, id: id) }
    }

    func save(_ package: VMPackage) {
        attempt("Save") { try package.save() }
    }

    private func uniqueName(_ base: String) -> String {
        let names = Set(packages.map(\.configuration.name))
        if !names.contains(base) { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    // MARK: - Starting a machine

    enum Readiness {
        case ready(arguments: [String])
        case notReady([String])
    }

    /// Everything that must be true before QEMU is handed a command line:
    /// qemu_init exit()s the whole app on a bad one.
    func readiness(of package: VMPackage) -> Readiness {
        var problems: [String] = []
        if !InfernoRuntime.isBundled { problems.append("This build has no emulator library.") }
        if !jit.isEnabled { problems.append("\(jit.label): \(jit.detail)") }
        let resolved = GuestFiles.resolve(package.links, documents: Self.documents)
        if !resolved.missing.isEmpty {
            problems.append("Missing guest files: " + resolved.missing.map(\.rawValue).joined(separator: ", "))
        }
        var files = resolved.files
        if problems.isEmpty, package.configuration.protectBaseImage {
            do {
                if try DeviceState.prepare(package, files: resolved.files) {
                    AppLogger.shared.log(.storage, "\(package.configuration.name): created its overlay and state copies")
                }
                files = DeviceState.resolve(resolved.files, for: package)
            } catch {
                problems.append("Could not prepare this device's own disk overlay: \(error.localizedDescription)")
            }
        }
        let splitWX: Bool
        if case .enabled(let method, _) = jit { splitWX = method.needsSplitWX } else { splitWX = true }
        let options = EmulatorArguments.Options(
            splitWX: splitWX,
            qemuDataDirectory: (Bundle.main.resourcePath ?? Bundle.main.bundlePath) + "/qemu-data",
            consoleLogPath: EmulatorController.consoleLogURL(for: package).path)
        do {
            let argv = try EmulatorArguments.build(config: package.configuration, files: files,
                                                   missing: resolved.missing, options: options)
            if problems.isEmpty { return .ready(arguments: argv) }
        } catch EmulatorArguments.BuildError.invalidConfiguration(let errors) {
            problems += errors
        } catch {
            // Missing files are already listed above.
        }
        return .notReady(problems)
    }

    /// The emulator resolves the USB socket against its working directory.
    func prepareWorkingDirectory(for package: VMPackage) {
        let state = package.url.appendingPathComponent("state")
        try? FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        FileManager.default.changeCurrentDirectoryPath(state.path)
    }
}
