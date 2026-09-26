import Foundation

/// The real emulator, through the C bridge in app/Runtime (vp_runtime.h).
final class InfernoRuntime: EmulatorRuntime {
    static let libraryName = "libqemu-aarch64-softmmu.dylib"

    let name = "Inferno"
    private let handle: OpaquePointer
    private let lock = NSLock()
    private var _state: RuntimeState = .idle
    var onStateChange: ((RuntimeState) -> Void)?

    static var libraryPath: String? {
        let candidates = [Bundle.main.privateFrameworksPath, Bundle.main.bundlePath].compactMap { $0 }
            .map { $0 + "/" + libraryName }
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    static var isBundled: Bool { libraryPath != nil }

    init() throws {
        guard let path = Self.libraryPath else { throw RuntimeError.libraryMissing }
        var error = [CChar](repeating: 0, count: 512)
        guard let handle = vp_emulator_create(path, &error, error.count) else {
            throw RuntimeError.load(String(cString: error))
        }
        self.handle = handle
        vp_emulator_set_state_callback(handle, { context, state, detail in
            guard let context else { return }
            let runtime = Unmanaged<InfernoRuntime>.fromOpaque(context).takeUnretainedValue()
            runtime.bridgeStateChanged(state, detail: detail)
        }, Unmanaged.passUnretained(self).toOpaque())
        AppLogger.shared.log(.vm, "Emulator library loaded: \(path)")
    }

    deinit {
        // Only frees when the machine never ran or has ended; a live QEMU
        // cannot be torn down and the process keeps it.
        vp_emulator_set_state_callback(handle, nil, nil)
        _ = vp_emulator_destroy(handle)
    }

    var capabilities: RuntimeCapabilities { RuntimeCapabilities(rawValue: vp_emulator_capabilities(handle)) }

    var state: RuntimeState {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }

    private func bridgeStateChanged(_ raw: vp_state, detail: Int32) {
        let new: RuntimeState
        switch raw {
        case VP_STATE_IDLE: new = .idle
        case VP_STATE_STARTING: new = .starting
        case VP_STATE_RUNNING: new = .running
        case VP_STATE_PAUSED: new = .paused
        case VP_STATE_STOPPING: new = .stopping
        case VP_STATE_STOPPED: new = .stopped(status: detail)
        default: new = .failed(String(cString: vp_emulator_last_error(handle)))
        }
        lock.lock()
        _state = new
        lock.unlock()
        AppLogger.shared.log(.vm, "Machine \(new.label.lowercased())")
        onStateChange?(new)
    }

    private func check(_ rc: Int32, _ what: String) throws {
        guard rc != Int32(truncatingIfNeeded: VP_OK.rawValue) else { return }
        let message = "\(what): \(String(cString: vp_emulator_last_error(handle))) (\(rc))"
        AppLogger.shared.log(.vm, message, level: .error)
        throw RuntimeError.refused(message)
    }

    func start(arguments: [String]) throws {
        AppLogger.shared.log(.qemu, "argv: " + arguments.joined(separator: " "))
        // The bridge copies argv, so these only need to live for the call.
        let owned: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        defer { owned.forEach { free($0) } }
        let cargs: [UnsafePointer<CChar>?] = owned.map { $0.map { UnsafePointer($0) } }
        let rc = cargs.withUnsafeBufferPointer { buf in
            vp_emulator_start(handle, Int32(buf.count), buf.baseAddress)
        }
        try check(rc, "start")
    }

    func pause() throws { try check(vp_emulator_pause(handle), "pause") }
    func resume() throws { try check(vp_emulator_resume(handle), "resume") }
    func reset() throws { try check(vp_emulator_reset(handle), "reset") }
    func stop() throws { try check(vp_emulator_stop(handle), "stop") }

    func readFrame(into buffer: UnsafeMutableRawPointer?, size: Int) -> FrameReadResult {
        var info = vp_frame_info()
        let result = vp_emulator_framebuffer(handle, buffer, size, &info)
        switch result {
        case VP_FRAME_NONE: return .none
        case VP_FRAME_OK: return .frame(width: Int(info.width), height: Int(info.height))
        case VP_FRAME_RESIZE: return .resize(width: Int(info.width), height: Int(info.height))
        default: return .unavailable
        }
    }

    func touch(x: Int32, y: Int32, pressed: Bool) {
        _ = vp_emulator_set_touch(handle, x, y, pressed)
    }

    func button(_ button: RuntimeButton, pressed: Bool) {
        let raw: vp_button
        switch button {
        case .home: raw = VP_BUTTON_HOME
        case .side: raw = VP_BUTTON_SIDE
        case .volumeUp: raw = VP_BUTTON_VOLUME_UP
        case .volumeDown: raw = VP_BUTTON_VOLUME_DOWN
        }
        _ = vp_emulator_button_event(handle, raw, pressed)
    }

    func metrics() -> RuntimeMetrics {
        var m = vp_metrics()
        vp_emulator_get_metrics(handle, &m)
        return RuntimeMetrics(framesPresented: m.frames_presented, displayRefreshes: m.display_refreshes,
                              framesRead: m.frames_read, touchesSent: m.touches_sent,
                              buttonsSent: m.buttons_sent, uptimeMS: m.uptime_ms, netLinkUp: m.net_link_up)
    }
}
