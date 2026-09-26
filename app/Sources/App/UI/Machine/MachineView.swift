import SwiftUI
import UniformTypeIdentifiers

/// A running machine: the guest's screen, its buttons, and its controls.
struct MachineView: View {
    @ObservedObject var controller: EmulatorController
    @Environment(\.dismiss) private var dismiss
    @State private var fullscreen = false
    @State private var overlay = false
    @State private var confirmStop = false
    @State private var showConsole = UserDefaults.standard.bool(forKey: "VPShowConsole")
    @State private var showImporter = false
    /// Kept apart from `showImporter`: the importer clears that before its completion runs.
    @State private var importKind = ImportKind.file
    @State private var showServices = false
    @State private var askFetch = false
    @State private var fetchPath = "/var/mobile/Documents/"

    enum ImportKind { case ipa, file }

    var body: some View {
        VStack(spacing: 0) {
            if !fullscreen { topBar }
            if !fullscreen {
                Picker("View", selection: $showConsole) {
                    Text("Screen").tag(false)
                    Text("Console").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
            }
            if showConsole && !fullscreen {
                ConsoleView(console: controller.console)
            } else {
                screen
            }
            if !fullscreen { buttonBar }
        }
        .background(Color.black.ignoresSafeArea())
        .statusBarHidden(fullscreen)
        .persistentSystemOverlays(fullscreen ? .hidden : .automatic)
        .alert("Emulator", isPresented: Binding(get: { controller.lastError != nil },
                                                set: { if !$0 { controller.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(controller.lastError ?? "")
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item]) { result in
            guard case .success(let url) = result else { return }
            if importKind == .ipa { controller.services.installIPA(url) } else { controller.services.sendFile(url) }
            showServices = true
        }
        .sheet(isPresented: $showServices) { GuestServicesView(services: controller.services) }
        .alert("Fetch from the guest", isPresented: $askFetch) {
            TextField("Path in the guest", text: $fetchPath)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Fetch") { controller.services.fetchFile(fetchPath); showServices = true }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Stop the machine?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop", role: .destructive) { controller.stop() }
        } message: {
            Text("The guest is powered off and its disks are written back. Starting another machine needs an app relaunch.")
        }
    }

    private var topBar: some View {
        HStack {
            // Leaving never stops the machine: the app model keeps it, and the
            // device list offers the way back. Stop is in the menu.
            Button { dismiss() } label: {
                Label("Back", systemImage: "chevron.left")
            }
            Spacer()
            if controller.isMock { StatusBadge(text: "Mock", color: .purple) }
            PhaseBadge(console: controller.console)
            StatusBadge(text: controller.state.label, color: controller.state.color)
            Menu {
                Button { controller.togglePause() } label: {
                    Label(controller.state == .paused ? "Resume" : "Pause",
                          systemImage: controller.state == .paused ? "play.fill" : "pause.fill")
                }
                .disabled(!controller.state.isLive || !controller.runtime.capabilities.contains(.pause))
                Button { controller.restart() } label: { Label("Restart", systemImage: "arrow.counterclockwise") }
                    .disabled(!controller.state.isLive)
                Button(role: .destructive) { confirmStop = true } label: { Label("Stop", systemImage: "stop.fill") }
                    .disabled(!controller.state.isLive)
                Divider()
                Button { controller.services.reconnectNetwork(); showServices = true } label: {
                    Label("Reconnect Guest Network", systemImage: "network")
                }
                .disabled(!controller.state.isLive)
                Button { controller.press(.ringer) } label: { Label("Toggle Ring/Silent Switch", systemImage: "bell.slash") }
                    .disabled(!controller.state.isLive)
                Button { importKind = .ipa; showImporter = true } label: { Label("Install IPA…", systemImage: "app.badge.plus") }
                    .disabled(!controller.state.isLive)
                Button { importKind = .file; showImporter = true } label: { Label("Send File to Guest…", systemImage: "doc.badge.arrow.up") }
                    .disabled(!controller.state.isLive)
                Button { askFetch = true } label: { Label("Fetch File from Guest…", systemImage: "doc.badge.arrow.down") }
                    .disabled(!controller.state.isLive)
                Divider()
                Button { fullscreen = true } label: { Label("Fullscreen", systemImage: "arrow.up.left.and.arrow.down.right") }
                Toggle(isOn: $overlay) { Label("Debug overlay", systemImage: "gauge") }

            } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var screen: some View {
        GeometryReader { geo in
            ZStack {
                if let metal = controller.metal {
                    MetalFrameView(renderer: metal)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .opacity(controller.hasFrame ? 1 : 0)
                    if !controller.hasFrame { placeholder }
                } else if let frame = controller.frame {
                    Image(decorative: frame, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    placeholder
                }
                if overlay { DebugOverlay(controller: controller).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading) }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        let phase: EmulatorController.TouchPhase = value.translation == .zero ? .began : .moved
                        controller.touch(at: value.location, in: geo.size, phase: phase)
                    }
                    .onEnded { value in
                        controller.touch(at: value.location, in: geo.size, phase: .ended)
                    }
            )
            .onTapGesture(count: 3) { if fullscreen { fullscreen = false } }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            switch controller.state {
            case .starting:
                ProgressView().tint(.white)
                Text("Booting… the guest draws nothing until iBoot hands over.").font(.footnote)
            case .failed(let why):
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.red)
                Text(why).font(.footnote).multilineTextAlignment(.center)
            case .stopped(let status):
                Image(systemName: "power").font(.largeTitle)
                Text("Machine stopped (status \(status)).").font(.footnote)
            default:
                Text("Waiting for the guest's first frame…").font(.footnote)
            }
        }
        .foregroundStyle(.secondary)
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var buttonBar: some View {
        HStack(spacing: 0) {
            ForEach(RuntimeButton.barButtons) { button in
                Button {
                    controller.press(button)
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: button.systemImage)
                        Text(button.title).font(.caption2)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.6).onEnded { _ in
                    // A long press on Side holds it long enough for the power-off slider.
                    if button == .side { controller.press(.side, hold: 2.5) }
                })
                .disabled(!controller.state.isLive || !controller.runtime.capabilities.contains(.buttons))
            }
        }
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }
}

struct DebugOverlay: View {
    @ObservedObject var controller: EmulatorController
    @ObservedObject var console: GuestConsole

    init(controller: EmulatorController) {
        _controller = ObservedObject(wrappedValue: controller)
        _console = ObservedObject(wrappedValue: controller.console)
    }

    var body: some View {
        let m = controller.metrics
        VStack(alignment: .leading, spacing: 2) {
            Text(String(format: "FPS %.1f", controller.fps))
            Text("frame \(controller.frameSize.width)×\(controller.frameSize.height)")
            Text("presented \(m.framesPresented)/s · refresh \(m.displayRefreshes)/s")
            Text("uptime \(m.uptimeMS / 1000)s · touches \(m.touchesSent) · buttons \(m.buttonsSent)")
            Text("tb \(controller.package.configuration.translatorCacheMB) MB · guest RAM \(controller.package.configuration.memoryMB) MB")
            Text(String(format: "host CPU %.0f%% · host RAM %ld MB · network %@", controller.hostCPU, HostInfo.residentMB, m.netLinkUp ? "up" : "down"))
            Text("runtime \(controller.runtime.name) · qmp \(console.qmpStatus ?? "—")")
            ForEach(console.transitions, id: \.phase) { t in
                Text(String(format: "%@ at %.1fs", t.phase.label, t.elapsed))
            }
            if let first = console.firstFrameAfter {
                Text(String(format: "first frame at %.1fs", first))
            }
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.green)
        .padding(6)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        .padding(8)
        .allowsHitTesting(false)
    }
}

/// The boot phase, from the console; watched separately so the top bar
/// redraws when the console changes.
struct PhaseBadge: View {
    @ObservedObject var console: GuestConsole

    var body: some View {
        if console.phase > .poweredOn {
            StatusBadge(text: console.phase.label, color: console.phase.color)
        }
    }
}
