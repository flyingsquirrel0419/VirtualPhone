import SwiftUI

/// Edits one device's configuration and where its guest files are.
struct MachineSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var package: VMPackage
    @State private var customBootArgs: Bool

    init(package: VMPackage) {
        _package = State(initialValue: package)
        _customBootArgs = State(initialValue: package.configuration.bootArgs != nil)
    }

    private var config: Binding<MachineConfiguration> { $package.configuration }

    var body: some View {
        NavigationStack {
            Form {
                Section("Machine") {
                    TextField("Name", text: config.name)
                    Stepper("CPU cores: \(package.configuration.cpuCores)", value: config.cpuCores,
                            in: MachineConfiguration.coreRange)
                    Stepper("Memory: \(package.configuration.memoryMB) MB", value: config.memoryMB,
                            in: MachineConfiguration.memoryRangeMB, step: 256)
                    Stepper("Translator cache: \(package.configuration.translatorCacheMB) MB",
                            value: config.translatorCacheMB, in: MachineConfiguration.translatorCacheRangeMB, step: 32)
                }
                Section("Display") {
                    Picker("Panel", selection: config.displayPreset) {
                        ForEach(DisplayPreset.allCases, id: \.self) { Text("\($0.displayName) — \($0.width)×\($0.height)").tag($0) }
                    }
                }
                Section {
                    Toggle("Network", isOn: config.network)
                    Toggle("Enable Audio (experimental)", isOn: config.audio)
                } footer: {
                    Text("Audio is off by default: without it the sound hardware is not described to the guest, which boots faster.")
                }
                Section("Boot") {
                    Toggle("Custom boot arguments", isOn: $customBootArgs)
                    if customBootArgs {
                        TextField("boot-args", text: Binding(
                            get: { package.configuration.bootArgs ?? MachineConfiguration.defaultBootArgs },
                            set: { package.configuration.bootArgs = $0 }), axis: .vertical)
                            .font(.system(.footnote, design: .monospaced))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                }
                Section {
                    TextField("Data folder", text: $package.links.dataDirectory)
                    TextField("SEP ROM", text: $package.links.sepROM)
                    TextField("Kernel", text: $package.links.kernel)
                    TextField("Device tree", text: $package.links.deviceTree)
                    TextField("Trust cache", text: $package.links.trustCache)
                } header: {
                    Text("Guest files")
                } footer: {
                    Text("Relative paths start at the app's Documents folder (data folder) or inside the data folder (the rest). VirtualPhone never ships these files; see docs/GUEST_IMAGE.md.")
                }
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                let issues = package.configuration.validate()
                if !issues.isEmpty {
                    Section("Problems") {
                        ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                            switch issue {
                            case .error(let m): Label(m, systemImage: "xmark.octagon").foregroundStyle(.red)
                            case .warning(let m): Label(m, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if !customBootArgs { package.configuration.bootArgs = nil }
                        model.save(package)
                        dismiss()
                    }
                    .disabled(!package.configuration.isValid)
                }
            }
        }
    }
}
