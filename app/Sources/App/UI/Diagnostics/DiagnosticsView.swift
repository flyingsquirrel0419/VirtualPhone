import SwiftUI
import UIKit

enum HostInfo {
    static var model: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    static var residentMB: Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let rc = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return rc == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }

    /// This process's CPU use, summed over its threads (100 = one core).
    static var cpuPercent: Double {
        var threads: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads else { return -1 }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)),
                          vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        }
        var total = 0.0
        for i in 0..<Int(count) {
            var info = thread_basic_info()
            var n = mach_msg_type_number_t(THREAD_INFO_MAX)
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) {
                    thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &n)
                }
            }
            if kr == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 {
                total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100
            }
        }
        return total
    }

    static var physicalMB: Int { Int(ProcessInfo.processInfo.physicalMemory / 1_048_576) }

    static func freeDiskMB() -> Int {
        let values = try? AppModel.documents.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Int((values?.volumeAvailableCapacityForImportantUsage ?? 0) / 1_048_576)
    }
}

struct DiagnosticsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var exported: URL?

    var body: some View {
        NavigationStack {
            List {
                Section("App") {
                    InfoRow(label: "App Version", value: model.build.version + " (\(model.build.build))")
                    InfoRow(label: "Commit", value: model.build.commit)
                    InfoRow(label: "Channel", value: model.build.channel)
                    InfoRow(label: "Emulator library", value: InfernoRuntime.isBundled ? "bundled" : "missing")
                }
                Section("Host") {
                    InfoRow(label: "Host iOS", value: UIDevice.current.systemVersion)
                    InfoRow(label: "Host Device", value: HostInfo.model)
                    InfoRow(label: "Memory", value: "\(HostInfo.physicalMB) MB physical · \(HostInfo.residentMB) MB used")
                    InfoRow(label: "Free disk", value: "\(HostInfo.freeDiskMB()) MB")
                    InfoRow(label: "JIT Status", value: "\(model.jit.label) — \(model.jit.detail)")
                }
                Section("Devices") {
                    ForEach(model.packages) { p in
                        let c = p.configuration
                        InfoRow(label: c.name,
                                value: "\(c.cpuCores) cores · \(c.memoryMB) MB · tb \(c.translatorCacheMB) MB · \(c.displayPreset.rawValue) · net \(c.network ? "on" : "off")")
                    }
                }
                Section("JIT providers") {
                    ForEach(JITProviders.all, id: \.id) { provider in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(provider.name).font(.subheadline.weight(.semibold))
                            Text(provider.instructions).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Recent Errors") {
                    let errors = AppLogger.shared.snapshotRecentErrors()
                    if errors.isEmpty { Text("None").foregroundStyle(.secondary) }
                    ForEach(Array(errors.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 11, design: .monospaced))
                    }
                }
                Section {
                    Button("Export Diagnostics") { exported = DiagnosticsExporter.export(model: model) }
                    if let exported {
                        ShareLink(item: exported) { Label("Share diagnostics.zip", systemImage: "square.and.arrow.up") }
                    }
                } footer: {
                    Text("Contains app logs, device configurations and the guest console log, with the app's container path removed. No guest image, firmware or key is included.")
                }
            }
            .navigationTitle("Diagnostics")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// Builds diagnostics.zip from text only: logs and JSON configurations,
/// redacted. The zip is made by the system (NSFileCoordinator .forUploading)
/// so no archive library is needed.
enum DiagnosticsExporter {
    static func export(model: AppModel) -> URL? {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("diagnostics", isDirectory: true)
        try? fm.removeItem(at: staging)
        try? fm.createDirectory(at: staging, withIntermediateDirectories: true)
        AppLogger.shared.flush()
        let home = NSHomeDirectory()

        func copyRedacted(_ source: URL, as name: String, limit: Int = 4 << 20) {
            guard let data = try? Data(contentsOf: source) else { return }
            let tail = data.count > limit ? data.suffix(limit) : data
            let text = LogLine.redact(String(decoding: tail, as: UTF8.self), homeDirectory: home)
            try? text.write(to: staging.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        copyRedacted(AppLogger.currentLog, as: "app.log")
        copyRedacted(AppLogger.previousLog, as: "app.prev.log")
        for p in model.packages {
            let base = p.url.deletingPathExtension().lastPathComponent
            copyRedacted(p.url.appendingPathComponent("config.json"), as: "\(base).config.json")
            copyRedacted(p.url.appendingPathComponent("firmware-links.json"), as: "\(base).firmware-links.json")
            copyRedacted(p.logsURL.appendingPathComponent("guest-console.log"), as: "\(base).guest-console.log")
        }
        let summary = """
        \(model.build.title) \(model.build.subtitle)
        commit \(model.build.commit)
        host \(HostInfo.model) iOS \(UIDevice.current.systemVersion)
        memory \(HostInfo.physicalMB) MB, used \(HostInfo.residentMB) MB, free disk \(HostInfo.freeDiskMB()) MB
        jit \(model.jit.label): \(model.jit.detail)
        emulator library \(InfernoRuntime.isBundled ? "bundled" : "missing")
        """
        try? summary.write(to: staging.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)

        var result: URL?
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: staging, options: .forUploading, error: &coordError) { zipped in
            let target = fm.temporaryDirectory.appendingPathComponent("diagnostics.zip")
            try? fm.removeItem(at: target)
            if (try? fm.copyItem(at: zipped, to: target)) != nil { result = target }
        }
        if let coordError { AppLogger.shared.log(.app, "Diagnostics export failed: \(coordError)", level: .error) }
        return result
    }
}
