import SwiftUI

/// First screen: the devices, and a way to make one.
struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var creating = false
    @State private var renaming: VMPackage?
    @State private var renameText = ""
    @State private var deleting: VMPackage?
    @State private var editing: VMPackage?
    @State private var showMachine = false
    @State private var notReady: (VMPackage, [String])?
    @State private var showDiagnostics = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let active = model.active {
                        ActiveMachineBanner(controller: active) { showMachine = true }
                    }
                    jitBanner
                    if model.packages.isEmpty {
                        emptyState
                    }
                    ForEach(model.packages, id: \.url) { package in
                        DeviceCard(package: package, onStart: { start(package) })
                            .contextMenu { menu(for: package) }
                    }
                    if !model.brokenPackages.isEmpty {
                        Text("\(model.brokenPackages.count) device package(s) could not be read; see Diagnostics.")
                            .font(.footnote).foregroundStyle(.red)
                    }
                    Button { creating = true } label: {
                        Label("Create", systemImage: "plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                .padding()
            }
            .navigationTitle("My Devices")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showDiagnostics = true } label: { Image(systemName: "stethoscope") }
                }
                ToolbarItem(placement: .bottomBar) {
                    Text("\(model.build.title) · \(model.build.subtitle)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .refreshable { model.reload(); model.refreshJIT() }
        }
        .onAppear(perform: autoDemoIfAsked)
        .sheet(isPresented: $creating) { CreateDeviceView().environmentObject(model) }
        .sheet(item: $editing) { package in MachineSettingsView(package: package).environmentObject(model) }
        .sheet(isPresented: $showDiagnostics) { DiagnosticsView().environmentObject(model) }
        .fullScreenCover(isPresented: $showMachine) {
            if let controller = model.active { MachineView(controller: controller) }
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") { if let p = renaming { model.rename(p, to: renameText) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this device?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let p = deleting { model.delete(p) } }
        } message: {
            Text("Its configuration, NVRAM and overlays are removed. Guest files you copied in are not touched.")
        }
        .alert("Cannot start yet", isPresented: Binding(get: { notReady != nil }, set: { if !$0 { notReady = nil } })) {
            Button("Start demo (mock runtime)") { if let p = notReady?.0 { launch(p, mock: true) } }
            Button("OK", role: .cancel) {}
        } message: {
            Text(notReady?.1.joined(separator: "\n") ?? "")
        }
        .alert("Error", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var jitBanner: some View {
        HStack {
            StatusBadge(text: model.jit.label, color: model.jit.color)
            Text(model.jit.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Spacer()
            Button("Check") { model.refreshJIT() }.font(.caption)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "iphone").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("No devices yet").font(.headline)
            Text("Create an iPhone 11, then copy your own guest files into Files → On My iPhone → VirtualPhone → InfernoData.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    @ViewBuilder
    private func menu(for package: VMPackage) -> some View {
        Button { start(package) } label: { Label("Start", systemImage: "play.fill") }
        Button { launch(package, mock: true) } label: { Label("Start demo (mock)", systemImage: "play.rectangle") }
        Button { editing = package } label: { Label("Settings", systemImage: "slider.horizontal.3") }
        Button { renameText = package.configuration.name; renaming = package } label: { Label("Rename", systemImage: "pencil") }
        Button { model.clone(package) } label: { Label("Clone", systemImage: "plus.square.on.square") }
        if DeviceState.exists(in: package) {
            Button(role: .destructive) { model.resetState(package) } label: {
                Label("Reset Device State", systemImage: "arrow.uturn.backward")
            }
        }
        ShareLink(item: package.url.appendingPathComponent("config.json")) {
            Label("Export configuration", systemImage: "square.and.arrow.up")
        }
        Button(role: .destructive) { deleting = package } label: { Label("Delete", systemImage: "trash") }
    }

    /// `-VPAutoDemo YES` (a launch argument, read through UserDefaults) makes
    /// a demo device and boots it on the mock runtime at once: how the
    /// simulator smoke test (scripts/sim-smoke.sh) exercises the app unattended.
    private func autoDemoIfAsked() {
        guard UserDefaults.standard.bool(forKey: "VPAutoDemo"), model.active == nil else { return }
        let name = "Demo iPhone"
        if !model.packages.contains(where: { $0.configuration.name == name }) {
            model.create(name: name, preset: .iphone11)
        }
        guard let package = model.packages.first(where: { $0.configuration.name == name }) else { return }
        AppLogger.shared.log(.app, "Auto demo: starting \(name) on the mock runtime")
        launch(package, mock: true)
    }

    private func start(_ package: VMPackage) {
        model.refreshJIT()
        switch model.readiness(of: package) {
        case .ready(let argv): launch(package, mock: false, arguments: argv)
        case .notReady(let problems): notReady = (package, problems)
        }
    }

    private func launch(_ package: VMPackage, mock: Bool, arguments: [String] = ["mock"]) {
        if let active = model.active, active.state != .idle {
            if case .stopped = active.state {} else if case .failed = active.state {} else {
                // One machine per launch, and this one is still going: show it.
                showMachine = true
                return
            }
        }
        do {
            let runtime: EmulatorRuntime
            if mock {
                runtime = MockEmulatorRuntime(preset: package.configuration.displayPreset,
                                              consoleLog: EmulatorController.consoleLogURL(for: package))
            } else {
                runtime = try InfernoRuntime()
            }
            if !mock { model.prepareWorkingDirectory(for: package) }
            let controller = EmulatorController(package: package, runtime: runtime)
            model.active = controller
            showMachine = true
            controller.start(arguments: arguments)
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }
}

extension VMPackage: Identifiable {
    public var id: URL { url }
}

extension EmulatorController: Identifiable {
    var id: ObjectIdentifier { ObjectIdentifier(self) }
}

struct DeviceCard: View {
    let package: VMPackage
    let onStart: () -> Void

    var body: some View {
        let c = package.configuration
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "iphone")
                .font(.system(size: 34))
                .frame(width: 48)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(c.name).font(.headline)
                Text("iPhone 11 · iOS 14.x").font(.subheadline).foregroundStyle(.secondary)
                Text("\(c.cpuCores) cores · \(formatMB(c.memoryMB)) RAM · \(c.displayPreset.displayName) panel")
                    .font(.caption).foregroundStyle(.secondary)
                if let when = package.uncleanShutdown {
                    Label("Not shut down cleanly (\(when.formatted(date: .abbreviated, time: .shortened)))",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            Spacer()
            Button(action: onStart) {
                Image(systemName: "play.fill").font(.title2)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func formatMB(_ mb: Int) -> String {
        mb % 1024 == 0 ? "\(mb / 1024) GB" : String(format: "%.1f GB", Double(mb) / 1024)
    }
}

struct CreateDeviceView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = "My iPhone 11"
    @State private var preset: DisplayPreset = .iphone11

    var body: some View {
        NavigationStack {
            Form {
                Section("Device") {
                    TextField("Name", text: $name)
                    InfoRow(label: "Model", value: "iPhone 11 (T8030)")
                    InfoRow(label: "Guest", value: "iOS 14.x")
                }
                Section {
                    Picker("Panel", selection: $preset) {
                        ForEach(DisplayPreset.allCases, id: \.self) { p in
                            Text("\(p.displayName) — \(p.width)×\(p.height)").tag(p)
                        }
                    }
                } footer: {
                    Text("The machine is always an iPhone 11; a smaller panel is less work for the emulated cores.")
                }
            }
            .navigationTitle("New Device")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        model.create(name: name, preset: preset)
                        dismiss()
                    }
                    .disabled(VMPackage.directoryName(for: name) == nil)
                }
            }
        }
    }
}

/// "A machine is running" — the way back to it after leaving its screen.
struct ActiveMachineBanner: View {
    @ObservedObject var controller: EmulatorController
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack {
                StatusBadge(text: controller.state.label, color: controller.state.color)
                Text(controller.package.configuration.name).font(.subheadline.weight(.semibold))
                Spacer()
                Text("Open").font(.subheadline)
                Image(systemName: "chevron.right").font(.caption)
            }
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
