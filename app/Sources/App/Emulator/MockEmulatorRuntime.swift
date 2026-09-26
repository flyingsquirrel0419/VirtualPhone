import Foundation

/// Boots in a second and draws a test pattern, so the UI can be developed and
/// checked on a phone without JIT, an emulator build or a guest image.
final class MockEmulatorRuntime: EmulatorRuntime {
    let name = "Mock"
    let capabilities: RuntimeCapabilities = [.display, .touch, .buttons, .pause, .reset, .stop, .stats]
    var onStateChange: ((RuntimeState) -> Void)?

    private let lock = NSLock()
    private var _state: RuntimeState = .idle
    private let width: Int
    private let height: Int
    private var tick: UInt32 = 0
    private var lastTouch: (x: Int32, y: Int32, down: Bool) = (-1, -1, false)
    private var startedAt: Date?
    private var frames: UInt64 = 0
    private var touches: UInt64 = 0
    private var buttons: UInt64 = 0
    private var lastFrameAt = Date.distantPast

    /// Written like the real chardev logfile, so the console, the boot phases
    /// and their timings can be exercised without a guest.
    private let consoleLog: URL?

    init(preset: DisplayPreset, consoleLog: URL? = nil) {
        width = preset.width
        height = preset.height
        self.consoleLog = consoleLog
    }

    static let fakeBoot: [(TimeInterval, String)] = [
        (0.3, "::\tiBoot for n104ap (VirtualPhone mock runtime)"),
        (1.0, "Darwin Kernel Version (mock): no guest is running"),
        (1.6, "BSD root: disk0s1 (mock)"),
        (2.2, "launchd[1]: mock userspace"),
        (3.0, "bash-5.0# "),
    ]

    private func writeConsole(_ line: String) {
        guard let url = consoleLog, let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        handle.write(Data((line + "\r\n").utf8))
    }

    var state: RuntimeState {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }

    private func set(_ new: RuntimeState) {
        lock.lock()
        _state = new
        if new == .running, startedAt == nil { startedAt = Date() }
        lock.unlock()
        AppLogger.shared.log(.vm, "Mock machine \(new.label.lowercased())")
        onStateChange?(new)
    }

    func start(arguments: [String]) throws {
        guard state == .idle else { throw RuntimeError.refused("mock machine already started") }
        set(.starting)
        for (delay, line) in Self.fakeBoot {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.state == .starting || self.state.isLive else { return }
                self.writeConsole(line)
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.state == .starting else { return }
            AppLogger.shared.log(.boot, "Mock kernel: Darwin Kernel Version (mock)")
            self.set(.running)
        }
    }

    func pause() throws {
        guard state == .running else { throw RuntimeError.refused("not running") }
        set(.paused)
    }

    func resume() throws {
        guard state == .paused else { throw RuntimeError.refused("not paused") }
        set(.running)
    }

    func reset() throws {
        guard state.isLive else { throw RuntimeError.refused("not running") }
        lock.lock()
        tick = 0
        lock.unlock()
    }

    func stop() throws {
        guard state.isLive || state == .starting else { return }
        set(.stopping)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.set(.stopped(status: 0)) }
    }

    func readFrame(into buffer: UnsafeMutableRawPointer?, size: Int) -> FrameReadResult {
        guard state.isLive else { return .unavailable }
        guard let buffer, size >= width * height * 4 else { return .resize(width: width, height: height) }

        lock.lock()
        defer { lock.unlock() }
        // About 30 frames a second; paused machines do not redraw.
        guard _state == .running, Date().timeIntervalSince(lastFrameAt) > 1.0 / 30 else { return .none }
        lastFrameAt = Date()
        tick &+= 1
        frames += 1

        let pixels = buffer.bindMemory(to: UInt32.self, capacity: width * height)
        let band = Int(tick % UInt32(height))
        for y in 0..<height {
            let row = pixels + y * width
            let inBand = abs(y - band) < 6
            for x in 0..<width {
                let r = UInt32(x * 255 / width), g = UInt32(y * 255 / height)
                row[x] = inBand ? 0xFFFF_FFFF : (0xFF00_0000 | r << 16 | g << 8 | 0x60)
            }
        }
        if lastTouch.down, lastTouch.x >= 0 {
            for dy in -20...20 {
                for dx in -20...20 where dx * dx + dy * dy <= 400 {
                    let px = Int(lastTouch.x) + dx, py = Int(lastTouch.y) + dy
                    if px >= 0, py >= 0, px < width, py < height { pixels[py * width + px] = 0xFFFF_3B30 }
                }
            }
        }
        return .frame(width: width, height: height)
    }

    func touch(x: Int32, y: Int32, pressed: Bool) {
        lock.lock()
        lastTouch = (x, y, pressed)
        touches += 1
        lock.unlock()
    }

    func button(_ button: RuntimeButton, pressed: Bool) {
        lock.lock()
        buttons += 1
        lock.unlock()
        if pressed { AppLogger.shared.log(.input, "Mock button \(button.title)") }
    }

    func metrics() -> RuntimeMetrics {
        lock.lock()
        defer { lock.unlock() }
        let uptime = startedAt.map { UInt64(Date().timeIntervalSince($0) * 1000) } ?? 0
        return RuntimeMetrics(framesPresented: frames, displayRefreshes: frames, framesRead: frames,
                              touchesSent: touches, buttonsSent: buttons, uptimeMS: uptime, netLinkUp: false)
    }
}
